// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";

/// @title ETH 池的紧急退出
/// @notice 本金不该被任何一方的设定冻住。这条出口的存在意义只有一句：
///         **无论冷却多久、哪个闸门被拉下，本金都能当场拿回去**，代价是放弃全部未领奖励。
///
/// @dev 本合约不可升级，所以这个出口一旦上线就没有第二次修改机会；
///      用例覆盖的重点也因此放在「会计不能被打乱」——代价是 `totalPending`
///      必须同步减少，否则 `recoverETH` 的上限会把退回去的本金当成余量。
contract ETHEmergencyWithdrawTest is StakingRewardsETHBase {
    /*//////////////////////////////////////////////////////////////
                        一、正常路径：本金与奖励
    //////////////////////////////////////////////////////////////*/

    function test_ReturnsPrincipalAndForfeitsReward() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 accrued = staking.earned(alice);
        assertGt(accrued, 0, "reward accrued before emergency exit");

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        staking.emergencyWithdraw();

        assertEq(alice.balance - ethBefore, 10 ether, "principal returned in full");
        assertEq(staking.balanceOf(alice), 0, "position cleared");
        assertEq(staking.totalSupply(), 0, "supply cleared");
        assertEq(staking.rewards(alice), 0, "reward forfeited");
        assertEq(staking.earned(alice), 0, "nothing left to claim");

        // `totalOwed` 是惰性量：alice 是唯一质押者，她这一整段应计直到这次退出才被结算进负债，
        // 随即又被放弃的奖励销掉，所以退出之后负债必然归零
        assertEq(staking.totalOwed(), 0, "liability drained with the only staker gone");
    }

    /// 计息本金 + 冷却中的本金一起退，且 `totalPending` 同步归零
    function test_ReturnsBothStakedAndPendingPrincipal() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 4 ether);

        assertEq(staking.totalSupply(), 6 ether, "accruing side");
        assertEq(staking.totalPending(), 4 ether, "cooling side");

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        staking.emergencyWithdraw();

        assertEq(alice.balance - ethBefore, 10 ether, "both buckets returned");
        assertEq(staking.totalSupply(), 0, "supply cleared");
        assertEq(staking.totalPending(), 0, "pending cleared");
        assertEq(staking.balanceOf(alice), 0, "position cleared");

        (uint256 amount,) = staking.pendingUnstake(alice);
        assertEq(amount, 0, "pending request deleted");

        // 会计必须同步收口：否则 `recoverETH` 的 `balance − totalSupply − totalPending`
        // 会把刚退回去的本金算成余量
        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, 0, "no ETH left behind");
        assertEq(owed, 0, "nothing owed after the only user left");
        assertEq(surplus, 0, "and no phantom surplus to sweep");
    }

    /*//////////////////////////////////////////////////////////////
                        二、它必须在别的出口都关着时也能用
    //////////////////////////////////////////////////////////////*/

    function test_IgnoresCooldown() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        // 冷却还剩整整一天，withdraw 必然失败
        (, uint256 unlockTime) = staking.pendingUnstake(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.StillLocked.selector, unlockTime));
        staking.withdraw();

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        staking.emergencyWithdraw();
        assertEq(alice.balance - ethBefore, 10 ether, "cooldown bypassed");
    }

    /// 两个闸门同时拉下也要能用：退的是本金，不是奖励
    function test_WorksWhilePausedAndClaimPaused() public {
        _stake(alice, 10 ether);
        staking.pause();
        staking.pauseClaim();

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        staking.emergencyWithdraw();

        assertEq(alice.balance - ethBefore, 10 ether, "principal still exits");
        assertTrue(staking.paused(), "stake gate still closed");
        assertTrue(staking.claimPaused(), "claim gate still closed");
    }

    /*//////////////////////////////////////////////////////////////
                        三、会计：不能把本金当余量
    //////////////////////////////////////////////////////////////*/

    function test_KeepsETHAccountingBalanced() public {
        _stake(alice, 10 ether);
        _stake(bob, 6 ether);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.emergencyWithdraw();

        // 余额仍然等于「计息本金 + 冷却本金」：没有凭空多出或少掉 wei
        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, address(staking).balance, "held mirrors balance");
        assertEq(owed, 6 ether, "bob's principal still accounted");
        assertEq(held, owed + surplus, "held = owed + surplus");
        assertEq(surplus, 0, "no phantom surplus from alice's exit");

        // 管理员这时候按上限取，也只能取到 0
        vm.expectRevert(StakingRewardsETH.NoSurplus.selector);
        staking.recoverETH();

        // bob 的本金与奖励都不受影响
        uint256 bobReward = staking.earned(bob);
        assertGt(bobReward, 0, "bob keeps accruing");
        vm.prank(bob);
        staking.getReward();
        assertEq(staking.earned(bob), 0, "bob claims normally");
    }

    function test_RevertsWhenNothingStaked() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewardsETH.NothingToEmergencyWithdraw.selector);
        staking.emergencyWithdraw();
    }

    /// 退出之后重新质押要能正常工作：状态清干净了才可能再进来
    function test_CanRestakeAfterEmergency() public {
        _stake(alice, 10 ether);
        vm.prank(alice);
        staking.emergencyWithdraw();

        _stake(alice, 5 ether);
        assertEq(staking.balanceOf(alice), 5 ether, "position rebuilt");
        assertEq(staking.totalSupply(), 5 ether, "supply rebuilt");
    }

    /*//////////////////////////////////////////////////////////////
                    四、取整差额不能让这个出口失效
    //////////////////////////////////////////////////////////////*/

    /// 应发比负债多几 wei 的状态下，紧急退出照样要能开，会计也要收口
    ///
    /// @dev 构造方式：质押 1 wei 尾数，`supply · Δ` 除以 PRECISION 一定有余数，
    ///      每跨一个结算边界两边各 floor 一次，跨两次后 `earned` 就比 `totalOwed` 多 1 wei。
    ///      两个没有仓位的地址各调一次 `getReward()`：结算走完、`reward == 0` 直接返回，
    ///      不改 `totalSupply`、不改 `rewardRate`，等于「纯结算两次」
    function test_EmergencyWithdrawSurvivesRoundingDeficit() public {
        uint256 amount = 1 ether + 1;
        _stake(alice, amount);

        vm.warp(block.timestamp + 1);
        vm.prank(address(0xBEEF));
        staking.getReward();

        vm.warp(block.timestamp + 1);
        vm.prank(address(0xCAFE));
        staking.getReward();

        uint256 owed = staking.totalOwed();
        uint256 due = staking.earned(alice);
        assertGt(due, owed, "deficit state: accrued exceeds recorded liability");

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        staking.emergencyWithdraw();

        assertEq(alice.balance - ethBefore, amount, "principal returned in full");
        assertEq(staking.balanceOf(alice), 0, "position cleared");
        assertEq(staking.totalSupply(), 0, "supply cleared");
        assertEq(staking.rewards(alice), 0, "forfeited reward cleared");
        assertEq(staking.totalOwed(), 0, "liability clamped, not underflowed");

        // 本金全额退回之后合约里不该剩下任何 ETH，`recoverETH` 也就不该有可取的余量
        (uint256 held, uint256 accounted, uint256 surplus) = staking.ethAccounting();
        assertEq(held, 0, "no ETH left behind");
        assertEq(accounted, 0, "nothing accounted to users");
        assertEq(surplus, 0, "no phantom surplus");
    }
}
