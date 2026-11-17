// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "../StakingRewards/StakingRewardsBase.sol";
import {StakingRewardsV2} from "../../src/StakingRewardsV2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title V1 → V2 的真实升级：20 项状态快照
/// @notice 这个文件只回答一个问题：**换掉实现合约之后，代理里的数据有没有变**。
///         升级出错不会报错，只会让用户的仓位、奖励、冷却中的本金悄悄错位，
///         所以证据必须逐项列出来，而不是「升完了、还能读」。
///
/// @dev 这里的 20 项和链上部署脚本做的是同一组比对。脚本跑一次就没了，
///      写进测试才是每次改动都会重跑的东西。
///      清单覆盖四类：奖励曲线（4）、本金记账（3）、参数（3）、地址与权限（5）、两个闸门（2）。
contract V2UpgradeTest is StakingRewardsBase {
    /// @dev 升级前后要对比的状态。少一项就少一个「数据没丢」的证据
    struct Snapshot {
        // ---- 奖励曲线 ----
        uint256 rewardRate;
        uint256 periodFinish;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        // ---- 本金与负债 ----
        uint256 totalSupply;
        uint256 totalOwed;
        uint256 alicePosition;
        // ---- 参数 ----
        uint256 rewardsDuration;
        uint256 unstakeCooldown;
        uint256 minStakeAmount;
        // ---- 地址 ----
        address stakingToken;
        address rewardToken;
        // ---- 闸门 ----
        bool paused;
        bool claimPaused;
        // ---- 权限 ----
        bool adminRole;
        bool managerRole;
        bool guardianRole;
        bool upgraderRole;
        // ---- 冷却中的本金 ----
        uint256 pendingAmount;
        uint256 pendingUnlockAt;
    }

    function setUp() public override {
        vm.warp(1_700_000_000);
        _deploy(COOLDOWN);
    }

    /*//////////////////////////////////////////////////////////////
                    一、复杂现场下升级不改变任何一项
    //////////////////////////////////////////////////////////////*/

    /// 摆一个「该有的都有」的现场再升级：
    /// 有人持仓、有人在冷却里、参数被改过、发奖金闸门已经拉下。
    /// 空池升级是最容易通过的场景，也最没有说服力
    function test_UpgradeKeepsEveryItem() public {
        _stake(alice, 300e18);
        _stake(bob, 100e18);
        _requestUnstake(alice, 100e18); // 100 在冷却里，200 还在计息
        vm.warp(block.timestamp + 2 days + 3 hours);

        vm.prank(admin);
        staking.setMinStakeAmount(5e18);
        vm.prank(admin);
        staking.pauseClaim();

        Snapshot memory before = _snapshot();

        // 升级本身：部署 V2 实现 + 代理指过去，data 为空（V2 没有新增状态，不需要迁移）
        StakingRewardsV2 v2 = new StakingRewardsV2();
        _upgradeTo(address(v2));

        Snapshot memory after_ = _snapshot();
        _assertSame(before, after_);

        assertEq(staking.implementation(), address(v2), "proxy repointed");
        assertEq(v2.version(), 2, "new code is live");
    }

    /// 升级前 V1 上读不到 `version()`。这条是「还没升」的机器可判定形式，
    /// 也是部署脚本里那个 `_versionOf(proxy) == 0` 前置检查的依据
    function test_V1HasNoVersionBeforeUpgrade() public view {
        (bool ok, bytes memory ret) = address(staking).staticcall(abi.encodeWithSignature("version()"));
        assertFalse(ok, "V1 has no version()");
        assertEq(ret.length, 0, "no return data");
    }

    /*//////////////////////////////////////////////////////////////
                二、升级之后用户资产仍然取得到（不只是"读得到"）
    //////////////////////////////////////////////////////////////*/

    /// 冷却中的本金跨升级后必须还能取。这条比读 `pendingUnstake` 更强：
    /// 记账对但转账路径坏掉，也只在这条上才会红
    function test_PendingPrincipalSurvivesUpgrade() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 100e18);

        _upgradeToV2();

        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal returned after upgrade");
        assertEq(staking.totalSupply(), 0, "no position left");
    }

    /// 升级前已计提但未领取的奖励，升级后领得出来，金额一分不差
    function test_UnclaimedRewardSurvivesUpgrade() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        // 触发一次结算，把应计变成「挂账未领」
        _stake(alice, 1);
        uint256 owedBefore = staking.rewards(alice);
        assertEq(owedBefore, ONE_DAY_REWARD, "booked before upgrade");

        _upgradeToV2();

        assertEq(staking.rewards(alice), owedBefore, "booked amount untouched");

        _getReward(alice);
        assertEq(rewardToken.balanceOf(alice), owedBefore, "paid in full after upgrade");
        assertEq(staking.rewards(alice), 0, "cleared");
    }

    /// 升级后奖励继续按原来的速率累积，不会因为换了实现而重算曲线
    function test_AccrualContinuesAfterUpgrade() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        _upgradeToV2();

        vm.warp(block.timestamp + 1 days);
        assertEq(staking.earned(alice), ONE_DAY_REWARD * 2, "day 1 before + day 1 after");
    }

    /*//////////////////////////////////////////////////////////////
                            三、谁能升级
    //////////////////////////////////////////////////////////////*/

    /// 升级权没有被继承成「管理员自动拥有」以外的任何东西：
    /// 只是拿到 REWARDS_MANAGER 或 GUARDIAN 的地址依然升不了
    function test_OnlyUpgraderCanUpgrade() public {
        _grantRole(MANAGER_ROLE, bob);
        _grantRole(GUARDIAN_ROLE_ID, guardian);

        StakingRewardsV2 v2 = new StakingRewardsV2();

        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.upgradeToAndCall(address(v2), "");

        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        staking.upgradeToAndCall(address(v2), "");

        assertEq(staking.implementation(), implementation, "still V1");
    }

    /*//////////////////////////////////////////////////////////////
                              内部
    //////////////////////////////////////////////////////////////*/

    function _upgradeToV2() internal returns (StakingRewardsV2 v2) {
        v2 = new StakingRewardsV2();
        _upgradeTo(address(v2));
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.rewardRate = staking.rewardRate();
        s.periodFinish = staking.periodFinish();
        s.lastUpdateTime = staking.lastUpdateTime();
        s.rewardPerTokenStored = staking.rewardPerTokenStored();
        s.totalSupply = staking.totalSupply();
        s.totalOwed = staking.totalOwed();
        s.alicePosition = staking.balanceOf(alice);
        s.rewardsDuration = staking.rewardsDuration();
        s.unstakeCooldown = staking.unstakeCooldown();
        s.minStakeAmount = staking.minStakeAmount();
        s.stakingToken = address(staking.stakingToken());
        s.rewardToken = address(staking.rewardToken());
        s.paused = staking.paused();
        s.claimPaused = staking.claimPaused();
        s.adminRole = staking.hasRole(ADMIN_ROLE_ID, admin);
        s.managerRole = staking.hasRole(MANAGER_ROLE, admin);
        s.guardianRole = staking.hasRole(GUARDIAN_ROLE_ID, admin);
        s.upgraderRole = staking.hasRole(keccak256("UPGRADER_ROLE"), admin);
        (uint256 pending, uint256 unlockAt) = staking.pendingUnstake(alice);
        s.pendingAmount = pending;
        s.pendingUnlockAt = unlockAt;
    }

    /// @dev 升级不该改变任何业务状态。用 assertEq 而不是 require：
    ///      红的时候能直接看到「哪一项从多少变成了多少」
    function _assertSame(Snapshot memory a, Snapshot memory b) internal pure {
        assertEq(b.rewardRate, a.rewardRate, "rewardRate changed");
        assertEq(b.periodFinish, a.periodFinish, "periodFinish changed");
        assertEq(b.lastUpdateTime, a.lastUpdateTime, "lastUpdateTime changed");
        assertEq(b.rewardPerTokenStored, a.rewardPerTokenStored, "rewardPerTokenStored changed");
        assertEq(b.totalSupply, a.totalSupply, "totalSupply changed");
        assertEq(b.totalOwed, a.totalOwed, "totalOwed changed");
        assertEq(b.alicePosition, a.alicePosition, "user position changed");
        assertEq(b.rewardsDuration, a.rewardsDuration, "rewardsDuration changed");
        assertEq(b.unstakeCooldown, a.unstakeCooldown, "unstakeCooldown changed");
        assertEq(b.minStakeAmount, a.minStakeAmount, "minStakeAmount changed");
        assertEq(b.stakingToken, a.stakingToken, "stakingToken changed");
        assertEq(b.rewardToken, a.rewardToken, "rewardToken changed");
        assertEq(b.paused, a.paused, "paused changed");
        assertEq(b.claimPaused, a.claimPaused, "claimPaused changed");
        assertEq(b.adminRole, a.adminRole, "admin role changed");
        assertEq(b.managerRole, a.managerRole, "manager role changed");
        assertEq(b.guardianRole, a.guardianRole, "guardian role changed");
        assertEq(b.upgraderRole, a.upgraderRole, "upgrader role changed");
        assertEq(b.pendingAmount, a.pendingAmount, "pending amount changed");
        assertEq(b.pendingUnlockAt, a.pendingUnlockAt, "pending unlock time changed");
    }
}
