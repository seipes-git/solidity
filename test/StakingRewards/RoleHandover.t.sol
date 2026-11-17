// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title 部署后的角色移交
/// @notice 部署脚本里那段 grant → renounce 的顺序是有风险的代码，这里把它写成可执行的规范。
///         要证明三件事：
///           ① 正确顺序能完成移交，且新人拿到权限、旧人真的失去；
///           ② 只移交守卫不移交管理员，是可以随时拿回来的 —— 真正的转移要连 ADMIN 一起给；
///           ③ 没有继承人就直接放弃 DEFAULT_ADMIN_ROLE，治理永久锁死，且不可恢复。
///         第 ③ 条是给未来的自己看的警示：合约虽然可升级，但没人能发起升级时，
///         代理里的代码同样换不掉——治理锁死等于把升级权一起冻住了。
contract RoleHandoverTest is StakingRewardsBase {
    address internal newGuardian = makeAddr("newGuardian");
    address internal multisig = makeAddr("multisig");

    /*//////////////////////////////////////////////////////////////
                        一、正确顺序的完整移交
    //////////////////////////////////////////////////////////////*/

    function test_HandoverGrantsThenRenounces() public {
        vm.startPrank(admin);
        staking.grantRole(GUARDIAN_ROLE_ID, newGuardian);
        // 脚本里的验证：确认写进去了才敢放弃自己的
        require(staking.hasRole(GUARDIAN_ROLE_ID, newGuardian), "grant failed");
        staking.renounceRole(GUARDIAN_ROLE_ID, admin);
        vm.stopPrank();

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

    /// 移交之后，新守卫同样被「不能冻结退出」这条规则约束。
    /// 权限换人不会让契约变松，这是设计里最需要钉住的不变量。
    /// @dev 必须用带冷却的基座：cooldown = 0 时 requestUnstake 已直接到账，
    ///      withdraw() 全程不被调用，给 withdraw 挂上 whenNotPaused 也测不出来（A-21）
    function test_NewGuardianStillCannotFreezeExits() public {
        _deploy(COOLDOWN);

        vm.startPrank(admin);
        staking.grantRole(GUARDIAN_ROLE_ID, newGuardian);
        staking.renounceRole(GUARDIAN_ROLE_ID, admin);
        vm.stopPrank();

        _stake(alice, 100e18);
        _requestUnstake(alice, 100e18);

        vm.prank(newGuardian);
        staking.pause();

        // 冷却期内取不出是冷却本身的规定，与暂停无关
        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal returned after handover");
        assertEq(staking.balanceOf(alice), 0, "shares cleared");
    }

    /// 多签接管后继承全部管理员职权，回收误转代币是最典型的一项
    function test_MultisigInheritsRecoveryPower() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staking), 5e18);

        vm.startPrank(admin);
        staking.grantRole(ADMIN_ROLE_ID, multisig);
        staking.renounceRole(ADMIN_ROLE_ID, admin);
        vm.stopPrank();

        vm.prank(multisig);
        staking.recoverERC20(address(other), 5e18);
        assertEq(other.balanceOf(multisig), 5e18, "multisig recovered");
    }

    /*//////////////////////////////////////////////////////////////
            二、只拆守卫是「软拆分」：部署者仍能拿回来
    //////////////////////////////////////////////////////////////*/

    /// 演示一个容易误解的地方：只要还握着 DEFAULT_ADMIN_ROLE，
    /// 放弃了 GUARDIAN 也能随时授予自己。所以「拆守卫」降低的是热钱包暴露面，
    /// 不是权限转移。真正的转移必须连 ADMIN 一起移交
    function test_GuardianHandoverIsReversibleWhileAdminHeld() public {
        vm.startPrank(admin);
        staking.renounceRole(GUARDIAN_ROLE_ID, admin);
        vm.stopPrank();

        assertFalse(staking.hasRole(GUARDIAN_ROLE_ID, admin), "gave up guardian");

        // DEFAULT_ADMIN_ROLE 是所有角色的 admin，所以随时能拿回来
        vm.prank(admin);
        staking.grantRole(GUARDIAN_ROLE_ID, admin);
        assertTrue(staking.hasRole(GUARDIAN_ROLE_ID, admin), "taken back at will");
    }

    /// 反过来：ADMIN 一旦移交，部署者就真的出局了
    function test_AdminHandoverIsIrreversible() public {
        vm.startPrank(admin);
        staking.grantRole(ADMIN_ROLE_ID, multisig);
        staking.renounceRole(ADMIN_ROLE_ID, admin);
        vm.stopPrank();

        // 部署者再也无法分配任何角色，包括给自己
        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.grantRole(GUARDIAN_ROLE_ID, admin);

        // 多签可以继续治理
        vm.prank(multisig);
        staking.grantRole(GUARDIAN_ROLE_ID, multisig);
        assertTrue(staking.hasRole(GUARDIAN_ROLE_ID, multisig), "multisig administers");
    }

    /*//////////////////////////////////////////////////////////////
                  三、错误顺序的后果（警示用例）
    //////////////////////////////////////////////////////////////*/

    /// 没有继承人就直接放弃 DEFAULT_ADMIN_ROLE：治理永久锁死。
    /// 这条测试存在的意义不是「验证功能」，是「记录一条不能再犯的错」
    function test_RenouncingAdminWithoutSuccessorLocksGovernanceForever() public {
        vm.prank(admin);
        staking.renounceRole(ADMIN_ROLE_ID, admin);

        assertFalse(staking.hasRole(ADMIN_ROLE_ID, admin), "nobody holds admin");

        // 所有治理入口永久不可用
        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.grantRole(ADMIN_ROLE_ID, admin);

        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.setUnstakeCooldown(1 days);

        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.recoverERC20(address(rewardToken), 1);

        // 但资金面不受影响：锁死的是治理，不是用户的钱。
        // 这是因为所有权限都只挂在管理函数上，提款路径从不检查角色
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);
        _getReward(alice);
        assertEq(rewardToken.balanceOf(alice), ONE_DAY_REWARD, "user funds still safe");

        _requestUnstake(alice, 100e18);
        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal still withdrawable");
    }

    /// renounceRole 只能由本人执行，管理员没法替别人放弃角色。
    /// 这条防止「管理员反手把别人的权限清空」
    function test_RenounceRequiresSelfConfirmation() public {
        _grantRole(GUARDIAN_ROLE_ID, guardian);

        vm.prank(admin);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        staking.renounceRole(GUARDIAN_ROLE_ID, guardian);
    }
}
