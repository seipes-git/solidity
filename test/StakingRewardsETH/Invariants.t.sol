// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {MockERC20} from "../../src/MockERC20.sol";

/// @title ETH 池的 handler
/// @notice 只通过合约函数动钱：不给 staking 直接 `vm.deal`、不直转。
///         `receive()` 存在，所以「误转」是真实可能的，等式类不变量必须建立在
///         「handler 不制造误转」这个前提上——这也是它和产品路径的区别所在。
contract ETHPoolHandler is Test {
    StakingRewardsETH public immutable staking;
    MockERC20 public immutable rewardToken;

    address[] public actors;

    /// @dev 解锁时间的影子账本：按「当时的 block.timestamp + 当时的冷却」取历史最大值，
    ///      不读合约的 `unlockTime`，两边不共享输入
    mapping(address => uint256) private _expectedUnlock;

    constructor(StakingRewardsETH staking_, MockERC20 rewardToken_) {
        staking = staking_;
        rewardToken = rewardToken_;

        for (uint256 i; i < 3; ++i) {
            address actor = makeAddr(string.concat("ethActor", vm.toString(i)));
            actors.push(actor);
            vm.deal(actor, 1_000 ether);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice 影子账本里这个地址的解锁时间下限
    function expectedUnlock(address actor) external view returns (uint256) {
        return _expectedUnlock[actor];
    }

    /// @notice 改冷却。需要 DEFAULT_ADMIN_ROLE，由测试的 setUp 授予
    function setCooldown(uint256 seed) external {
        try staking.setUnstakeCooldown(bound(seed, 0, 30 days)) {} catch {}
    }

    function stake(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 wallet = actor.balance;
        if (wallet == 0) return;

        amount = bound(amount, 1, wallet);
        vm.prank(actor);
        try staking.stake{value: amount}() {} catch {}
    }

    function requestUnstake(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 position = staking.balanceOf(actor);
        if (position == 0) return;

        amount = bound(amount, 1, position);
        // 冷却必须在调用前读：合约用的是调用那一刻的值
        uint256 cooldown = staking.unstakeCooldown();

        vm.prank(actor);
        try staking.requestUnstake(amount) {
            if (cooldown != 0) _noteRequest(actor, cooldown);
        } catch {}
    }

    function withdraw(uint256 seed) external {
        address actor = _actor(seed);
        vm.prank(actor);
        try staking.withdraw() {
            delete _expectedUnlock[actor];
        } catch {}
    }

    function getReward(uint256 seed) external {
        vm.prank(_actor(seed));
        try staking.getReward() {} catch {}
    }

    function exit(uint256 seed) external {
        address actor = _actor(seed);
        uint256 position = staking.balanceOf(actor);
        uint256 cooldown = staking.unstakeCooldown();
        // 同 ERC20 池：exit 内置的 withdraw 会清空 pending，影子要跟着归零
        (, bool unlocked) = staking.withdrawable(actor);

        vm.prank(actor);
        try staking.exit() {
            if (unlocked) delete _expectedUnlock[actor];
            if (position != 0 && cooldown != 0) _noteRequest(actor, cooldown);
        } catch {}
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 12 hours));
    }

    function notify(uint256 amount) external {
        uint256 wallet = rewardToken.balanceOf(address(this));
        if (wallet == 0) return;

        amount = bound(amount, 1, wallet);
        if (!rewardToken.transfer(address(staking), amount)) return;
        try staking.notifyRewardAmount(amount) {} catch {}
    }

    function _noteRequest(address actor, uint256 cooldown) internal {
        uint256 candidate = block.timestamp + cooldown;
        if (candidate > _expectedUnlock[actor]) _expectedUnlock[actor] = candidate;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// @title ETH 池的状态型不变量
/// @notice ETH 池没有「第二个币」可以对账，唯一的账本就是 `totalSupply + totalPending`；
///         `recoverETH` 的上限也是用这两个数算出来的。
contract ETHPoolInvariantsTest is StdInvariant, StakingRewardsETHBase {
    /// @dev 取整 dust 的容差，只服务于不变量自身：`totalOwed` 每个结算边界各 floor 一次，
    ///      单个用户的 `rewards` 是跨多个边界的一次性 floor，逐户求和可以超出负债 n-1 wei。
    ///      这个差额在 `getReward` / `emergencyWithdraw` 里由夹逼吸收，不构成可回滚的路径
    uint256 private constant ROUNDING_DUST = 1e6;

    ETHPoolHandler internal handler;

    function setUp() public override {
        vm.warp(1_700_000_000);
        _deploy(COOLDOWN);

        handler = new ETHPoolHandler(staking, rewardToken);
        rewardToken.mint(address(handler), 1_000_000e18);

        // handler 要能改冷却，否则 `setCooldown` 每次都撞权限、参数抖动这条路径根本不存在
        staking.grantRole(ADMIN_ROLE_ID, address(handler));

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              不变量
    //////////////////////////////////////////////////////////////*/

    /// 合约实际持有的 ETH == 计息本金 + 冷却中的本金。
    /// handler 从不直接给合约打钱，所以这里必须是等式，不是 ≥
    function invariant_ETHFullyBacked() public view {
        assertEq(address(staking).balance, staking.totalSupply() + staking.totalPending(), "ETH fully backed");
    }

    /// 双向夹逼：所有地址挂账之和不超过负债，负债不超过奖励币余额。
    /// 与 ERC20 池的 `invariant_RewardLiabilityWithinBalance` 同一套口径
    function invariant_RewardLiabilityWithinBalance() public view {
        uint256 booked;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            booked += staking.rewards(handler.actors(i));
        }

        uint256 owed = staking.totalOwed();
        assertLe(booked, owed + ROUNDING_DUST, "booked rewards <= liability (+ dust)");
        assertLe(owed, rewardToken.balanceOf(address(staking)), "liability <= reward balance");
    }

    /// 挂着的解锁请求，其解锁时间不早于「历次请求里最晚的那次」。
    /// ETH 池的冷却上限是 30 天且没有紧急出口，这条对它比对 ERC20 池更要紧
    function invariant_UnlockTimeNeverShortened() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            (, uint256 unlockTime) = staking.pendingUnstake(actor);
            assertGe(unlockTime, handler.expectedUnlock(actor), "unlock time never moved earlier");
        }
    }

    /*//////////////////////////////////////////////////////////////
                          夹具自检
    //////////////////////////////////////////////////////////////*/

    /// handler 的动作真的改变了池子状态。否则不变量在空池上平凡成立
    function test_HandlerReachesContract() public {
        uint256 heldBefore = address(staking).balance;

        handler.stake(0, 10 ether);
        assertEq(staking.balanceOf(handler.actors(0)), 10 ether, "stake reached the pool");
        assertEq(address(staking).balance - heldBefore, 10 ether, "ETH moved in");

        handler.requestUnstake(0, 10 ether);
        assertEq(staking.totalPending(), 10 ether, "request reached the pool");
        assertEq(staking.totalSupply(), 0, "position left the accruing side");
    }

    /// 改冷却这个动作真的落到了合约上，且影子账本跟着走。
    /// 没有这一条，`invariant_UnlockTimeNeverShortened` 在「影子恒为 0」时会平凡成立
    function test_CooldownChangeReachesContractAndShadowTracks() public {
        handler.setCooldown(20 days);
        assertEq(staking.unstakeCooldown(), 20 days, "cooldown applied");

        handler.stake(0, 10 ether);
        handler.requestUnstake(0, 10 ether);

        address actor = handler.actors(0);
        (uint256 pending, uint256 unlockTime) = staking.pendingUnstake(actor);
        assertEq(pending, 10 ether, "request landed");
        assertEq(unlockTime, block.timestamp + 20 days, "deadline from the cooldown of that moment");
        assertEq(handler.expectedUnlock(actor), unlockTime, "shadow matches the pool");

        // 冷却改短后再挂一笔：老额度的解锁时间更晚，必须被保留
        handler.setCooldown(1 days);
        handler.stake(0, 10 ether);
        handler.requestUnstake(0, 10 ether);

        (, uint256 unlockTimeAfter) = staking.pendingUnstake(actor);
        assertEq(unlockTimeAfter, unlockTime, "a shorter cooldown does not pull the deadline forward");
        assertEq(handler.expectedUnlock(actor), unlockTimeAfter, "shadow keeps the later deadline");
    }
}
