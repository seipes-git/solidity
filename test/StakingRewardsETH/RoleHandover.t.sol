// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title ETH 池的角色移交
/// @notice 与 ERC20 池同一套语义，差别在 `admin = address(this)`：
///         管理动作直接调，不需要 prank；外人用 alice / 新造的多签地址扮演。
///
///         这里要回答的是「治理出问题会不会连带资金面」：
///         治理锁死是运营事故，本金与奖励取不出来是资金事故，两者必须分开看。
contract ETHRoleHandoverTest is StakingRewardsETHBase {
    address internal multisig = makeAddr("multisig");
    address internal newGuardian = makeAddr("newGuardian");

    /*//////////////////////////////////////////////////////////////
                        一、正确顺序的完整移交
    //////////////////////////////////////////////////////////////*/

    function test_HandoverGrantsThenRenounces() public {
        staking.grantRole(GUARDIAN_ROLE_ID, newGuardian);
        staking.renounceRole(GUARDIAN_ROLE_ID, admin);

        assertTrue(staking.hasRole(GUARDIAN_ROLE_ID, newGuardian), "new guardian holds role");
        assertFalse(staking.hasRole(GUARDIAN_ROLE_ID, admin), "old guardian gave it up");

        // 新人能刹车
        vm.prank(newGuardian);
        staking.pause();
        assertTrue(staking.paused(), "new guardian can pause");

        // 旧人不能 —— 这一条是移交是否真的生效的唯一证据
        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.pause();
    }

    /// 移交之后，新守卫同样被「不能冻结退出」这条规则约束，权限换人不会让契约变松
    function test_NewGuardianStillCannotFreezeExits() public {
        staking.grantRole(GUARDIAN_ROLE_ID, newGuardian);
        staking.renounceRole(GUARDIAN_ROLE_ID, admin);

        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        vm.prank(newGuardian);
        staking.pause();

        // 冷却期内取不出是冷却本身的规定，与暂停无关
        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        assertEq(alice.balance, 100 ether, "principal returned after handover");
        assertEq(staking.balanceOf(alice), 0, "position cleared");
    }

    /*//////////////////////////////////////////////////////////////
                      二、ADMIN 一旦移交就真的出局
    //////////////////////////////////////////////////////////////*/

    function test_AdminHandoverIsIrreversible() public {
        staking.grantRole(ADMIN_ROLE_ID, multisig);
        staking.renounceRole(ADMIN_ROLE_ID, admin);

        // 部署者再也无法分配任何角色，包括给自己
        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.grantRole(GUARDIAN_ROLE_ID, admin);

        // 多签可以继续治理
        vm.prank(multisig);
        staking.grantRole(GUARDIAN_ROLE_ID, multisig);
        assertTrue(staking.hasRole(GUARDIAN_ROLE_ID, multisig), "multisig administers");
    }

    /// 多签接管后继承全部管理员职权，取走误转的 ERC20 是最典型的一项
    function test_MultisigInheritsRecoveryPower() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staking), 5e18);

        staking.grantRole(ADMIN_ROLE_ID, multisig);
        staking.renounceRole(ADMIN_ROLE_ID, admin);

        vm.prank(multisig);
        staking.recoverERC20(address(other), 5e18);
        assertEq(other.balanceOf(multisig), 5e18, "multisig recovered");
    }

    /*//////////////////////////////////////////////////////////////
                三、没有继承人就直接放弃 ADMIN 的后果
    //////////////////////////////////////////////////////////////*/

    /// 治理永久锁死，但资金面不受影响。
    /// 后者才是这个文件存在的理由：治理权限只挂在管理函数上，取钱路径从不检查角色
    function test_RenouncingAdminWithoutSuccessorLocksGovernanceForever() public {
        staking.renounceRole(ADMIN_ROLE_ID, admin);
        assertFalse(staking.hasRole(ADMIN_ROLE_ID, admin), "nobody holds admin");

        // 四个治理入口永久不可用
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.grantRole(ADMIN_ROLE_ID, admin);

        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setUnstakeCooldown(1 days);

        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverETH();

        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverERC20(address(rewardToken), 1);

        // 用户照常领奖、照常取回本金
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);
        _getReward(alice);
        assertApproxEqAbs(rewardToken.balanceOf(alice), ONE_DAY_REWARD, 1e6, "reward still claimable");

        _requestUnstake(alice, 10 ether);
        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);
        assertEq(alice.balance, 100 ether, "principal still withdrawable");
    }

    /// renounceRole 只能由本人执行，管理员没法替别人放弃角色
    function test_RenounceRequiresSelfConfirmation() public {
        _grantRole(GUARDIAN_ROLE_ID, guardian);

        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        staking.renounceRole(GUARDIAN_ROLE_ID, guardian);
    }
}
