// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title 暂停开关：只冻结入口，不冻结出口
/// @notice 这一组是整个合约里最值得讲的设计取舍。
///         很多项目把 pause 挂在 withdraw 上，紧急情况下用户本金被锁在里面；
///         这里的 pause 只挡 stake，解押、提取、领奖励始终可用。
///         测试用 cooldown = 1 天搭建，因为只有冷却模式下「withdraw」这一步才真实存在，
///         否则「暂停不影响 withdraw」会因为没东西可取而变成假绿。
contract PauseTest is StakingRewardsBase {
    /// 与 Pausable 里的事件签名一致，测试合约不继承它，这里重新声明才能 expectEmit
    event Paused(address account);
    event ClaimPaused(address indexed account);
    event ClaimUnpaused(address indexed account);

    function setUp() public override {
        vm.warp(1_700_000_000);
        _deploy(COOLDOWN);
        _grantRole(GUARDIAN_ROLE_ID, guardian);
    }

    /*//////////////////////////////////////////////////////////////
                            一、暂停生效
    //////////////////////////////////////////////////////////////*/

    function test_PauseBlocksStake() public {
        vm.prank(guardian);
        staking.pause();

        assertTrue(staking.paused(), "paused");

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stake(100e18);
    }

    function test_PauseEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit Paused(guardian);

        vm.prank(guardian);
        staking.pause();
    }

    function test_UnpauseRestoresStake() public {
        vm.prank(guardian);
        staking.pause();

        vm.prank(guardian);
        staking.unpause();
        assertFalse(staking.paused(), "unpaused");

        _stake(alice, 100e18);
        assertEq(staking.balanceOf(alice), 100e18, "stake works again");
    }

    /*//////////////////////////////////////////////////////////////
                    二、暂停期间退出路径全部畅通
    //////////////////////////////////////////////////////////////*/

    function test_PauseAllowsRequestUnstake() public {
        _stake(alice, 100e18);

        vm.prank(guardian);
        staking.pause();

        // 暂停中依然可以发起解押
        _requestUnstake(alice, 40e18);
        (uint256 pending,) = staking.pendingUnstake(alice);
        assertEq(pending, 40e18, "unstack request accepted while paused");
    }

    function test_PauseAllowsWithdraw() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18);

        vm.prank(guardian);
        staking.pause();

        vm.warp(block.timestamp + COOLDOWN);

        // 关键断言：管理员暂停的手伸不到用户的本金
        _withdraw(alice);
        assertEq(stakeToken.balanceOf(alice), 940e18, "principal withdrawable while paused");
    }

    function test_PauseAllowsGetReward() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(guardian);
        staking.pause();

        _getReward(alice);
        assertEq(rewardToken.balanceOf(alice), ONE_DAY_REWARD, "reward claimable while paused");
    }

    function test_PauseAllowsExit() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(guardian);
        staking.pause();

        vm.prank(alice);
        staking.exit();

        // exit = requestUnstake + getReward，两步都不受暂停影响
        assertEq(staking.balanceOf(alice), 0, "shares cleared");
        assertEq(rewardToken.balanceOf(alice), ONE_DAY_REWARD, "reward paid");
        (uint256 pending,) = staking.pendingUnstake(alice);
        assertEq(pending, 100e18, "principal queued for withdrawal");
    }

    /*//////////////////////////////////////////////////////////////
                      三、暂停不影响奖励继续累积
    //////////////////////////////////////////////////////////////*/

    /// 暂停只是禁止新资金进入，已在池内的仓位照常计息——
    /// 否则等于用暂停把用户的收益也一起冻掉了
    function test_PauseDoesNotStopAccrual() public {
        _stake(alice, 100e18);

        vm.prank(guardian);
        staking.pause();

        vm.warp(block.timestamp + 1 days);
        assertEq(staking.earned(alice), ONE_DAY_REWARD, "accrual continues while paused");
    }

    /*//////////////////////////////////////////////////////////////
              四、领取暂停：把「本金」和「奖励」分成两级闸门
    //////////////////////////////////////////////////////////////*/

    /// 奖励发放可以被单独冻结，这是和「暂停存入」完全独立的开关
    function test_PauseClaimBlocksGetReward() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(guardian);
        staking.pauseClaim();
        assertTrue(staking.claimPaused(), "claim paused");

        vm.prank(alice);
        vm.expectRevert(StakingRewards.ClaimIsPaused.selector);
        staking.getReward();
    }

    /// 关键断言：停发奖励的手伸不到本金
    function test_PauseClaimDoesNotBlockWithdraw() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 100e18);

        vm.prank(guardian);
        staking.pauseClaim();

        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal unaffected by claim pause");
    }

    function test_PauseClaimDoesNotBlockRequestUnstake() public {
        _stake(alice, 100e18);

        vm.prank(guardian);
        staking.pauseClaim();

        _requestUnstake(alice, 40e18);
        (uint256 pending,) = staking.pendingUnstake(alice);
        assertEq(pending, 40e18, "unstake still allowed");
    }

    /// exit 的语义是「退出」，不能因为发奖被暂停就整笔失败——
    /// 否则用户想走都走不掉，那正是这套设计要避免的局面
    function test_ExitSkipsRewardWhenClaimPaused() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(guardian);
        staking.pauseClaim();

        vm.prank(alice);
        staking.exit(); // 不 revert

        assertEq(staking.balanceOf(alice), 0, "shares cleared");
        assertEq(rewardToken.balanceOf(alice), 0, "reward not paid");
        (uint256 pending,) = staking.pendingUnstake(alice);
        assertEq(pending, 100e18, "principal still queued");
        // 奖励没有丢，只是留在账上等恢复
        assertEq(staking.rewards(alice), ONE_DAY_REWARD, "reward kept on the books");
    }

    /// 暂停期间奖励照常累积，恢复后一次补齐 —— 用户不因为停发而损失
    function test_RewardAccruesWhileClaimPausedAndPaidAfterUnpause() public {
        _stake(alice, 100e18);

        vm.prank(guardian);
        staking.pauseClaim();

        vm.warp(block.timestamp + 2 days);
        assertEq(staking.earned(alice), ONE_DAY_REWARD * 2, "accrues while claim is paused");

        vm.prank(guardian);
        staking.unpauseClaim();
        assertFalse(staking.claimPaused(), "resumed");

        _getReward(alice);
        assertEq(rewardToken.balanceOf(alice), ONE_DAY_REWARD * 2, "full reward paid after resume");
    }

    function test_PauseClaimTwiceReverts() public {
        vm.prank(guardian);
        staking.pauseClaim();

        vm.prank(guardian);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.pauseClaim();
    }

    function test_UnpauseClaimWhenActiveReverts() public {
        vm.prank(guardian);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        staking.unpauseClaim();
    }

    function test_PauseClaimEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit ClaimPaused(guardian);

        vm.prank(guardian);
        staking.pauseClaim();

        vm.expectEmit(true, false, false, true, address(staking));
        emit ClaimUnpaused(guardian);

        vm.prank(guardian);
        staking.unpauseClaim();
    }

    /// 两个开关彼此独立：恢复存入不会顺手恢复发奖，反之亦然
    function test_BothSwitchesAreIndependent() public {
        _stake(alice, 100e18);

        vm.prank(guardian);
        staking.pause();
        vm.prank(guardian);
        staking.pauseClaim();

        // 只恢复存入
        vm.prank(guardian);
        staking.unpause();

        assertFalse(staking.paused(), "deposit resumed");
        assertTrue(staking.claimPaused(), "claim still paused");

        vm.prank(alice);
        vm.expectRevert(StakingRewards.ClaimIsPaused.selector);
        staking.getReward();
    }
}
