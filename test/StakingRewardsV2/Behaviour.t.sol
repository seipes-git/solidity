// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsV2Base} from "./StakingRewardsV2Base.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {StakingRewardsV2} from "../../src/StakingRewardsV2.sol";

/// @title V2 的行为 —— 升级之后新增的三件事
/// @notice 这个文件只回答一个问题：**V2 比 V1 多做了什么**。
///         对应 V1 的三处缺口写在 `test/StakingRewards/Limits.t.sol`，两个文件合起来是完整的一组。
///
///         ① 观测接口：totalOwedLive / solvencyRatio
///         ② recoverERC20 对 rewardToken 从「一律禁止」改成「只能取盈余」
///         ③ emergencyWithdraw：放弃奖励、无视冷却、立即取回本金
///
/// @dev 全部走「V1 部署 + 真实升级」的路径（见 `StakingRewardsV2Base`），因为线上就是这么发生的。
///      状态快照式的升级验证单独放在 `Upgrade.t.sol`，这里只测行为。
contract V2BehaviourTest is StakingRewardsV2Base {
    /*//////////////////////////////////////////////////////////////
                        一、版本与观测接口
    //////////////////////////////////////////////////////////////*/

    function test_VersionIsTwo() public view {
        assertEq(_asV2().version(), 2, "version bumped");
        assertEq(staking.implementation(), address(v2), "proxy upgraded");
    }

    /// 没有任何负债时返回 max，而不是 0。前端必须分开处理这两种情况
    function test_SolvencyRatioIsMaxWhenNoDebt() public {
        // 换一个「初始化了但没注资」的池子，再把它的代理升到 V2
        _deployEmpty(COOLDOWN);
        StakingRewardsV2 fresh = new StakingRewardsV2();
        _upgradeTo(address(fresh));

        assertEq(fresh.totalOwedLive(), 0, "no liability");
        assertEq(fresh.solvencyRatio(), type(uint256).max, "max means 'no debt', not 'insolvent'");
    }

    /// 注资恰好覆盖整期时，偿付率随时间从「极高」降到周期结束的 1.0。
    /// 这条同时验证了两件事：totalOwedLive 会跟踪应计，而且整期预算确实是够的
    function test_SolvencyRatioDropsToOneAtPeriodEnd() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION);

        // 触发一次结算，让 totalOwed 追上真实应计
        _requestUnstake(alice, 100e18);

        assertApproxEqRel(_asV2().solvencyRatio(), 1e18, 0.0001e18, "budget exactly covers the period");
    }

    /// totalOwedLive 要把「未结算的应计」算进去，而 V1 的 totalOwed 刻意不算
    function test_TotalOwedLiveIncludesUnsettledAccrual() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 2 days);

        uint256 lazy = staking.totalOwed();
        uint256 live = _asV2().totalOwedLive();

        assertApproxEqAbs(live - lazy, 2 * ONE_DAY_REWARD, 1e6, "two days of accrual not yet booked");
        assertGt(_asV2().solvencyRatio(), 0, "ratio computable");
    }

    /*//////////////////////////////////////////////////////////////
                    二、recoverERC20：只能取盈余
    //////////////////////////////////////////////////////////////*/

    /// 额外注进来的钱可以取，本期预算一分不能动
    function test_RecoverRewardTokenTakesOnlyTheExtra() public {
        uint256 extra = 1_000e18;
        rewardToken.mint(address(staking), extra);

        vm.prank(admin);
        _asV2().recoverERC20(address(rewardToken), extra);
        assertEq(rewardToken.balanceOf(admin), extra, "extra arrived");

        // 取完之后，本期预算仍然锁着，再取 1 wei 都不行
        vm.prank(admin);
        vm.expectPartialRevert(StakingRewards.InsufficientRewardBalance.selector);
        _asV2().recoverERC20(address(rewardToken), 1);
    }

    /// 多取 1 wei 就被拦。报错里的 available 精确等于额外注资额
    function test_RecoverRewardTokenRejectsOneWeiOverAvailable() public {
        uint256 extra = 1_000e18;
        rewardToken.mint(address(staking), extra);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InsufficientRewardBalance.selector, extra + 1, extra));
        _asV2().recoverERC20(address(rewardToken), extra + 1);
    }

    /// 周期跑到一半时，剩下那段的预算已经被许诺，取不走。
    /// 这条是 V2 第一版漏掉的洞：按 `balance - totalOwed` 算，这里会放出 43.2 万枚的假盈余，
    /// 取走后到第 7 天用户 getReward 就会 safeTransfer 失败
    function test_MidPeriodBudgetIsLocked() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 2 days);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InsufficientRewardBalance.selector, 1, 0));
        _asV2().recoverERC20(address(rewardToken), 1);
    }

    /// A-8 留下的钱现在有出口了：整期空池，那 604800 枚奖励在 V1 里永远取不出来
    /// （stakingToken 和 rewardToken 都被 recoverERC20 死禁）
    function test_StrandedRewardsRecoverableAfterEmptyPeriod() public {
        // 池子从头到尾空着
        vm.warp(block.timestamp + DURATION + 1);
        assertEq(staking.totalOwed(), 0, "nobody earned anything");
        assertEq(staking.periodFinish() < block.timestamp ? 1 : 0, 1, "period over");

        vm.prank(admin);
        _asV2().recoverERC20(address(rewardToken), FUND);

        assertEq(rewardToken.balanceOf(admin), FUND, "stranded budget came back");
    }

    /// 偿付不足时 available 应该是 0，而不是减法下溢成 Panic(0x11)。
    /// 这条是把「看不懂的报错」换成「可读的错误」——运营出事时这两者差别很大
    function test_RecoverRewardTokenWhenInsolventRevertsCleanly() public {
        // 先制造真实负债：质押 + 走一天 + 触发结算
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);
        _requestUnstake(alice, 100e18);
        assertGt(staking.totalOwed(), 0, "liability booked");

        // 再把 rewardToken 转走大半，制造余额 < 负债
        vm.prank(address(staking));
        assertTrue(rewardToken.transfer(alice, 600_000e18), "top-up transfer returns true");
        assertLt(rewardToken.balanceOf(address(staking)), staking.totalOwed(), "now insolvent");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InsufficientRewardBalance.selector, 1, 0));
        _asV2().recoverERC20(address(rewardToken), 1);
    }

    /// stakingToken 依旧完全禁止，这条边界没有被放宽
    function test_RecoverStillRefusesStakingToken() public {
        vm.prank(admin);
        vm.expectRevert(StakingRewards.CannotRecoverStakingToken.selector);
        _asV2().recoverERC20(address(stakeToken), 1);
    }

    /*//////////////////////////////////////////////////////////////
                    三、emergencyWithdraw
    //////////////////////////////////////////////////////////////*/

    /// 核心用例：冷却期内本金全额退回，代价是放弃奖励，且负债同步销账
    function test_EmergencyWithdrawIgnoresCooldown() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        uint256 walletBefore = stakeToken.balanceOf(alice);
        uint256 owedLiveBefore = _asV2().totalOwedLive();

        _requestUnstake(alice, 100e18);
        // 此刻本金在冷却里，withdraw 会 revert
        (, uint256 lockedUntil) = staking.pendingUnstake(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StillLocked.selector, lockedUntil));
        staking.withdraw();

        uint256 forfeited = _asV2().earned(alice);
        assertGt(forfeited, 0, "there is a reward to give up");

        vm.prank(alice);
        _asV2().emergencyWithdraw();

        assertEq(stakeToken.balanceOf(alice) - walletBefore, 100e18, "principal returned during cooldown");
        assertEq(staking.balanceOf(alice), 0, "position cleared");
        assertEq(staking.totalSupply(), 0, "pool emptied (no seed stake in this fixture)");
        assertEq(_asV2().earned(alice), 0, "reward forfeited");

        (, uint256 unlockTime) = staking.pendingUnstake(alice);
        assertEq(unlockTime, 0, "pending request cleared");

        assertLt(staking.totalOwed(), owedLiveBefore, "liability written off");
    }

    /// 应发比负债多几 wei 的状态下，紧急退出照样要能开
    ///
    /// @dev 构造方式：1 wei 尾数让 `supply · Δ` 除以 PRECISION 有余数，每跨一个结算边界
    ///      两边各 floor 一次，跨两次之后 `earned` 就比 `totalOwed` 多 1 wei。
    ///      两个没有仓位的地址各调一次 `getReward()`，它们结算完就返回，
    ///      不改 `totalSupply`、不改 `rewardRate`，等于「纯结算两次」。
    ///      断言顺序是先证状态真的到了（`due > owed`），再断言退出结果
    function test_EmergencyWithdrawSurvivesRoundingDeficit() public {
        _stake(alice, 1e18 + 1);

        vm.warp(block.timestamp + 1);
        vm.prank(address(0xBEEF));
        _asV2().getReward();

        vm.warp(block.timestamp + 1);
        vm.prank(address(0xCAFE));
        _asV2().getReward();

        uint256 owed = staking.totalOwed();
        uint256 due = _asV2().earned(alice);
        assertGt(due, owed, "deficit state: accrued exceeds recorded liability");

        uint256 walletBefore = stakeToken.balanceOf(alice);
        vm.prank(alice);
        _asV2().emergencyWithdraw();

        assertEq(stakeToken.balanceOf(alice) - walletBefore, 1e18 + 1, "principal returned in full");
        assertEq(staking.balanceOf(alice), 0, "position cleared");
        assertEq(staking.totalSupply(), 0, "supply cleared");
        assertEq(_asV2().rewards(alice), 0, "forfeited reward cleared");
        assertEq(staking.totalOwed(), 0, "liability clamped, not underflowed");
    }

    /// 激活状态的仓位也能走紧急退出，不必先 requestUnstake
    function test_EmergencyWithdrawFromActivePosition() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        _asV2().emergencyWithdraw();

        assertEq(staking.balanceOf(alice), 0, "position cleared");
        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal back");
    }

    /// 闭环：退出前余额被负债全额占用，退出后这笔额度松散出来，变成可被 recoverERC20 取走的盈余。
    /// 如果不销账，合约会长期显示偿付不足，而钱其实就躺在里面
    /// @dev 必须用 `totalOwedLive()` 算「退出前的可用额度」：`totalOwed` 是惰性的，
    ///      直接拿它做减法会把未结算应计误当成盈余，测出来永远是「啥也没变」
    function test_ForfeitedRewardBecomesRecoverableSurplus() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 2 days);

        // 退出前：本期预算全额锁着，取 1 wei 都不行
        vm.prank(admin);
        vm.expectPartialRevert(StakingRewards.InsufficientRewardBalance.selector);
        _asV2().recoverERC20(address(rewardToken), 1);

        uint256 forfeited = _asV2().earned(alice);
        assertGt(forfeited, 0, "there is a reward to give up");

        vm.prank(alice);
        _asV2().emergencyWithdraw();

        // 退出后：负债销账，放弃的那笔正好变成可动额度
        vm.prank(admin);
        _asV2().recoverERC20(address(rewardToken), forfeited);
        assertEq(rewardToken.balanceOf(admin), forfeited, "forfeited reward recovered");

        // 只能取这么多，剩下的仍是后面几天的预算
        vm.prank(admin);
        vm.expectPartialRevert(StakingRewards.InsufficientRewardBalance.selector);
        _asV2().recoverERC20(address(rewardToken), 1);
    }

    /// 两个闸门都拉下时，本金仍然退得出来。紧急退出的语义是「退本金」，不是「发奖励」
    function test_EmergencyWithdrawWorksWhenBothGatesClosed() public {
        _stake(alice, 100e18);

        vm.startPrank(admin);
        staking.pause();
        staking.pauseClaim();
        vm.stopPrank();

        vm.prank(alice);
        _asV2().emergencyWithdraw();

        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal escapes a fully paused pool");
    }

    function test_EmergencyWithdrawRevertsWhenNothingToTake() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewardsV2.NothingToEmergencyWithdraw.selector);
        _asV2().emergencyWithdraw();
    }

    /// 不能调用第二次：状态清空后再来一次必须报错，而不是「成功转 0」
    function test_EmergencyWithdrawCannotBeRepeated() public {
        _stake(alice, 100e18);

        vm.prank(alice);
        _asV2().emergencyWithdraw();

        vm.prank(alice);
        vm.expectRevert(StakingRewardsV2.NothingToEmergencyWithdraw.selector);
        _asV2().emergencyWithdraw();
    }

    /// 一个人紧急退出，其他人的应计不受影响——份额变少只会让他们分得更多
    function test_EmergencyWithdrawDoesNotDisturbOthers() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        vm.warp(block.timestamp + 1 days);

        uint256 bobEarnedBefore = _asV2().earned(bob);

        vm.prank(alice);
        _asV2().emergencyWithdraw();

        assertEq(_asV2().earned(bob), bobEarnedBefore, "bob's accrual untouched by alice leaving");

        // alice 走后 bob 是唯一质押者，之后按全速累积
        vm.warp(block.timestamp + 1 days);
        assertGt(_asV2().earned(bob), bobEarnedBefore, "bob now earns the whole rate");
    }

    /*//////////////////////////////////////////////////////////////
                    四、V1 的核心行为在 V2 上仍然成立
    //////////////////////////////////////////////////////////////*/

    function test_StakeAndWithdrawStillWork() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);
        _requestUnstake(alice, 100e18);
        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal back");
    }

    function test_RewardAccrualStillLinear() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);
        assertEq(_asV2().earned(alice), ONE_DAY_REWARD, "accrual unchanged by the upgrade");
    }

    function test_NotifyStillRefusesUnfundedReward() public {
        // expectPartialRevert：1.5.1 里 expectRevert(bytes4) 要求完整 data 匹配，
        // 带参数的自定义错误必须用它
        vm.prank(admin);
        vm.expectPartialRevert(StakingRewards.InsufficientRewardBalance.selector);
        _asV2().notifyRewardAmount(FUND * 2);
    }

    function test_RolesSurviveUpgrade() public view {
        assertTrue(staking.hasRole(ADMIN_ROLE_ID, admin), "admin");
        assertTrue(staking.hasRole(MANAGER_ROLE, admin), "manager");
        assertTrue(staking.hasRole(GUARDIAN_ROLE_ID, admin), "guardian");
    }
}
