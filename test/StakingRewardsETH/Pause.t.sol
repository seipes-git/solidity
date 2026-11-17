// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ETH 池的两级闸门：只冻入口，不冻出口
/// @notice 这里的取舍和 ERC20 池完全一致：pause 只挡 stake，
///         解押、提取、领奖始终可用。差异在于 ETH 池的退出路径会真的转 ETH 出去，
///         所以「暂停期间还能不能拿到钱」是能直接观测到的，不存在假绿。
contract ETHPauseTest is StakingRewardsETHBase {
    /*//////////////////////////////////////////////////////////////
                            一、暂停生效
    //////////////////////////////////////////////////////////////*/

    function test_PauseBlocksStake() public {
        staking.pause();
        assertTrue(staking.paused(), "paused");

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stake{value: 1 ether}();
    }

    function test_UnpauseRestoresStake() public {
        staking.pause();
        staking.unpause();
        assertFalse(staking.paused(), "unpaused");

        _stake(alice, 10 ether);
        assertEq(staking.balanceOf(alice), 10 ether, "stake works again");
    }

    function test_PauseTwiceReverts() public {
        staking.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.pause();
    }

    /*//////////////////////////////////////////////////////////////
                    二、暂停期间退出路径全部畅通
    //////////////////////////////////////////////////////////////*/

    function test_PauseAllowsRequestUnstake() public {
        _stake(alice, 10 ether);
        staking.pause();

        _requestUnstake(alice, 10 ether);
        assertEq(staking.totalPending(), 10 ether, "unstake request accepted while paused");
    }

    function test_PauseAllowsWithdraw() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);
        staking.pause();

        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        // 关键断言：管理员暂停的手伸不到用户的本金
        assertEq(alice.balance, 100 ether, "principal withdrawable while paused");
    }

    function test_PauseAllowsGetReward() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);
        staking.pause();

        _getReward(alice);
        assertApproxEqAbs(rewardToken.balanceOf(alice), ONE_DAY_REWARD, 1e6, "reward claimable while paused");
    }

    function test_PauseAllowsExit() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);
        staking.pause();

        vm.prank(alice);
        staking.exit();

        // exit = requestUnstake + getReward，两步都不受暂停影响
        assertEq(staking.balanceOf(alice), 0, "shares cleared");
        assertApproxEqAbs(rewardToken.balanceOf(alice), ONE_DAY_REWARD, 1e6, "reward paid");
        assertEq(staking.totalPending(), 10 ether, "principal queued for withdrawal");
    }

    /// 暂停只是禁止新资金进入，已在池内的仓位照常计息
    function test_PauseDoesNotStopAccrual() public {
        _stake(alice, 10 ether);
        staking.pause();

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD, 1e6, "accrual continues while paused");
    }

    /*//////////////////////////////////////////////////////////////
              三、领取暂停：把「本金」和「奖励」分成两级闸门
    //////////////////////////////////////////////////////////////*/

    function test_PauseClaimBlocksGetReward() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        staking.pauseClaim();
        assertTrue(staking.claimPaused(), "claim paused");

        vm.prank(alice);
        vm.expectRevert(StakingRewardsETH.ClaimIsPaused.selector);
        staking.getReward();
    }

    /// 关键断言：停发奖励的手伸不到本金
    function test_PauseClaimDoesNotBlockWithdraw() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        staking.pauseClaim();

        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        assertEq(alice.balance, 100 ether, "principal unaffected by claim pause");
    }

    function test_PauseClaimDoesNotBlockRequestUnstake() public {
        _stake(alice, 10 ether);

        staking.pauseClaim();

        _requestUnstake(alice, 10 ether);
        assertEq(staking.totalPending(), 10 ether, "unstake still allowed");
    }

    /// exit 的语义是「退出」，不能因为发奖被暂停就整笔失败
    function test_ExitSkipsRewardWhenClaimPaused() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        staking.pauseClaim();

        vm.prank(alice);
        staking.exit(); // 不 revert

        assertEq(staking.balanceOf(alice), 0, "shares cleared");
        assertEq(rewardToken.balanceOf(alice), 0, "reward not paid");
        assertEq(staking.totalPending(), 10 ether, "principal still queued");
        // 奖励没有丢，只是留在账上等恢复
        assertApproxEqAbs(staking.rewards(alice), ONE_DAY_REWARD, 1e6, "reward kept on the books");
    }

    /// 暂停期间奖励照常累积，恢复后一次补齐 —— 用户不因为停发而损失
    function test_RewardAccruesWhileClaimPausedAndPaidAfterUnpause() public {
        _stake(alice, 10 ether);

        staking.pauseClaim();

        vm.warp(block.timestamp + 2 days);
        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD * 2, 1e6, "accrues while claim is paused");

        staking.unpauseClaim();
        assertFalse(staking.claimPaused(), "resumed");

        _getReward(alice);
        assertApproxEqAbs(rewardToken.balanceOf(alice), ONE_DAY_REWARD * 2, 1e6, "full reward paid after resume");
    }

    function test_PauseClaimTwiceReverts() public {
        staking.pauseClaim();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.pauseClaim();
    }

    function test_UnpauseClaimWhenActiveReverts() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        staking.unpauseClaim();
    }

    /// 两个开关彼此独立：恢复存入不会顺手恢复发奖
    function test_BothSwitchesAreIndependent() public {
        _stake(alice, 10 ether);

        staking.pause();
        staking.pauseClaim();

        staking.unpause();

        assertFalse(staking.paused(), "deposit resumed");
        assertTrue(staking.claimPaused(), "claim still paused");

        vm.prank(alice);
        vm.expectRevert(StakingRewardsETH.ClaimIsPaused.selector);
        staking.getReward();
    }
}
