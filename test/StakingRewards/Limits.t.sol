// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";

/// @title V1 的能力边界 —— 三件它确实做不到的事
/// @notice 这个文件里的用例全都断言「能力缺失」，所以它们在 V1 上永远是绿的。
///         它们和 `test/StakingRewardsV2/` 里的用例对着看，就是完整的
///         「发现问题 → 升级修复」闭环：
///
///           ① rewardToken 是死禁令 → 注资过量就永远取不回来
///           ② 没有 totalOwedLive / solvencyRatio → 运营看不出池子够不够付
///           ③ 冷却期内没有任何出口 → 用户只能干等
///
/// @dev 如果哪天有人把这些能力下放回 V1，这里的用例会变红。
///      那是提醒你更新文档与审计记录，不是提醒你代码坏了。
contract LimitationsTest is StakingRewardsBase {
    /// V1 对 rewardToken 是死禁令，哪怕合约里有明显用不完的盈余
    function test_RefusesRewardTokenEvenWithHugeSurplus() public {
        // 模拟「注资过量」：额外打 1000 枚进去，远超负债
        rewardToken.mint(address(staking), 1_000e18);
        assertGt(rewardToken.balanceOf(address(staking)), staking.totalOwed(), "there is surplus to take");

        vm.prank(admin);
        vm.expectRevert(StakingRewards.CannotRecoverRewardToken.selector);
        staking.recoverERC20(address(rewardToken), 1);
    }

    /// V1 没有任何观测接口能算出实时负债或偿付率
    function test_HasNoLiveDebtViews() public {
        (bool okOwed,) = address(staking).call(abi.encodeWithSignature("totalOwedLive()"));
        assertFalse(okOwed, "V1 has no totalOwedLive");

        (bool okRatio,) = address(staking).call(abi.encodeWithSignature("solvencyRatio()"));
        assertFalse(okRatio, "V1 has no solvencyRatio");

        (bool okVersion,) = address(staking).call(abi.encodeWithSignature("version()"));
        assertFalse(okVersion, "V1 has no version");
    }

    /// V1 没有紧急退出：冷却期内本金一分钱都动不了
    function test_HasNoExitDuringCooldown() public {
        _deploy(COOLDOWN);
        _stake(alice, 100e18);
        _requestUnstake(alice, 100e18);

        (bool ok,) = address(staking).call(abi.encodeWithSignature("emergencyWithdraw()"));
        assertFalse(ok, "V1 has no emergencyWithdraw");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StillLocked.selector, block.timestamp + COOLDOWN));
        staking.withdraw();
    }
}
