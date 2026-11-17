// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";

/// @title ETH 池的奖励数学与周期边界
/// @notice 奖励算法与 ERC20 池逐行相同（Synthetix 式），所以这里不再重复「公式为什么对」，
///         只验证同一套不变量在 ETH 计价下仍然成立：
///         ① 单人不进出时严格线性；② 多人按份额分配且总量守恒；
///         ③ 后入场的人拿不到入场前的产出；④ 周期结束后不再增长。
///
/// @dev 与 ERC20 池同一套参数：每秒 1 枚，整期 604,800 枚，`rewardRate` 没有整除截断。
///      但 `rewardPerToken()` 里还有一次 `/ totalSupply`，份额除不尽时仍会留 dust，
///      所以涉及具体数值的断言仍用 `assertApproxEqAbs`。
contract ETHRewardsTest is StakingRewardsETHBase {
    function test_SetupSanity() public view {
        assertEq(staking.rewardRate(), RATE, "rate");
        assertEq(staking.rewardRate(), FUND / DURATION, "rate covers the whole period");
        assertEq(staking.periodFinish(), block.timestamp + DURATION, "period");
        assertEq(staking.totalSupply(), 0, "pool starts empty");
    }

    /*//////////////////////////////////////////////////////////////
                    一、累积：奖励怎么随时间长出来
    //////////////////////////////////////////////////////////////*/

    function test_SingleStakerAccruesLinearly() public {
        _stake(alice, 10 ether);

        // 质押的同一秒内不应有任何奖励
        assertEq(staking.earned(alice), 0, "no reward in the staking block");

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD, 1e6, "1 day");

        vm.warp(block.timestamp + 2 days);
        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD * 3, 1e6, "3 days total");
    }

    function test_TwoStakersSplitEvenly() public {
        _stake(alice, 10 ether);
        _stake(bob, 10 ether);

        vm.warp(block.timestamp + 1 days);

        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD / 2, 1e6, "alice half");
        assertApproxEqAbs(staking.earned(bob), ONE_DAY_REWARD / 2, 1e6, "bob half");
        assertApproxEqAbs(staking.earned(alice) + staking.earned(bob), ONE_DAY_REWARD, 1e6, "sum equals emission");
    }

    /// 中途入场的人拿不到他入场之前的那段时间
    function test_JoinLateGetsNoBackpay() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        _stake(bob, 10 ether);

        assertEq(staking.earned(bob), 0, "no backpay");
        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD, 1e6, "alice keeps day 1");
    }

    /// 池子空着的时候不累积 —— 代价是这段时间的奖励滞留合约、不会补发
    function test_EmptyPoolAccrualFrozen_RewardsStranded() public {
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.rewardPerToken(), 0, "frozen while empty");

        _stake(alice, 10 ether);
        assertEq(staking.rewards(alice), 0, "nothing retroactive");

        vm.warp(block.timestamp + DURATION);

        // 从入场时刻才重新开始累积，只剩 6 天可分配
        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD * 6, 1e6, "only 6 days were distributed");
        assertApproxEqAbs(
            rewardToken.balanceOf(address(staking)) - staking.earned(alice),
            ONE_DAY_REWARD,
            1e6,
            "1 day of rewards stranded in contract"
        );
    }

    function test_EarnedStopsAtPeriodFinish() public {
        _stake(alice, 10 ether);

        vm.warp(staking.periodFinish() + 30 days);

        assertApproxEqAbs(staking.earned(alice), ONE_DAY_REWARD * 7, 1e8, "capped at full period");

        uint256 snapshot = staking.rewardPerToken();
        vm.warp(block.timestamp + 365 days);
        assertEq(staking.rewardPerToken(), snapshot, "perToken frozen after finish");
    }

    /*//////////////////////////////////////////////////////////////
                      二、续投：剩余奖励与新奖励合并
    //////////////////////////////////////////////////////////////*/

    function test_NotifyMidPeriodMergesLeftover() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 3 days);

        uint256 alreadyAccrued = staking.earned(alice);
        uint256 leftover = FUND - alreadyAccrued;

        rewardToken.mint(address(staking), FUND);
        staking.notifyRewardAmount(FUND);

        // 周期被重新拉长一整期，而不是接着原来的尾巴跑
        assertEq(staking.periodFinish(), block.timestamp + DURATION, "period restarted");

        vm.warp(staking.periodFinish());
        assertApproxEqAbs(staking.earned(alice) - alreadyAccrued, leftover + FUND, 1e8, "leftover + new");
    }

    /// 预算保护：池子里只有一期的钱，再许诺两期必须失败
    function test_NotifyRevertsIfNotFunded() public {
        vm.expectPartialRevert(StakingRewardsETH.InsufficientRewardBalance.selector);
        staking.notifyRewardAmount(FUND * 2);
    }

    /*//////////////////////////////////////////////////////////////
              三、预算保护：已欠出去的钱不能算成可用额度
    //////////////////////////////////////////////////////////////*/

    /// 已结算、还没领的奖励，不能再当成新一期的额度许诺出去
    function test_NotifyCannotCountOwedRewardsAsBudget() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 3 days);

        // 再质押 1 wei 只为触发结算，把「未结算」变成「挂账未领」
        _stake(alice, 1);
        assertApproxEqAbs(staking.rewards(alice), ONE_DAY_REWARD * 3, 1e6, "owed but unpaid");

        vm.warp(staking.periodFinish());

        vm.expectPartialRevert(StakingRewardsETH.InsufficientRewardBalance.selector);
        staking.notifyRewardAmount(FUND);
    }

    /// 一次结算都没发生时，未结算的应计同样算负债
    function test_NotifyCannotCountAccruedRewardsAsBudget() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 3 days);

        // 坐实前提：没有任何人触发过结算
        assertEq(staking.rewards(alice), 0, "never settled");

        vm.expectPartialRevert(StakingRewardsETH.InsufficientRewardBalance.selector);
        staking.notifyRewardAmount(ONE_DAY_REWARD * 3);

        // 把欠她的那部分真的转进来，同一个调用就必须通过：
        // 拦住它的应该是负债，而不是别的条件
        rewardToken.mint(address(staking), ONE_DAY_REWARD * 3);
        staking.notifyRewardAmount(ONE_DAY_REWARD * 3);
    }

    /*//////////////////////////////////////////////////////////////
                            四、领取
    //////////////////////////////////////////////////////////////*/

    function test_GetRewardTransfersAndClears() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertApproxEqAbs(rewardToken.balanceOf(alice) - before, ONE_DAY_REWARD, 1e6, "paid");
        assertEq(staking.rewards(alice), 0, "cleared");

        // 同一时刻再领一次，金额应为 0（没有 revert，只是不发）
        uint256 afterFirst = rewardToken.balanceOf(alice);
        _getReward(alice);
        assertEq(rewardToken.balanceOf(alice), afterFirst, "no double pay");
    }

    /// 领走奖励之后，`rewards` 与 `totalOwed` 必须同时归零
    function test_GetRewardClearsLiability() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        // 触发结算，让应计同时落进 rewards 与 totalOwed
        _stake(alice, 1);
        assertGt(staking.totalOwed(), 0, "liability booked");

        _getReward(alice);

        assertEq(staking.rewards(alice), 0, "reward cleared");
        // 用 dust 容差而不是 == 0：速率本身干净，但 `rewardPerToken` 的 `/ totalSupply`
        // 仍会按用户 floor，多一个质押者就可能残留几 wei
        assertLe(staking.totalOwed(), 1e6, "liability cleared");

        // 同一时刻再领一次，负债不增长
        _getReward(alice);
        assertLe(staking.totalOwed(), 1e6, "still zero");
    }

    /// `earned()` 是只算不写，`getReward()` 是结算那条；两条路径要算出同一个数。
    /// 断言的是这件事本身，不是某个具体金额
    function test_EarnedReadsEqualActualPayout() public {
        _stake(alice, 10 ether);
        // 非整数天的时刻：干净倍数可能掩盖取整口径的差异
        vm.warp(block.timestamp + 1 days + 3 hours);

        uint256 expected = staking.earned(alice);
        assertGt(expected, 0, "there is something to read");

        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice) - before, expected, "payout equals the view");
        assertEq(staking.earned(alice), 0, "view drains to zero after payout");
    }

    /// 从未产生过奖励时不该 revert，也不该产生转账
    function test_ZeroRewardGetRewardDoesNotRevert() public {
        _stake(alice, 10 ether);

        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice), before, "nothing moved");
        assertEq(staking.rewards(alice), 0, "nothing booked");
    }

    /// 结算边界各 floor 一次、用户跨边界一次性 floor，差额可以让「应发 > 负债」。
    /// ETH 池不可升级，这条路径一旦回滚就没有补救出口，所以必须单独钉住
    function test_RoundingDeficitDoesNotBlockClaim() public {
        // 尾数 7 wei：10 ether + 7 在「1 秒间隔、两次结算」下每个边界都留余数，
        // 逐位算过（换 1/3 余数刚好被吃掉、不产生差额）
        _stake(alice, 10 ether + 7);

        // 两个空仓位地址各领一次 = 纯结算两次，不改 supply、不改 rewardRate
        vm.warp(block.timestamp + 1);
        vm.prank(address(0xBEEF));
        staking.getReward();

        vm.warp(block.timestamp + 1);
        vm.prank(address(0xCAFE));
        staking.getReward();

        uint256 owed = staking.totalOwed();
        uint256 due = staking.earned(alice);
        assertGt(due, owed, "deficit state: accrued exceeds recorded liability");

        uint256 beforeBal = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice) - beforeBal, due, "pays the full accrued amount");
        assertEq(staking.rewards(alice), 0, "user side cleared");
        assertEq(staking.totalOwed(), 0, "liability clamped, not underflowed");
    }

    /// fuzz 版交叉验证：任意质押额、任意时长，读数与实收都必须严格相等
    function testFuzz_EarnedMatchesPayout(uint96 rawAmount, uint32 elapsed) public {
        uint256 amount = bound(uint256(rawAmount), 1, 50 ether);
        uint256 t = bound(uint256(elapsed), 1, DURATION);

        _stake(alice, amount);
        vm.warp(block.timestamp + t);

        uint256 expected = staking.earned(alice);
        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice) - before, expected, "fuzz: payout equals view");
        assertEq(staking.earned(alice), 0, "fuzz: view drains to zero");
    }

    /*//////////////////////////////////////////////////////////////
                    五、周期参数：只能在周期结束后改
    //////////////////////////////////////////////////////////////*/

    function test_SetRewardsDurationRejectedWhileActive() public {
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(StakingRewardsETH.PeriodStillActive.selector);
        staking.setRewardsDuration(14 days);
    }

    function test_SetRewardsDurationAfterFinish() public {
        vm.warp(staking.periodFinish());

        vm.expectRevert(StakingRewardsETH.InvalidDuration.selector);
        staking.setRewardsDuration(0);

        staking.setRewardsDuration(14 days);
        assertEq(staking.rewardsDuration(), 14 days, "duration updated");
    }

    /*//////////////////////////////////////////////////////////////
                        六、守恒（fuzz）
    //////////////////////////////////////////////////////////////*/

    /// 任何质押比例、任何时长下，两人收益之和都等于这段时间的产出
    function testFuzz_Conservation(uint96 amountA, uint96 amountB, uint32 elapsed) public {
        uint256 a = bound(uint256(amountA), 1, 50 ether);
        uint256 b = bound(uint256(amountB), 1, 50 ether);
        uint256 t = bound(uint256(elapsed), 0, DURATION);

        _stake(alice, a);
        _stake(bob, b);

        vm.warp(block.timestamp + t);

        // 用相对误差：金额变化几个数量级时，绝对容差没有意义
        assertApproxEqRel(
            staking.earned(alice) + staking.earned(bob), staking.rewardRate() * t, 1e10, "conservation"
        );
    }
}
