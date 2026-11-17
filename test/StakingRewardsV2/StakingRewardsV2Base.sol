// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "../StakingRewards/StakingRewardsBase.sol";
import {StakingRewardsV2} from "../../src/StakingRewardsV2.sol";

/// @title StakingRewardsV2 的测试基座
/// @notice V2 是 V1 的升级版，测试环境也照着这条路径搭：
///         先用 V1 的基座把代理部署起来（带冷却），再把代理指向 V2 的实现合约。
///
///         为什么不用 `new StakingRewardsV2()` 直接部署：
///         V2 没有构造函数参数、也没有新的初始化函数，直接部署出来的实例
///         既没有角色也没有状态，测出来的东西和线上无关。
///         走一次真实升级，顺带就证明了「V2 不需要迁移」。
///
/// @dev 继承自 `StakingRewardsBase` 而不是复制一份 helper：
///      V2 的全部状态变量与 V1 相同，差别只在函数。基座复用同一个代理地址，
///      于是同一套 `_stake` / `_requestUnstake` 在升级后依然指向代理，行为一致。
///      用带冷却的部署（cooldown = 1 天），`emergencyWithdraw` 的「无视解锁时间」才有意义。
abstract contract StakingRewardsV2Base is StakingRewardsBase {
    StakingRewardsV2 internal v2;

    function setUp() public virtual override {
        vm.warp(1_700_000_000);
        _deploy(COOLDOWN);
        _upgradeToV2();
    }

    /// @dev 部署 V2 实现并把代理指过去。UPGRADER_ROLE 在 initialize 里给了 admin
    function _upgradeToV2() internal {
        v2 = new StakingRewardsV2();
        _upgradeTo(address(v2));
    }

    /// @dev 同一个代理地址，换用 V2 的 ABI 去看它。地址没变，变的只是被 delegatecall 的代码
    function _asV2() internal view returns (StakingRewardsV2) {
        return StakingRewardsV2(address(staking));
    }
}
