// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

/// @title ERC20 池的重入面：证明 `nonReentrant` 真的在挡东西
/// @notice ETH 池的同一组用例在 `test/StakingRewardsETH/Reentrancy.t.sol`，
///         那边靠恶意接收方的 `receive()` 触发；这里有两条触发路径：
///           - `stake` 走 `transferFrom`，代币可以在这一步回调
///           - `withdraw` / `getReward` 走 `safeTransfer`，同一位置也能回调
///
/// @dev 为什么这些用例必须存在：`stake` / `withdraw` / `getReward` 三个入口都挂了
///      `nonReentrant`，但在此之前 263 条里没有一条会因为它被删掉而变红。
///      「结构上安全」和「有证据证明它安全」是两件事，这里补的是后者。
///
///      每条攻击用例都配了两个断言：
///        ① 重入**失败了**，且失败原因是 `ReentrancyGuardReentrantCall`——
///           只断言「没成功」会把「余额不足」这类无关失败也算成防线有效；
///        ② 钱只动了一次，且别人的本金一分未改。
contract ERC20ReentrancyTest is StakingRewardsBase {
    /// 0 冷却，让 `requestUnstake` 退化成单笔提取，转账路径更短、更好定位
    function setUp() public override {
        vm.warp(1_700_000_000);
        // 基座用 MockERC20 建的那套环境这里用不上：本文件每一步都要换成会回调的代币
    }

    /*//////////////////////////////////////////////////////////////
                                工具
    //////////////////////////////////////////////////////////////*/

    /// @dev 用指定的两个代币建一个池子，其余参数与基座一致
    function _deployWith(MockERC20 stk, MockERC20 rwd, uint256 cooldown) internal returns (StakingRewards pool) {
        StakingRewards impl = new StakingRewards();
        bytes memory initData = abi.encodeCall(StakingRewards.initialize, (stk, rwd, DURATION, cooldown));
        vm.prank(admin);
        pool = StakingRewards(address(new ERC1967Proxy(address(impl), initData)));
    }

    /// @dev 注资 + 开奖，与基座 `_deploy` 的后两步一致
    function _fund(MockERC20 rwd) internal {
        rwd.mint(address(staking), FUND);
        vm.prank(admin);
        staking.notifyRewardAmount(FUND);
    }

    function _approve(MockERC20 token, address who) internal {
        vm.prank(who);
        token.approve(address(staking), type(uint256).max);
    }

    function _guardSelector() internal pure returns (bytes4) {
        return ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
    }

    /*//////////////////////////////////////////////////////////////
                        ① stake：transferFrom 里回调
    //////////////////////////////////////////////////////////////*/

    function test_ReentrantStakeIsBlockedAndCreditedOnce() public {
        ReentrantERC20 stk = new ReentrantERC20();
        ReentrantERC20 rwd = new ReentrantERC20();
        staking = _deployWith(stk, rwd, 0);
        _fund(rwd);

        stk.mint(alice, 100e18);
        _approve(stk, alice);

        // 质押 100 的过程中，代币回调池子再 stake 一次
        stk.arm(address(staking), abi.encodeWithSignature("stake(uint256)", 1e18));

        vm.prank(alice);
        staking.stake(100e18);

        assertTrue(stk.attacked(), "attack did not trigger");
        assertFalse(stk.reentrySucceeded(), "re-entry must fail");
        assertEq(
            bytes32(stk.lastRevertSelector()),
            bytes32(_guardSelector()),
            "must be blocked by the reentrancy guard"
        );

        // 只记一次：重入那次既没生效也没留下半笔仓位
        assertEq(staking.balanceOf(alice), 100e18, "credited exactly once");
        assertEq(staking.totalSupply(), 100e18, "totalSupply credited once");
    }

    /*//////////////////////////////////////////////////////////////
                        ② getReward：safeTransfer 里回调
    //////////////////////////////////////////////////////////////*/

    function test_ReentrantGetRewardCannotDoublePay() public {
        ReentrantERC20 stk = new ReentrantERC20();
        ReentrantERC20 rwd = new ReentrantERC20();
        staking = _deployWith(stk, rwd, 0);
        _fund(rwd);

        stk.mint(alice, 100e18);
        _approve(stk, alice);
        vm.prank(alice);
        staking.stake(100e18);

        vm.warp(block.timestamp + 1_000);
        uint256 expected = staking.earned(alice);
        assertGt(expected, 0, "nothing accrued, the test would be vacuous");

        // 发奖励的那一刻回调，试图再领一次
        rwd.arm(address(staking), abi.encodeWithSignature("getReward()"));

        vm.prank(alice);
        staking.getReward();

        assertTrue(rwd.attacked(), "attack did not trigger");
        assertFalse(rwd.reentrySucceeded(), "re-entry must fail");
        assertEq(
            bytes32(rwd.lastRevertSelector()),
            bytes32(_guardSelector()),
            "must be blocked by the reentrancy guard"
        );

        assertEq(rwd.balanceOf(alice), expected, "paid exactly once");
    }

    /*//////////////////////////////////////////////////////////////
                     ③ requestUnstake：本金的转账里回调
    //////////////////////////////////////////////////////////////*/

    function test_ReentrantUnstakeCannotDrainOtherPrincipal() public {
        ReentrantERC20 stk = new ReentrantERC20();
        ReentrantERC20 rwd = new ReentrantERC20();
        staking = _deployWith(stk, rwd, 0);
        _fund(rwd);

        // 池子里必须有别人的钱，否则「掏空自己」也会被误判成攻击成功
        stk.mint(alice, 100e18);
        stk.mint(bob, 10e18);
        _approve(stk, alice);
        _approve(stk, bob);

        vm.prank(alice);
        staking.stake(100e18);
        vm.prank(bob);
        staking.stake(10e18);

        // bob 提取自己的 10 时回调，试图调 withdraw() 把 alice 的本金也提走
        stk.arm(address(staking), abi.encodeWithSignature("withdraw()"));

        vm.prank(bob);
        staking.requestUnstake(10e18);

        assertTrue(stk.attacked(), "attack did not trigger");
        assertFalse(stk.reentrySucceeded(), "re-entry must fail");
        assertEq(
            bytes32(stk.lastRevertSelector()),
            bytes32(_guardSelector()),
            "must be blocked by the reentrancy guard"
        );

        assertEq(stk.balanceOf(bob), 10e18, "own principal returned exactly once");
        assertEq(stk.balanceOf(address(staking)), 100e18, "alice principal untouched");
    }

    /*//////////////////////////////////////////////////////////////
                          ④ exit：复合入口也要挡住
    //////////////////////////////////////////////////////////////*/

    function test_ReentrantExitIsBlocked() public {
        ReentrantERC20 stk = new ReentrantERC20();
        ReentrantERC20 rwd = new ReentrantERC20();
        staking = _deployWith(stk, rwd, 0);
        _fund(rwd);

        stk.mint(alice, 100e18);
        _approve(stk, alice);
        vm.prank(alice);
        staking.stake(100e18);

        vm.warp(block.timestamp + 500);

        stk.arm(address(staking), abi.encodeWithSignature("exit()"));

        vm.prank(alice);
        staking.exit();

        assertTrue(stk.attacked(), "attack did not trigger");
        assertFalse(stk.reentrySucceeded(), "re-entry must fail");
        assertEq(
            bytes32(stk.lastRevertSelector()),
            bytes32(_guardSelector()),
            "exit() has no guard itself; its inner requestUnstake does"
        );

        // 正常路径没被这次攻击破坏：本金和奖励都到位
        assertEq(staking.balanceOf(alice), 0, "position closed");
        assertEq(stk.balanceOf(alice), 100e18, "principal returned");
        assertGt(rwd.balanceOf(alice), 0, "reward paid");
    }

    /*//////////////////////////////////////////////////////////////
                     ⑤ 对照：这个代币不攻击时一切正常
    //////////////////////////////////////////////////////////////*/

    /// @dev 没有这条，前四条都可能「因为代币本身就转不动」而假绿
    function test_SameTokensWorkNormallyWhenNotAttacking() public {
        ReentrantERC20 stk = new ReentrantERC20();
        ReentrantERC20 rwd = new ReentrantERC20();
        staking = _deployWith(stk, rwd, 0);
        _fund(rwd);

        stk.mint(alice, 100e18);
        _approve(stk, alice);

        vm.prank(alice);
        staking.stake(100e18);
        assertEq(staking.balanceOf(alice), 100e18);

        vm.warp(block.timestamp + 1_000);
        uint256 expected = staking.earned(alice);
        vm.prank(alice);
        staking.getReward();
        assertEq(rwd.balanceOf(alice), expected);

        vm.prank(alice);
        staking.requestUnstake(100e18);
        assertEq(stk.balanceOf(alice), 100e18, "principal back");
        assertEq(staking.totalSupply(), 0, "pool emptied by its only staker");
    }
}
