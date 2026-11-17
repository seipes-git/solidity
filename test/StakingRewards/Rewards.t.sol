// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";

/// @title 奖励数学：累积、分配、周期边界
/// @notice 这里验证的是 Synthetix 式的核心不变量：
///         ① 单人不进出时严格线性；② 多人按份额分配且总量守恒；
///         ③ 后入场的人拿不到入场前的产出；④ 周期结束后不再增长。
/// @dev 断言的三种写法：
///        assertEq           期望值能算到 wei，直接用等号
///        assertApproxEqAbs  期望值对但有 dust，给 wei 级容差
///        assertApproxEqRel  误差随数值放大，给比例容差（fuzz 里常用）
contract RewardsTest is StakingRewardsBase {
    function test_SetupSanity() public view {
        assertEq(staking.rewardRate(), RATE, "rate");
        assertEq(staking.periodFinish(), block.timestamp + DURATION, "period");
        assertEq(staking.totalSupply(), 0, "pool starts empty");
    }

    /*//////////////////////////////////////////////////////////////
                    一、累积：奖励怎么随时间长出来
    //////////////////////////////////////////////////////////////*/

    /// 不变量 1：只有一个质押者、没有进出时，奖励是严格线性的
    function test_SingleStakerAccruesLinearly() public {
        _stake(alice, 100e18);

        // 质押的同一秒内不应有任何奖励
        assertEq(staking.earned(alice), 0, "no reward in the staking block");

        vm.warp(block.timestamp + 1 days);
        assertEq(staking.earned(alice), ONE_DAY_REWARD, "1 day");

        vm.warp(block.timestamp + 2 days);
        assertEq(staking.earned(alice), ONE_DAY_REWARD * 3, "3 days total");
    }

    /// 不变量 2：两人等额质押，产出对半；两者之和 = 速率 × 时间
    function test_TwoStakersSplitEvenly() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);

        vm.warp(block.timestamp + 1 days);

        assertEq(staking.earned(alice), ONE_DAY_REWARD / 2, "alice half");
        assertEq(staking.earned(bob), ONE_DAY_REWARD / 2, "bob half");
        assertEq(staking.earned(alice) + staking.earned(bob), ONE_DAY_REWARD, "sum equals emission");
    }

    /// 不变量 3：中途入场的人拿不到他入场之前的那段时间
    function test_JoinLateGetsNoBackpay() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        _stake(bob, 100e18);

        assertEq(staking.earned(bob), 0, "no backpay");
        assertEq(staking.earned(alice), ONE_DAY_REWARD, "alice keeps day 1");

        vm.warp(block.timestamp + 1 days);

        assertEq(staking.earned(alice), ONE_DAY_REWARD + ONE_DAY_REWARD / 2, "alice day1 + half day2");
        assertEq(staking.earned(bob), ONE_DAY_REWARD / 2, "bob half day2");
    }

    /// 不变量 4：池子空着的时候不累积 —— 代价是这段时间的奖励滞留合约、不会补发
    function test_EmptyPoolAccrualFrozen_RewardsStranded() public {
        assertEq(staking.totalSupply(), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(staking.rewardPerToken(), 0, "frozen while empty");

        _stake(alice, 100e18);

        // 从入场时刻才重新开始累积，只剩 6 天可分配
        assertEq(staking.rewards(alice), 0, "nothing retroactive");
        vm.warp(block.timestamp + DURATION);

        assertEq(staking.earned(alice), ONE_DAY_REWARD * 6, "only 6 days were distributed");
        assertEq(
            rewardToken.balanceOf(address(staking)) - staking.earned(alice),
            ONE_DAY_REWARD,
            "1 day of rewards stranded in contract"
        );
    }

    /// 上一条只断言「空池时等于 0」，如果实现写成 `if (totalSupply == 0) return 0;`
    /// 它照样通过 —— 那是假绿。这条断言「池子被清空后累计值不再变化」，
    /// 才能真正区分「短路返回常量」和「按公式不累积」
    function test_RewardPerTokenFrozenAfterPoolEmptied() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        uint256 snapshot = staking.rewardPerToken();
        assertGt(snapshot, 0, "accrued while occupied");

        // 全部退出，池子归零
        _requestUnstake(alice, 100e18);
        assertEq(staking.totalSupply(), 0, "pool emptied");

        vm.warp(block.timestamp + 1 days);
        assertEq(staking.rewardPerToken(), snapshot, "frozen after pool emptied");
        assertEq(staking.earned(alice), ONE_DAY_REWARD, "late joiners get nothing extra");
    }

    /*//////////////////////////////////////////////////////////////
                        二、周期结束就停
    //////////////////////////////////////////////////////////////*/

    function test_EarnedStopsAtPeriodFinish() public {
        _stake(alice, 100e18);

        vm.warp(staking.periodFinish() + 30 days);

        assertEq(staking.earned(alice), ONE_DAY_REWARD * 7, "capped at full period");
        uint256 snapshot = staking.rewardPerToken();

        vm.warp(block.timestamp + 365 days);
        assertEq(staking.rewardPerToken(), snapshot, "perToken frozen after finish");
        assertEq(staking.earned(alice), ONE_DAY_REWARD * 7, "earned frozen after finish");
    }

    /*//////////////////////////////////////////////////////////////
                      三、续投：剩余奖励与新奖励合并
    //////////////////////////////////////////////////////////////*/

    function test_NotifyMidPeriodMergesLeftover() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 3 days);

        // 池里只有她一个人，此刻的待领奖励就等于已经发掉的那部分
        uint256 alreadyAccrued = staking.earned(alice);
        uint256 leftover = FUND - alreadyAccrued;

        rewardToken.mint(address(staking), FUND);
        vm.prank(admin);
        staking.notifyRewardAmount(FUND);

        // 周期被重新拉长一整期，而不是接着原来的尾巴跑
        assertEq(staking.periodFinish(), block.timestamp + DURATION, "period restarted");

        vm.warp(staking.periodFinish());
        assertApproxEqAbs(staking.earned(alice) - alreadyAccrued, leftover + FUND, DURATION, "leftover + new");
    }

    /// 周期已过期时重新注入，走的是「从头开始」分支
    function test_NotifyAfterPeriodFinishStartsFreshCycle() public {
        vm.warp(block.timestamp + DURATION + 1 days);

        vm.prank(admin);
        staking.notifyRewardAmount(FUND);

        assertEq(staking.periodFinish(), block.timestamp + DURATION, "period restarted");
        assertEq(staking.rewardRate(), RATE, "rate back to clean value");
    }

    /*//////////////////////////////////////////////////////////////
                四、预算保护：同一笔钱不能被许诺两次
    //////////////////////////////////////////////////////////////*/

    function test_NotifyRevertsIfNotFunded() public {
        // 池子里只有 FUND，再注入两期就会因为「余额覆盖不了整期」而失败。
        // 只校验错误类型不校验数值：required 跟着注入额变，写死等于把公式抄进断言
        vm.prank(admin);
        vm.expectPartialRevert(StakingRewards.InsufficientRewardBalance.selector);
        staking.notifyRewardAmount(FUND * 2);
    }

    /// A-7 回归：已挂账未领的奖励不能被当成新奖励的额度重复许诺
    function test_NotifyCannotCountOwedRewardsAsBudget() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 3 days);

        // 再质押 1 wei 触发结算，把 3 天奖励从「未结算」变成「挂账未领」
        _stake(alice, 1);
        assertEq(staking.totalOwed(), ONE_DAY_REWARD * 3, "owed but unpaid");

        vm.warp(staking.periodFinish());

        vm.prank(admin);
        vm.expectPartialRevert(StakingRewards.InsufficientRewardBalance.selector);
        staking.notifyRewardAmount(FUND);
    }

    /// A-18 回归：全程没有任何人结算，未结算的应计也必须算进负债。
    /// 这条路径 A-7 的用例测不出来——它在中间主动 settle 了一次，把「未结算」变成了「挂账」
    function test_NotifyCannotCountAccruedRewardsAsBudget() public {
        _stake(alice, 200e18);
        vm.warp(block.timestamp + 3 days);

        assertEq(staking.rewards(alice), 0, "never settled");

        vm.prank(admin);
        vm.expectPartialRevert(StakingRewards.InsufficientRewardBalance.selector);
        staking.notifyRewardAmount(ONE_DAY_REWARD * 3);

        // 把欠她的那部分真的转进来，同一个调用就必须通过：证明拦住它的是负债而不是别的条件
        rewardToken.mint(address(staking), ONE_DAY_REWARD * 3);
        vm.prank(admin);
        staking.notifyRewardAmount(ONE_DAY_REWARD * 3);
    }

    /*//////////////////////////////////////////////////////////////
                            五、领取
    //////////////////////////////////////////////////////////////*/

    function test_GetRewardTransfersAndClears() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice) - before, ONE_DAY_REWARD, "paid");
        assertEq(staking.rewards(alice), 0, "cleared");

        // 同一时刻再领一次，金额应为 0（没有 revert，只是不发）
        uint256 afterFirst = rewardToken.balanceOf(alice);
        _getReward(alice);
        assertEq(rewardToken.balanceOf(alice), afterFirst, "no double pay");
    }

    /// 领走奖励之后，`rewards` 与 `totalOwed` 必须同时归零
    function test_GetRewardClearsLiability() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        // 触发结算，让应计同时落进 rewards 与 totalOwed
        _stake(alice, 1);
        assertGt(staking.totalOwed(), 0, "liability booked");

        _getReward(alice);

        assertEq(staking.rewards(alice), 0, "reward cleared");
        assertEq(staking.totalOwed(), 0, "liability cleared");

        // 同一时刻再领一次，负债不增长
        _getReward(alice);
        assertEq(staking.totalOwed(), 0, "still zero");
    }

    /*//////////////////////////////////////////////////////////////
                六、读数与实收必须是同一个数
    //////////////////////////////////////////////////////////////*/

    /// @notice `earned()` 走的是「只算不写」的那条路，`getReward()` 走的是结算那条。
    ///         两条路径要算出同一个数，断言的是这件事本身，不是某个具体金额
    function test_EarnedReadsEqualActualPayout() public {
        _stake(alice, 100e18);
        // 取非整数天的时刻：整数天的值恰好是干净倍数，可能掩盖取整口径的差异
        vm.warp(block.timestamp + 1 days + 3 hours);

        uint256 expected = staking.earned(alice);
        assertGt(expected, 0, "there is something to read");

        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice) - before, expected, "payout equals the view");
        assertEq(staking.earned(alice), 0, "view drains to zero after payout");
    }

    /// 中途换人进出会触发多次结算，每次结算都把增量累进 `rewards`。
    /// 读数要跟着结算结果走，不是每次从头算
    function test_EarnedEqualsPayoutAcrossSettlements() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        _stake(bob, 100e18); // bob 进场：第一次结算
        vm.warp(block.timestamp + 2 days);

        _requestUnstake(bob, 100e18); // bob 离场：第二次结算
        vm.warp(block.timestamp + 3 days);

        uint256 expected = staking.earned(alice);
        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice) - before, expected, "cross-settlement read equals payout");
    }

    /// 同一秒内第二次结算不产生增量：曲线不动、读数不动，也不该凭空多出奖励
    function test_RepeatSettlementSameSecondAddsNothing() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        _stake(alice, 1); // 第一次结算
        uint256 curveAfterFirst = staking.rewardPerTokenStored();
        uint256 readAfterFirst = staking.earned(alice);

        vm.warp(block.timestamp); // 时间不推进
        _stake(alice, 1); // 第二次结算，走 delta == 0 分支

        assertEq(staking.rewardPerTokenStored(), curveAfterFirst, "curve unchanged");
        assertEq(staking.earned(alice), readAfterFirst, "read unchanged");
    }

    /// 从未产生过奖励时不该 revert，也不该产生转账
    /// （区别于「领过一次再领」的那条，这里连结算都还没发生过）
    function test_ZeroRewardGetRewardDoesNotRevert() public {
        _stake(alice, 100e18);

        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice), before, "nothing moved");
        assertEq(staking.rewards(alice), 0, "nothing booked");
    }

    /// 结算边界各 floor 一次、用户跨边界一次性 floor，两者之差可以让「应发 > 负债」。
    /// 这条把那个状态摆出来，再真走一次领取：金额必须照发，负债清零，不能整笔回滚
    function test_RoundingDeficitDoesNotBlockClaim() public {
        // 尾数 1 wei：`supply · Δ` 除以 PRECISION 一定有余数，两个边界各丢一次
        _stake(alice, 1e18 + 1);

        // 两个没有任何仓位的地址各领一次：走完结算、`reward == 0` 直接返回，
        // 效果是「纯结算两次」，不改 totalSupply、不改 rewardRate，也不动 alice 的账
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
        uint256 amount = bound(uint256(rawAmount), 1e12, 100_000e18);
        uint256 t = bound(uint256(elapsed), 1, DURATION);

        stakeToken.mint(alice, amount);
        _stake(alice, amount);
        vm.warp(block.timestamp + t);

        uint256 expected = staking.earned(alice);
        uint256 before = rewardToken.balanceOf(alice);
        _getReward(alice);

        assertEq(rewardToken.balanceOf(alice) - before, expected, "fuzz: payout equals view");
        assertEq(staking.earned(alice), 0, "fuzz: view drains to zero");
    }

    /*//////////////////////////////////////////////////////////////
                        七、守恒（fuzz）
    //////////////////////////////////////////////////////////////*/

    /// 任何质押比例、任何时长下，两人收益之和都等于这段时间的产出
    function testFuzz_Conservation(uint96 amountA, uint96 amountB, uint32 elapsed) public {
        uint256 a = bound(uint256(amountA), 1e12, 100_000e18);
        uint256 b = bound(uint256(amountB), 1e12, 100_000e18);
        uint256 t = bound(uint256(elapsed), 0, DURATION);

        stakeToken.mint(alice, a);
        stakeToken.mint(bob, b);
        _stake(alice, a);
        _stake(bob, b);

        vm.warp(block.timestamp + t);

        // 用相对误差：金额变化几个数量级时，绝对容差没有意义
        assertApproxEqRel(staking.earned(alice) + staking.earned(bob), RATE * t, 1e10, "conservation");
    }
}
