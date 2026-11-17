// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../../src/MockERC20.sol";

/// @title 边界与不变量
/// @notice 放两类东西：管理员函数的失败路径，以及「无论输入怎么变都必须成立」的 fuzz 不变量。
///         不变量比单点用例更难写错，因为它不预设具体数值，只约束关系。
contract EdgeCasesTest is StakingRewardsBase {
    /*//////////////////////////////////////////////////////////////
                        一、初始化的参数校验
    //////////////////////////////////////////////////////////////*/

    function test_SetRewardsDurationRejectedWhileActive() public {
        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        vm.expectRevert(StakingRewards.PeriodStillActive.selector);
        staking.setRewardsDuration(14 days);
    }

    function test_SetRewardsDurationAfterFinish() public {
        vm.warp(staking.periodFinish());

        vm.prank(admin);
        vm.expectRevert(StakingRewards.InvalidDuration.selector);
        staking.setRewardsDuration(0);

        vm.prank(admin);
        staking.setRewardsDuration(14 days);
        assertEq(staking.rewardsDuration(), 14 days, "duration updated");
    }

    /// duration 为 0 会让 notifyRewardAmount 的除法 panic，必须在 initialize 就挡住。
    /// 代理模式下这道校验更重要：部署代理和初始化是两件事，一旦放过就再没有第二次机会
    function test_InitializeRejectsZeroDuration() public {
        StakingRewards impl = new StakingRewards();
        bytes memory initData = abi.encodeCall(StakingRewards.initialize, (stakeToken, rewardToken, 0, 0));

        vm.expectRevert(StakingRewards.InvalidDuration.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// 质押币和奖励币是同一个地址时，`available = balance - totalOwed` 里混进了用户本金，
    /// manager 可以把本金当奖励预算许诺出去。这个前提必须在初始化就被拒绝，
    /// 因为代理部署之后没有第二次改这两个地址的机会
    function test_InitializeRejectsSameToken() public {
        StakingRewards impl = new StakingRewards();
        bytes memory initData =
            abi.encodeCall(StakingRewards.initialize, (stakeToken, stakeToken, DURATION, 0));

        vm.expectRevert(StakingRewards.InvalidToken.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// 零地址代币：转账会打到 address(0)，在部分实现里「成功但什么都没发生」
    function test_InitializeRejectsZeroToken() public {
        StakingRewards impl = new StakingRewards();

        bytes memory zeroStake =
            abi.encodeCall(StakingRewards.initialize, (IERC20(address(0)), rewardToken, DURATION, 0));
        vm.expectRevert(StakingRewards.InvalidToken.selector);
        new ERC1967Proxy(address(impl), zeroStake);

        bytes memory zeroReward =
            abi.encodeCall(StakingRewards.initialize, (stakeToken, IERC20(address(0)), DURATION, 0));
        vm.expectRevert(StakingRewards.InvalidToken.selector);
        new ERC1967Proxy(address(impl), zeroReward);
    }

    /*//////////////////////////////////////////////////////////////
                          二、误转代币的回收
    //////////////////////////////////////////////////////////////*/

    function test_RecoverERC20RefusesBothPoolTokens() public {
        vm.prank(admin);
        vm.expectRevert(StakingRewards.CannotRecoverStakingToken.selector);
        staking.recoverERC20(address(stakeToken), 1);

        vm.prank(admin);
        vm.expectRevert(StakingRewards.CannotRecoverRewardToken.selector);
        staking.recoverERC20(address(rewardToken), 1);
    }

    function test_RecoverERC20ReturnsForeignTokenToCaller() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staking), 7e18);

        vm.prank(admin);
        staking.recoverERC20(address(other), 7e18);

        assertEq(other.balanceOf(admin), 7e18, "sent to caller");
        assertEq(other.balanceOf(address(staking)), 0, "drained");
    }

    /*//////////////////////////////////////////////////////////////
                            三、空池视图
    //////////////////////////////////////////////////////////////*/

    function test_RewardPerTokenFrozenWhenEmpty() public view {
        // setUp 里已经 notify，但没人质押
        assertEq(staking.totalSupply(), 0, "empty");
        assertEq(staking.rewardPerToken(), 0, "no accrual without stake");
    }

    function test_EarnedZeroForUnseenAccount() public view {
        assertEq(staking.earned(address(0xdead)), 0, "unknown account earns nothing");
    }

    /*//////////////////////////////////////////////////////////////
                            四、fuzz 不变量
    //////////////////////////////////////////////////////////////*/

    /// 不变量：所有提取之和永远不超过存入之和。
    /// 这条比「余额对不对」更强——它不依赖具体数值，任何金额序列都必须成立
    function testFuzz_NeverWithdrawMoreThanStaked(uint96 first, uint96 second, uint32 elapsed) public {
        uint256 a = bound(uint256(first), 1e12, 1_000e18);
        uint256 t = bound(uint256(elapsed), 0, DURATION);

        // 额外发一笔，制造「钱包余额 ≠ 初始值」的干扰，防止断言写死成理想值而假绿
        stakeToken.mint(alice, bound(uint256(second), 0, 1_000e18));
        uint256 walletBefore = stakeToken.balanceOf(alice);

        _stake(alice, a);
        vm.warp(block.timestamp + t);

        // 顶格提取，钱包必须回到存入前的余额，一手不差
        _requestUnstake(alice, a);

        assertEq(stakeToken.balanceOf(alice), walletBefore, "wallet exactly restored");
        assertEq(staking.balanceOf(alice), 0, "position cleared");
        assertEq(staking.totalSupply(), 0, "pool empty");
    }

    /// 不变量：任何时刻待领奖励都不超过同一时刻池子的产出上限。
    /// 若实现里少加了某个除数，这条会立刻炸出来
    function testFuzz_EarnedNeverExceedsBudget(uint96 rawAmount, uint32 elapsed) public {
        uint256 amount = bound(uint256(rawAmount), 1e12, 1_000e18);
        uint256 t = bound(uint256(elapsed), 0, DURATION);

        _stake(alice, amount);
        vm.warp(block.timestamp + t);

        assertLe(staking.earned(alice), RATE * DURATION, "cannot exceed total emission");
        assertApproxEqRel(staking.earned(alice), RATE * t, 1e10, "exactly proportional to time");
    }

    /// 不变量：合约持有的奖励币永远够付「此刻应付给用户的部分」。
    /// @dev **这条的真实强度有限，别把它当成偿付能力的证明**：
    ///      被比较量只有「余额」和「单个用户的 earned」，而余额在整段 fuzz 里恒为一期预算，
    ///      所以它实际上只能说明「单人应计不超过一期产出」，抓不到负债口径那类问题
    ///      （`totalOwed` 少记时它照样绿）。真正夹逼负债的是
    ///      `test/StakingRewards/Invariants.t.sol` 里的 `invariant_RewardLiabilityWithinBalance`。
    ///      另外不能先调 `_getReward` 再断言：那样 `totalOwed` 必然归零，
    ///      整个断言退化成 `balance >= 0`（A-27）。
    ///      被比较量也不该用 `totalOwed`——它是惰性量，两次结算之间读到的值偏低
    function testFuzz_SolventAlways(uint96 rawAmount, uint32 elapsed) public {
        uint256 amount = bound(uint256(rawAmount), 1e12, 1_000e18);
        uint256 t = bound(uint256(elapsed), 1, DURATION);

        _stake(alice, amount);
        vm.warp(block.timestamp + t);

        // 前提：收益不为零，否则下面的断言是平凡真
        assertGt(staking.earned(alice), 0, "non-trivial accrual");

        assertGe(
            rewardToken.balanceOf(address(staking)),
            staking.earned(alice),
            "balance covers what is owed right now"
        );
    }
}
