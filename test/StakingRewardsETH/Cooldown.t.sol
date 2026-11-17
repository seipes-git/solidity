// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ETH 池的解质押冷却
/// @notice 要验证的四件事：
///           ① 冷却期内取不到本金，冷却结束后一定取得到（边界是 `>=`）；
///           ② 多次发起时解锁时间取最晚，新额度不能插队；
///           ③ 管理员改冷却值不影响已经排队的请求；
///           ④ 构造参数的上限校验真的存在——否则部署时就能把用户锁一年
///
/// @dev 这里对 ETH 池尤其重要：本金的「锁」是账面上的（`totalPending`），
///      而钱一直在合约里。记账和余额一旦不同步，`recoverETH` 就会把用户的钱当余量取走。
contract ETHCooldownTest is StakingRewardsETHBase {
    uint256 internal constant MAX_COOLDOWN = 30 days;

    /*//////////////////////////////////////////////////////////////
                          一、请求与解锁的时序
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawOneSecondBeforeUnlockReverts() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        (, uint256 unlockTime) = staking.pendingUnstake(alice);
        vm.warp(unlockTime - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.StillLocked.selector, unlockTime));
        staking.withdraw();

        // 本金一分未动，仍然挂在 pending 上
        assertEq(staking.totalPending(), 10 ether, "still pending");
    }

    function test_WithdrawAtUnlockSucceeds() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        (, uint256 unlockTime) = staking.pendingUnstake(alice);
        vm.warp(unlockTime);

        _withdraw(alice);

        assertEq(alice.balance, 100 ether, "principal returned at unlock");
        (uint256 amount,) = staking.pendingUnstake(alice);
        assertEq(amount, 0, "request cleared");
    }

    /*//////////////////////////////////////////////////////////////
                    二、多次请求：解锁时间取最晚
    //////////////////////////////////////////////////////////////*/

    function test_SecondRequestExtendsUnlock() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 4 ether); // t0：unlock = t0 + 1d

        vm.warp(block.timestamp + 12 hours);
        _requestUnstake(alice, 6 ether); // t0+12h：unlock 应被推到 t0+12h + 1d

        (uint256 amount, uint256 unlockTime) = staking.pendingUnstake(alice);
        assertEq(amount, 10 ether, "amounts accumulate");
        assertEq(staking.totalPending(), 10 ether, "aggregate accumulates too");
        assertEq(unlockTime, block.timestamp + COOLDOWN, "unlock pushed to the later one");

        // 老额度不能在新请求的冷却期内偷偷解锁
        vm.warp(unlockTime - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.StillLocked.selector, unlockTime));
        staking.withdraw();

        vm.warp(unlockTime);
        _withdraw(alice);
        assertEq(alice.balance, 100 ether, "all principal back");
    }

    /// 这条测的是「取最晚」真正起作用的场景。
    /// 常规场景下第二次请求的解锁时刻本来就晚于第一次，max 是空操作，删掉也 PASS。
    /// max 只在两次请求之间把 unstakeCooldown 调低时才生效：
    /// 老额度必须仍然锁到首次解锁时刻，不能被新冷却值「打折」
    function test_LoweringCooldownDoesNotUnlockOldAmountEarly() public {
        _deploy(30 days);

        _stake(alice, 10 ether);
        _requestUnstake(alice, 4 ether);
        (uint256 firstAmount, uint256 firstUnlock) = staking.pendingUnstake(alice);
        assertEq(firstAmount, 4 ether, "first request");
        assertEq(firstUnlock, block.timestamp + 30 days, "locked for 30 days");

        // 管理员把冷却降到 1 天
        staking.setUnstakeCooldown(1 days);

        _requestUnstake(alice, 6 ether);
        (uint256 merged, uint256 afterSecond) = staking.pendingUnstake(alice);

        assertEq(merged, 10 ether, "amounts merged");
        // 删掉 max 的话这里会是 now + 1 天，比首次解锁早 29 天
        assertEq(afterSecond, firstUnlock, "still locked until the ORIGINAL unlock time");
        assertGt(afterSecond, block.timestamp + 1 days, "new shorter cooldown must not shorten old lock");
    }

    /*//////////////////////////////////////////////////////////////
                  三、exit 不重锁已经到期的本金
    //////////////////////////////////////////////////////////////*/

    /// 单槽 `pendingUnstake` 合并请求时取最晚解锁时间：「先挂 10 ETH 等满冷却 → 再 exit 剩下 5」
    /// 会把那 10 一起推后一整个周期。`exit` 因此在内部先 `withdraw` 已解锁的部分
    function test_ExitDoesNotRelockUnlockedPrincipal() public {
        _stake(alice, 15 ether);
        _requestUnstake(alice, 10 ether);

        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 walletBefore = alice.balance;
        vm.prank(alice);
        staking.exit();

        assertEq(alice.balance - walletBefore, 10 ether, "unlocked part paid in the same tx");

        (uint256 amount, uint256 unlockTime) = staking.pendingUnstake(alice);
        assertEq(amount, 5 ether, "only the remainder is queued");
        assertEq(unlockTime, block.timestamp + COOLDOWN, "remainder starts its own cooldown");
        assertEq(staking.totalSupply(), 0, "nothing left accruing");
        assertEq(staking.totalPending(), 5 ether, "pending bucket matches the remainder");
    }

    /*//////////////////////////////////////////////////////////////
                    四、冷却期间仍然结算奖励
    //////////////////////////////////////////////////////////////*/

    /// 发起解押时本金已离开仓位，所以冷却期不再产生奖励；但发起之前那段必须结清
    function test_RequestSettlesRewardUpToThatMoment() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        _requestUnstake(alice, 10 ether);

        assertApproxEqAbs(staking.rewards(alice), ONE_DAY_REWARD, 1e6, "settled at request time");

        // 冷却期内仓位为 0，奖励不再增长
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD, 1e6, "no accrual while pending");
    }

    /*//////////////////////////////////////////////////////////////
                    五、改冷却值不影响已排队的请求
    //////////////////////////////////////////////////////////////*/

    function test_CooldownChangeDoesNotAffectPending() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 4 ether);

        (, uint256 unlockTime) = staking.pendingUnstake(alice);

        staking.setUnstakeCooldown(MAX_COOLDOWN);

        (, uint256 afterChange) = staking.pendingUnstake(alice);
        assertEq(afterChange, unlockTime, "pending unlock untouched");

        vm.warp(unlockTime);
        _withdraw(alice);
        assertEq(alice.balance, 94 ether, "still withdrawable on schedule");
    }

    /*//////////////////////////////////////////////////////////////
                              六、上限保护
    //////////////////////////////////////////////////////////////*/

    function test_SetCooldownAboveCapReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.CooldownTooLong.selector, MAX_COOLDOWN + 1));
        staking.setUnstakeCooldown(MAX_COOLDOWN + 1);

        // 正好等于上限应当通过
        staking.setUnstakeCooldown(MAX_COOLDOWN);
        assertEq(staking.unstakeCooldown(), MAX_COOLDOWN, "cap accepted");
    }

    /// ETH 池是 constructor 版，校验在构造函数里。这条守住「部署时就不能乱填」
    function test_ConstructorRejectsCooldownAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.CooldownTooLong.selector, MAX_COOLDOWN + 1));
        new StakingRewardsETH(IERC20(address(rewardToken)), DURATION, MAX_COOLDOWN + 1);
    }

    function test_ConstructorRejectsZeroDuration() public {
        vm.expectRevert(StakingRewardsETH.InvalidDuration.selector);
        new StakingRewardsETH(IERC20(address(rewardToken)), 0, COOLDOWN);
    }

    /// 奖励币是零地址时，`getReward` 会打到 address(0)。这个池没有升级通路，部署完就改不了
    function test_ConstructorRejectsZeroRewardToken() public {
        vm.expectRevert(StakingRewardsETH.InvalidToken.selector);
        new StakingRewardsETH(IERC20(address(0)), DURATION, COOLDOWN);
    }

    /*//////////////////////////////////////////////////////////////
                          七、边界（fuzz）
    //////////////////////////////////////////////////////////////*/

    /// 解锁时刻之前一律失败、之后一律成功，中间没有缝隙也没有多等
    function testFuzz_UnlockBoundary(uint96 rawAmount, uint32 waitBeforeUnlock) public {
        uint256 amount = bound(uint256(rawAmount), 1, 50 ether);
        _stake(alice, amount);

        _requestUnstake(alice, amount);
        (, uint256 unlockTime) = staking.pendingUnstake(alice);

        uint256 wait = bound(uint256(waitBeforeUnlock), 1, COOLDOWN - 1);
        vm.warp(unlockTime - wait);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.StillLocked.selector, unlockTime));
        staking.withdraw();

        vm.warp(unlockTime);
        _withdraw(alice);
        assertEq(alice.balance, 100 ether, "principal fully returned");
    }
}
