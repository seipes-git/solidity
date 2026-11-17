// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";

/// @title 解质押冷却：两阶段退出
/// @notice 整个测试合约用 cooldown = 1 天重新搭环境，因为冷却逻辑只在 cooldown > 0 时才存在。
///         要验证的三件事：
///           ① 冷却期内取不到本金，但冷却结束后一定取得到；
///           ② 多次发起解押时解锁时间取最晚，新额度不能插队；
///           ③ 管理员改冷却值不影响已经排队的请求（否则等于单方面延长用户等待）
contract CooldownTest is StakingRewardsBase {
    uint256 internal constant MAX_COOLDOWN = 30 days;

    function setUp() public override {
        vm.warp(1_700_000_000);
        _deploy(COOLDOWN);
    }

    /*//////////////////////////////////////////////////////////////
                          一、请求与解锁的时序
    //////////////////////////////////////////////////////////////*/

    function test_RequestCreatesPending() public {
        _stake(alice, 100e18);

        uint256 expectedUnlock = block.timestamp + COOLDOWN;
        _requestUnstake(alice, 40e18);

        // 本金离开仓位，进入挂起区，钱包此刻还是空的
        assertEq(staking.balanceOf(alice), 60e18, "shares deducted");
        assertEq(staking.totalSupply(), 60e18, "supply deducted");
        assertEq(stakeToken.balanceOf(alice), 900e18, "principal NOT returned yet");

        (uint256 amount, uint256 unlockTime) = staking.pendingUnstake(alice);
        assertEq(amount, 40e18, "pending amount");
        assertEq(unlockTime, expectedUnlock, "unlock at now + cooldown");

        (uint256 withdrawableAmount, bool unlocked) = staking.withdrawable(alice);
        assertEq(withdrawableAmount, 40e18, "view reports pending");
        assertFalse(unlocked, "not unlocked yet");
    }

    function test_WithdrawOneSecondBeforeUnlockReverts() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18);

        (, uint256 unlockTime) = staking.pendingUnstake(alice);
        vm.warp(unlockTime - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StillLocked.selector, unlockTime));
        staking.withdraw();
    }

    function test_WithdrawAtUnlockSucceeds() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18);

        (, uint256 unlockTime) = staking.pendingUnstake(alice);
        vm.warp(unlockTime); // 边界是 >=，正好等于解锁时刻应当通过

        _withdraw(alice);

        assertEq(stakeToken.balanceOf(alice), 940e18, "principal returned at unlock");
        (uint256 amount,) = staking.pendingUnstake(alice);
        assertEq(amount, 0, "request cleared");
    }

    function test_WithdrawTwiceReverts() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18);
        vm.warp(block.timestamp + COOLDOWN);

        _withdraw(alice); // 第一次成功

        // 状态已清零，第二次没有东西可取 —— 这条同时证明 delete 生效
        vm.prank(alice);
        vm.expectRevert(StakingRewards.NothingToWithdraw.selector);
        staking.withdraw();
    }

    /*//////////////////////////////////////////////////////////////
                    二、多次请求：解锁时间取最晚
    //////////////////////////////////////////////////////////////*/

    function test_SecondRequestExtendsUnlock() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18); // t0：unlock = t0 + 1d

        vm.warp(block.timestamp + 12 hours);
        _requestUnstake(alice, 60e18); // t0+12h：unlock 应被推到 t0+12h + 1d

        (uint256 amount, uint256 unlockTime) = staking.pendingUnstake(alice);
        assertEq(amount, 100e18, "amounts accumulate");
        assertEq(unlockTime, block.timestamp + COOLDOWN, "unlock pushed to the later one");

        // 老额度不能在新请求的冷却期内偷偷解锁
        vm.warp(unlockTime - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StillLocked.selector, unlockTime));
        staking.withdraw();

        vm.warp(unlockTime);
        _withdraw(alice);
        assertEq(stakeToken.balanceOf(alice), 1_000e18, "all principal back");
    }

    /// 这条测的是「取最晚」真正起作用的场景。
    /// 常规场景（冷却值不变）下第二次请求的解锁时刻本来就晚于第一次，
    /// max 是空操作，删掉也 PASS —— 那是假绿（A-22）。
    /// max 只在两次请求之间把 unstakeCooldown 调低时才生效：
    /// 老额度必须仍然锁到首次解锁时刻，不能被新冷却值「打折」
    function test_LoweringCooldownDoesNotUnlockOldAmountEarly() public {
        // 用 30 天的冷却开局
        _deploy(30 days);

        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18);
        (uint256 firstAmount, uint256 firstUnlock) = staking.pendingUnstake(alice);
        assertEq(firstAmount, 40e18, "first request");
        assertEq(firstUnlock, block.timestamp + 30 days, "locked for 30 days");

        // 管理员把冷却降到 1 天
        vm.prank(admin);
        staking.setUnstakeCooldown(1 days);

        // 再发起一笔：now + 1d 远早于首次解锁时刻
        _requestUnstake(alice, 60e18);
        (uint256 merged, uint256 afterSecond) = staking.pendingUnstake(alice);

        assertEq(merged, 100e18, "amounts merged");
        // 删掉 max 的话这里会是 now + 1 天，比首次解锁早 29 天
        assertEq(afterSecond, firstUnlock, "still locked until the ORIGINAL unlock time");
        assertGt(afterSecond, block.timestamp + 1 days, "new shorter cooldown must not shorten old lock");
    }

    /*//////////////////////////////////////////////////////////////
                      三、冷却期间仍然结算奖励
    //////////////////////////////////////////////////////////////*/

    /// 发起解押时本金已离开仓位，所以冷却期不再产生奖励；但发起之前那段必须结清
    function test_RequestSettlesRewardUpToThatMoment() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        _requestUnstake(alice, 100e18);

        assertEq(staking.rewards(alice), ONE_DAY_REWARD, "settled at request time");

        // 冷却期内仓位为 0，奖励不再增长
        vm.warp(block.timestamp + 12 hours);
        assertEq(staking.earned(alice), ONE_DAY_REWARD, "no accrual while pending");
    }

    /*//////////////////////////////////////////////////////////////
                        四、exit 在冷却模式下的语义
    //////////////////////////////////////////////////////////////*/

    function test_ExitLeavesPrincipalPending() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.exit();

        // 奖励已到账，但本金还在排队
        assertEq(rewardToken.balanceOf(alice), ONE_DAY_REWARD, "reward paid immediately");
        assertEq(staking.balanceOf(alice), 0, "shares cleared");
        (uint256 pending,) = staking.pendingUnstake(alice);
        assertEq(pending, 100e18, "principal pending, not lost");
        assertEq(stakeToken.balanceOf(alice), 900e18, "wallet still short");
    }

    /// 已经等满冷却的那笔本金，不能被 `exit()` 重新计时
    /// @dev 单槽 `pendingUnstake` 合并请求时取最晚解锁时间，于是「先挂 100 等满 → 再 exit 剩 50」
    ///      会把那 100 一起推后一个周期。`exit` 因此在内部先 `withdraw` 已解锁的部分
    function test_ExitDoesNotRelockUnlockedPrincipal() public {
        _stake(alice, 150e18);
        _requestUnstake(alice, 100e18);

        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 walletBefore = stakeToken.balanceOf(alice);
        vm.prank(alice);
        staking.exit();

        assertEq(stakeToken.balanceOf(alice) - walletBefore, 100e18, "unlocked part paid in the same tx");

        (uint256 amount, uint256 unlockTime) = staking.pendingUnstake(alice);
        assertEq(amount, 50e18, "only the remainder is queued");
        assertEq(unlockTime, block.timestamp + COOLDOWN, "remainder starts its own cooldown");
        assertEq(staking.totalSupply(), 0, "nothing left accruing");
    }

    /*//////////////////////////////////////////////////////////////
                    五、改冷却值不影响已排队的请求
    //////////////////////////////////////////////////////////////*/

    function test_CooldownChangeDoesNotAffectPending() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18);

        (, uint256 unlockTime) = staking.pendingUnstake(alice);

        // 管理员把冷却拉到上限：只影响之后发起的请求
        vm.prank(admin);
        staking.setUnstakeCooldown(MAX_COOLDOWN);

        (, uint256 afterChange) = staking.pendingUnstake(alice);
        assertEq(afterChange, unlockTime, "pending unlock untouched");

        vm.warp(unlockTime);
        _withdraw(alice);
        assertEq(stakeToken.balanceOf(alice), 940e18, "still withdrawable on schedule");
    }

    /*//////////////////////////////////////////////////////////////
                              六、上限保护
    //////////////////////////////////////////////////////////////*/

    function test_SetCooldownAboveCapReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.CooldownTooLong.selector, MAX_COOLDOWN + 1));
        staking.setUnstakeCooldown(MAX_COOLDOWN + 1);

        // 正好等于上限应当通过
        vm.prank(admin);
        staking.setUnstakeCooldown(MAX_COOLDOWN);
        assertEq(staking.unstakeCooldown(), MAX_COOLDOWN, "cap accepted");
    }

    /// 参数校验从「构造函数」搬到了「initialize」，但校验本身必须还在——
    /// 否则管理员可以在部署后把冷却设成任意长度
    function test_InitializeRejectsCooldownAboveCap() public {
        StakingRewards impl = new StakingRewards();
        bytes memory initData = abi.encodeCall(
            StakingRewards.initialize, (stakeToken, rewardToken, DURATION, MAX_COOLDOWN + 1)
        );

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.CooldownTooLong.selector, MAX_COOLDOWN + 1));
        new ERC1967Proxy(address(impl), initData);
    }

    /*//////////////////////////////////////////////////////////////
                          七、边界（fuzz）
    //////////////////////////////////////////////////////////////*/

    /// 解锁时刻之前一律失败、之后一律成功，中间没有缝隙也没有多等
    function testFuzz_UnlockBoundary(uint96 rawAmount, uint32 waitBeforeUnlock) public {
        uint256 amount = bound(uint256(rawAmount), 1e12, 1_000e18);
        _stake(alice, amount);

        _requestUnstake(alice, amount);
        (, uint256 unlockTime) = staking.pendingUnstake(alice);

        uint256 wait = bound(uint256(waitBeforeUnlock), 1, COOLDOWN - 1);
        vm.warp(unlockTime - wait);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.StillLocked.selector, unlockTime));
        staking.withdraw();

        vm.warp(unlockTime);
        _withdraw(alice);
        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal fully returned");
    }
}
