// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {StakingRewardsV2Mock} from "./mocks/StakingRewardsV2Mock.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title UUPS 升级通路
/// @notice 这一组测的不是业务逻辑，而是「代理这一层有没有接对」。
///         代理模式有四种典型事故，每一种都在下面有对应用例：
///           ① 实现合约被人直接 initialize，抢走角色；
///           ② 升级权限没收紧，任何人都能换逻辑；
///           ③ 升级之后用户仓位、奖励、暂停状态丢了；
///           ④ 直接对实现合约调用升级，或者把代理指向一个没有代码的地址。
///
/// @dev 这里用 `StakingRewardsV2Mock` 验证通路。它只加函数、不加状态变量，
///      所以「升级后状态没丢」这个结论不会被布局差异干扰
contract UpgradeTest is StakingRewardsBase {
    /// 与 ERC1967Utils 里的事件签名一致，测试侧重新声明才能 expectEmit
    event Upgraded(address indexed implementation);

    bytes32 internal constant UPGRADER_ROLE_ID = keccak256("UPGRADER_ROLE");

    StakingRewardsV2Mock internal v2;

    /// @dev 同一个代理地址，用 V2 的 ABI 去看它。升级前后 `staking` 变量不用换，
    ///      代理地址也从没变过——变的只是那段被 delegatecall 的代码
    function _asV2() internal view returns (StakingRewardsV2Mock) {
        return StakingRewardsV2Mock(address(staking));
    }

    function setUp() public override {
        super.setUp();
        v2 = new StakingRewardsV2Mock();
    }

    /*//////////////////////////////////////////////////////////////
                        一、代理与实现的接线是否正确
    //////////////////////////////////////////////////////////////*/

    /// 代理存的实现地址必须等于我们部署的那个，且业务状态读的是代理自己的存储
    function test_ProxyPointsToImplementation() public view {
        assertEq(staking.implementation(), implementation, "proxy -> implementation");
        assertEq(address(staking.stakingToken()), address(stakeToken), "state lives in proxy storage");
        assertEq(staking.rewardsDuration(), DURATION, "duration initialized");
    }

    /// 实现合约自己不能被初始化。构造函数里的 _disableInitializers 就是为这一条
    function test_ImplementationCannotBeInitializedDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StakingRewards(implementation).initialize(stakeToken, rewardToken, DURATION, 0);
    }

    /// 代理也不能初始化第二次：initializer 修饰器按版本号记账，version 1 已用过
    function test_ProxyCannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        staking.initialize(stakeToken, rewardToken, DURATION, 0);
    }

    /// 直接对实现合约调用升级必须失败（onlyProxy）。不加这道闸，
    /// 有人能在实现合约上写一个假的实现指针，把后来接管的代理带偏
    function test_UpgradeOnImplementationReverts() public {
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        StakingRewards(implementation).upgradeToAndCall(address(v2), "");
    }

    /// proxiableUUID 只能在实现合约上读。在代理上下文里 address(this) != __self，必须拒
    function test_ProxiableUUIDRevertsThroughProxy() public {
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        staking.proxiableUUID();
    }

    /*//////////////////////////////////////////////////////////////
                            二、谁能升级
    //////////////////////////////////////////////////////////////*/

    function test_NonUpgraderCannotUpgrade() public {
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.upgradeToAndCall(address(v2), "");
    }

    /// 守卫和运营都不能升级：升级权是独立的一项，不能从管理参数的角色里溢出
    function test_ManagerAndGuardianCannotUpgrade() public {
        _grantRole(GUARDIAN_ROLE_ID, guardian);
        _grantRole(MANAGER_ROLE, bob);

        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.upgradeToAndCall(address(v2), "");

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.upgradeToAndCall(address(v2), "");
    }

    function test_UpgraderCanUpgrade() public {
        assertEq(staking.implementation(), implementation, "before");

        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(v2));
        _upgradeTo(address(v2));

        assertEq(staking.implementation(), address(v2), "proxy now points to v2");
    }

    /// 放弃升级权之后就真的升不了。这条是「角色移交」那套流程的兜底验证
    function test_RenouncedUpgraderCannotUpgrade() public {
        vm.startPrank(admin);
        staking.grantRole(UPGRADER_ROLE_ID, bob);
        staking.renounceRole(UPGRADER_ROLE_ID, admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.upgradeToAndCall(address(v2), "");

        vm.prank(bob);
        staking.upgradeToAndCall(address(v2), "");
        assertEq(staking.implementation(), address(v2), "new upgrader takes over");
    }

    /*//////////////////////////////////////////////////////////////
                          三、升级之后状态还在吗
    //////////////////////////////////////////////////////////////*/

    /// 这是整个「可升级」最核心的一条：换实现不能动数据。
    /// 代理模式里数据一直在代理地址的存储里，实现合约只是一段被 delegatecall 的代码
    function test_UpgradePreservesAllState() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        uint256 posBefore = staking.balanceOf(alice);
        uint256 supplyBefore = staking.totalSupply();
        uint256 earnedBefore = staking.earned(alice);
        uint256 rateBefore = staking.rewardRate();
        uint256 finishBefore = staking.periodFinish();
        uint256 owedBefore = staking.totalOwed();

        _upgradeTo(address(v2));

        assertEq(staking.balanceOf(alice), posBefore, "position");
        assertEq(staking.totalSupply(), supplyBefore, "totalSupply");
        assertEq(staking.earned(alice), earnedBefore, "earned");
        assertEq(staking.rewardRate(), rateBefore, "rewardRate");
        assertEq(staking.periodFinish(), finishBefore, "periodFinish");
        assertEq(staking.totalOwed(), owedBefore, "totalOwed");
        assertTrue(staking.hasRole(MANAGER_ROLE, admin), "roles survive");
        assertEq(_asV2().version(), 2, "new code is live");
    }

    /// 暂停状态也必须跨升级保留。否则一次升级会把「管理员刚拉下的闸门」悄悄恢复
    function test_UpgradePreservesPauseState() public {
        vm.prank(admin);
        staking.pause();
        vm.prank(admin);
        staking.pauseClaim();

        _upgradeTo(address(v2));

        assertTrue(staking.paused(), "paused survives");
        assertTrue(staking.claimPaused(), "claimPaused survives");
    }

    /// 升级后旧逻辑照常工作：本金该退还是退，不是「升级完就换了个合约」
    function test_UpgradeKeepsBusinessLogicWorking() public {
        _stake(alice, 100e18);
        _upgradeTo(address(v2));

        vm.warp(block.timestamp + 1 days);
        _requestUnstake(alice, 100e18);

        assertEq(staking.balanceOf(alice), 0, "position cleared after upgrade");
        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal returned after upgrade");
    }

    function test_V2NewFunctionWorks() public {
        _stake(alice, 250e18);
        _upgradeTo(address(v2));

        assertEq(_asV2().version(), 2);
        assertEq(_asV2().loyaltyScore(alice), 250, "new view sees old state");
        assertEq(_asV2().extraInfo(), "v2");
    }

    /*//////////////////////////////////////////////////////////////
                            四、升级目标的边界
    //////////////////////////////////////////////////////////////*/

    /// 指向一个没有代码的地址会把代理变成砖：之后所有调用都返回空数据、全部 revert，
    /// 而且没有任何入口改回来（upgradeToAndCall 自己也是代理上的调用）
    /// @dev 这里不断言具体错误类型，因为第一个拦住它的不是 OZ 的 custom error：
    ///      `_upgradeToAndCallUUPS` 会先调 `newImplementation.proxiableUUID()`，
    ///      而对没有代码的地址调接口时，Solidity 在调用前就插入了 extcodesize 检查，
    ///      抛的是编译器内置的无 selector revert（"call to non-contract address"）。
    ///      ERC1967InvalidImplementation 在这条路径上根本轮不到。
    ///      **所以这里的 `vm.expectRevert()` 是裸的：本条只验「升级失败」，不验 revert 原因**；
    ///      强度靠下面两行状态断言补——失败之后代理与参数都没被改动
    function test_UpgradeToNonContractReverts() public {
        address dead = makeAddr("dead");

        vm.prank(admin);
        vm.expectRevert();
        staking.upgradeToAndCall(dead, "");

        // 失败之后代理仍指向原来的实现，没有留下半套状态
        assertEq(staking.implementation(), implementation, "proxy intact after failed upgrade");
        assertEq(staking.rewardsDuration(), DURATION, "state intact after failed upgrade");
    }
}
