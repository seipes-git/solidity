// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title ETH 池的权限分层
/// @notice 角色划分与 ERC20 池一致，且多一条特殊约束：`recoverETH` 是能把池子掏空的函数，
///         必须只挂在 DEFAULT_ADMIN_ROLE 上，不能顺手给到 REWARDS_MANAGER。
///         这里的每个正向用例都配一个反向用例——只测「能改」不测「不能改」等于没测。
contract ETHAccessTest is StakingRewardsETHBase {
    /*//////////////////////////////////////////////////////////////
                            一、初始角色分配
    //////////////////////////////////////////////////////////////*/

    function test_DeployerHoldsAllRoles() public view {
        assertTrue(staking.hasRole(ADMIN_ROLE_ID, admin), "admin");
        assertTrue(staking.hasRole(MANAGER_ROLE, admin), "manager");
        assertTrue(staking.hasRole(GUARDIAN_ROLE_ID, admin), "guardian");
    }

    function test_OutsidersHaveNoRoles() public view {
        assertFalse(staking.hasRole(MANAGER_ROLE, alice), "alice no manager");
        assertFalse(staking.hasRole(GUARDIAN_ROLE_ID, alice), "alice no guardian");
        assertFalse(staking.hasRole(ADMIN_ROLE_ID, alice), "alice no admin");
    }

    /*//////////////////////////////////////////////////////////////
                    二、无权限地址调用管理函数全部失败
    //////////////////////////////////////////////////////////////*/

    /// 表驱动兜底：新加管理函数时往数组里加一行就能覆盖。
    /// 断言必须比「调用失败」更严——要确认失败原因是权限，不是业务状态。
    /// 只判 assertFalse 的话，删掉 onlyRole 仍然可能 PASS（比如函数本来就因参数不合法 revert）
    function test_AllGovernanceFunctionsRejectOutsider() public {
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(StakingRewardsETH.notifyRewardAmount, (1e18));
        calls[1] = abi.encodeCall(StakingRewardsETH.setRewardsDuration, (1 days));
        calls[2] = abi.encodeCall(StakingRewardsETH.setMinStakeAmount, (1 ether));
        calls[3] = abi.encodeCall(StakingRewardsETH.setUnstakeCooldown, (1 days));
        calls[4] = abi.encodeCall(StakingRewardsETH.recoverERC20, (address(rewardToken), 1));
        calls[5] = abi.encodeCall(StakingRewardsETH.recoverETH, ());
        calls[6] = abi.encodeCall(StakingRewardsETH.pause, ());
        calls[7] = abi.encodeCall(StakingRewardsETH.unpause, ());
        calls[8] = abi.encodeCall(StakingRewardsETH.pauseClaim, ());
        calls[9] = abi.encodeCall(StakingRewardsETH.unpauseClaim, ());

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

    function test_RecoverETHRejectsOutsider() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverETH();
    }

    /// 顺序不能反：未暂停时 `unpause()` 本来就 revert `ExpectedPause`，
    /// 那个 revert 会把「权限」这一层盖住。先真的暂停，外人来恢复
    function test_UnpauseRejectsOutsider() public {
        staking.pause();

        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.unpause();

        assertTrue(staking.paused(), "still paused");
    }

    /*//////////////////////////////////////////////////////////////
                      三、角色边界：授权不等于全权
    //////////////////////////////////////////////////////////////*/

    /// 拿到 REWARDS_MANAGER_ROLE 之后能做奖励参数，但仍然动不了冷却、回收和 ETH 余量
    function test_ManagerCannotTouchAdminOnlyFunctions() public {
        _grantRole(MANAGER_ROLE, bob);

        // 正向：改奖励参数可以
        vm.prank(bob);
        staking.setMinStakeAmount(5 ether);
        assertEq(staking.minStakeAmount(), 5 ether, "manager can set min stake");

        // 反向：改冷却、取 ETH 余量都不行
        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setUnstakeCooldown(1 days);

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverETH();
    }

    /// 守卫只能拉两个闸门，改不了奖励曲线 —— 这是拆角色的核心理由
    function test_GuardianCannotChangeRewardParams() public {
        _grantRole(GUARDIAN_ROLE_ID, guardian);

        vm.prank(guardian);
        staking.pause();
        assertTrue(staking.paused(), "guardian can pause deposits");

        vm.startPrank(guardian);
        staking.unpause();
        staking.pauseClaim();
        vm.stopPrank();
        assertTrue(staking.claimPaused(), "guardian can pause claims");

        // 但改不了任何参数，也动不了钱
        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.notifyRewardAmount(1e18);

        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setMinStakeAmount(1 ether);

        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverETH();
    }

    /*//////////////////////////////////////////////////////////////
                        四、授权与撤销的闭环
    //////////////////////////////////////////////////////////////*/

    function test_GrantAndRevokeRoundTrip() public {
        _grantRole(MANAGER_ROLE, bob);
        assertTrue(staking.hasRole(MANAGER_ROLE, bob), "granted");

        vm.prank(bob);
        staking.setMinStakeAmount(3 ether);
        assertEq(staking.minStakeAmount(), 3 ether, "works while granted");

        staking.revokeRole(MANAGER_ROLE, bob);
        assertFalse(staking.hasRole(MANAGER_ROLE, bob), "revoked");

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setMinStakeAmount(4 ether);
    }

    /// 只有 DEFAULT_ADMIN_ROLE 能分配角色，管理员角色本身不能自我复制
    function test_ManagerCannotGrantRoles() public {
        _grantRole(MANAGER_ROLE, bob);

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.grantRole(ADMIN_ROLE_ID, bob);
    }
}
