// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title 权限分层：谁可以做什么
/// @notice 三个角色是刻意拆开的，这一组测试要证明拆分真的生效、不是摆设：
///           REWARDS_MANAGER_ROLE  改奖励参数（注入、周期、最小质押额）
///           GUARDIAN_ROLE         只能暂停恢复，改不了任何参数
///           DEFAULT_ADMIN_ROLE    改冷却、回收误转代币、分配角色
/// @dev 权限测试最容易写成「测了但没测到」：只断言状态变量变了，
///      却没验证「非授权者调用会失败」。这里每个正向用例都配一个反向用例。
contract AccessTest is StakingRewardsBase {
    /*//////////////////////////////////////////////////////////////
                            一、初始角色分配
    //////////////////////////////////////////////////////////////*/

    function test_DeployerHoldsAllRoles() public view {
        assertTrue(staking.hasRole(ADMIN_ROLE_ID, admin), "admin");
        assertTrue(staking.hasRole(MANAGER_ROLE, admin), "manager");
        assertTrue(staking.hasRole(GUARDIAN_ROLE_ID, admin), "guardian");
    }

    function test_OtherAddressesHaveNoRoles() public view {
        assertFalse(staking.hasRole(MANAGER_ROLE, alice), "alice no manager");
        assertFalse(staking.hasRole(GUARDIAN_ROLE_ID, alice), "alice no guardian");
        assertFalse(staking.hasRole(ADMIN_ROLE_ID, alice), "alice no admin");
    }

    /*//////////////////////////////////////////////////////////////
                    二、无权限地址调用管理函数全部失败
    //////////////////////////////////////////////////////////////*/

    function test_NotifyRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.notifyRewardAmount(1e18);
    }

    function test_SetDurationRejectsOutsider() public {
        vm.warp(staking.periodFinish());

        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setRewardsDuration(1 days);
    }

    function test_SetMinStakeRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setMinStakeAmount(1e18);
    }

    function test_SetCooldownRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setUnstakeCooldown(1 days);
    }

    function test_RecoverRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverERC20(address(rewardToken), 1);
    }

    function test_PauseRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.pause();
    }

    function test_PauseClaimRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.pauseClaim();
    }

    function test_UnpauseRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.unpause();
    }

    /// 表驱动的兜底：新加管理函数时，往数组里加一行就能覆盖，
    /// 不用再复制一遍「换个函数名」的测试。
    /// 断言必须比「调用失败」更严：要确认失败原因是权限，不是业务状态。
    /// 只判 assertFalse 的话，删掉 `unpauseClaim` 的 onlyRole 仍然 PASS——
    /// 因为 claimPaused == false 时它本来就 revert ExpectedPause（A-23）
    function test_AllAdminFunctionsRejectOutsider() public {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(StakingRewards.notifyRewardAmount, (1e18));
        calls[1] = abi.encodeCall(StakingRewards.setRewardsDuration, (1 days));
        calls[2] = abi.encodeCall(StakingRewards.setMinStakeAmount, (1e18));
        calls[3] = abi.encodeCall(StakingRewards.setUnstakeCooldown, (1 days));
        calls[4] = abi.encodeCall(StakingRewards.recoverERC20, (address(rewardToken), 1));
        calls[5] = abi.encodeCall(StakingRewards.pause, ());
        calls[6] = abi.encodeCall(StakingRewards.unpause, ());
        calls[7] = abi.encodeCall(StakingRewards.pauseClaim, ());
        calls[8] = abi.encodeCall(StakingRewards.unpauseClaim, ());

        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = _callAs(alice, calls[i]);
            assertFalse(ok, "outsider must not succeed");
            assertEq(
                _revertSelector(ret),
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                "must fail on authorization, not on business state"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                      三、角色边界：授权不等于全权
    //////////////////////////////////////////////////////////////*/

    /// 拿到 REWARDS_MANAGER_ROLE 之后能做奖励参数，但仍然动不了冷却和回收
    function test_ManagerCannotTouchAdminOnlyFunctions() public {
        _grantRole(MANAGER_ROLE, bob);

        // 正向：改奖励参数可以
        vm.prank(bob);
        staking.setMinStakeAmount(5e18);
        assertEq(staking.minStakeAmount(), 5e18, "manager can set min stake");

        // 反向：改冷却、回收代币都不行
        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setUnstakeCooldown(1 days);

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverERC20(address(rewardToken), 1);
    }

    /// 守卫只能暂停恢复，改不了奖励曲线 —— 这是拆角色的核心理由
    function test_GuardianCannotChangeRewardParams() public {
        _grantRole(GUARDIAN_ROLE_ID, guardian);

        // 守卫能做的是「两个闸门」：停存入、停发奖
        vm.prank(guardian);
        staking.pause();
        assertTrue(staking.paused(), "guardian can pause deposits");

        vm.prank(guardian);
        staking.pauseClaim();
        assertTrue(staking.claimPaused(), "guardian can pause claims");

        // 但改不了任何参数
        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.notifyRewardAmount(1e18);

        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setMinStakeAmount(1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        四、授权与撤销的闭环
    //////////////////////////////////////////////////////////////*/

    function test_GrantAndRevokeRoundTrip() public {
        _grantRole(MANAGER_ROLE, bob);
        assertTrue(staking.hasRole(MANAGER_ROLE, bob), "granted");

        vm.prank(bob);
        staking.setMinStakeAmount(3e18);
        assertEq(staking.minStakeAmount(), 3e18, "works while granted");

        vm.prank(admin);
        staking.revokeRole(MANAGER_ROLE, bob);
        assertFalse(staking.hasRole(MANAGER_ROLE, bob), "revoked");

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setMinStakeAmount(4e18);
    }

    /// 只有 DEFAULT_ADMIN_ROLE 能分配角色，管理员角色本身不能自我复制
    function test_ManagerCannotGrantRoles() public {
        _grantRole(MANAGER_ROLE, bob);

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.grantRole(ADMIN_ROLE_ID, bob);
    }
}
