// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";

/// @title ETH 池的本金流转：存入、解押、提取、退出
/// @notice 与 ERC20 池相比这里多一个必须盯住的量：`totalPending`。
///         本金一旦进入冷却，它就从 `totalSupply` 搬到 `totalPending`，
///         两个数相加才是合约真正欠用户的钱。`recoverETH` 的上限就靠它。
///
///         所以每个用例的断言都成对出现：仓位变了，`totalPending` 必须同步变。
///         只断言 `address(staking).balance` 会漏掉「记账和余额脱节」这类问题。
contract ETHStakingTest is StakingRewardsETHBase {
    /*//////////////////////////////////////////////////////////////
                          一、质押本身的记账
    //////////////////////////////////////////////////////////////*/

    function test_StakeMovesETHIntoContract() public {
        _stake(alice, 10 ether);

        assertEq(staking.balanceOf(alice), 10 ether, "position recorded");
        assertEq(staking.totalSupply(), 10 ether, "supply recorded");
        assertEq(address(staking).balance, 10 ether, "ETH actually arrived");
        assertEq(alice.balance, 90 ether, "wallet debited");
    }

    function test_StakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewardsETH.ZeroAmount.selector);
        staking.stake{value: 0}();
    }

    function test_StakeBelowMinimumReverts() public {
        staking.setMinStakeAmount(5 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.BelowMinStake.selector, 1 ether, 5 ether));
        staking.stake{value: 1 ether}();
    }

    /// 边界是 `>=`：正好等于下限应当通过
    function test_StakeAtMinimumAccepted() public {
        staking.setMinStakeAmount(5 ether);

        _stake(alice, 5 ether);
        assertEq(staking.balanceOf(alice), 5 ether, "boundary accepted");
    }

    /// 往合约直转 ETH 不改变任何记账。这些钱不属于任何人，只有 recoverETH 能动
    function test_DonationDoesNotInflateAccounting() public {
        _stake(alice, 10 ether);
        vm.deal(address(staking), 13 ether); // 模拟手滑直转 3 ETH

        assertEq(staking.totalSupply(), 10 ether, "supply untouched");
        assertEq(staking.balanceOf(alice), 10 ether, "position untouched");

        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, 13 ether, "contract holds more");
        assertEq(owed, 10 ether, "only 10 is user money");
        assertEq(surplus, 3 ether, "the rest is nobody's");
    }

    /*//////////////////////////////////////////////////////////////
                        二、发起解押：本金搬到 pending
    //////////////////////////////////////////////////////////////*/

    function test_RequestUnstakeMovesToPending() public {
        _stake(alice, 10 ether);

        _requestUnstake(alice, 10 ether);

        assertEq(staking.balanceOf(alice), 0, "position cleared");
        assertEq(staking.totalSupply(), 0, "supply cleared");

        (uint256 pending, uint256 unlockAt) = staking.pendingUnstake(alice);
        assertEq(pending, 10 ether, "pending recorded");
        assertEq(staking.totalPending(), 10 ether, "aggregate pending");
        assertEq(unlockAt, block.timestamp + COOLDOWN, "unlock scheduled");

        // ETH 仍在合约里，只是归属从「计息本金」变成「待退还本金」
        assertEq(address(staking).balance, 10 ether, "ETH still held");
    }

    /// 只有部分解押时，剩下的仓位继续计息，pending 只记扣掉的那部分
    function test_PartialRequestKeepsRestStaked() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 4 ether);

        assertEq(staking.balanceOf(alice), 6 ether, "rest stays staked");
        assertEq(staking.totalSupply(), 6 ether, "supply reflects the rest");
        assertEq(staking.totalPending(), 4 ether, "only the request is pending");
    }

    function test_RequestUnstakeMoreThanBalanceReverts() public {
        _stake(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsETH.InsufficientBalance.selector, 20 ether, 10 ether));
        staking.requestUnstake(20 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            三、提取本金
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawAfterUnlockReturnsExactETH() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        vm.warp(block.timestamp + COOLDOWN);

        uint256 before = alice.balance;
        _withdraw(alice);

        assertEq(alice.balance, before + 10 ether, "principal returned to the wei");
        assertEq(staking.totalPending(), 0, "aggregate pending cleared");
        assertEq(address(staking).balance, 0, "contract emptied of principal");
    }

    /// 提取两次：第二次必须是「没有东西可取」，而不是「成功转 0」
    function test_WithdrawTwiceReverts() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);
        vm.warp(block.timestamp + COOLDOWN);

        _withdraw(alice);

        vm.prank(alice);
        vm.expectRevert(StakingRewardsETH.NothingToWithdraw.selector);
        staking.withdraw();
    }

    /*//////////////////////////////////////////////////////////////
                    四、冷却为 0：提取退化成单笔
    //////////////////////////////////////////////////////////////*/

    function test_ZeroCooldownReturnsPrincipalImmediately() public {
        _deploy(0);
        _stake(alice, 10 ether);

        _requestUnstake(alice, 4 ether);

        assertEq(staking.balanceOf(alice), 6 ether, "shares deducted");
        assertEq(staking.totalPending(), 0, "no pending request when cooldown is zero");
        // 100 - 10（质押）+ 4（当场退回）
        assertEq(alice.balance, 94 ether, "4 ETH returned in the same tx");
    }

    function test_ZeroCooldownWithdrawReverts() public {
        _deploy(0);
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(StakingRewardsETH.NothingToWithdraw.selector);
        staking.withdraw();
    }

    /*//////////////////////////////////////////////////////////////
                                五、退出
    //////////////////////////////////////////////////////////////*/

    /// 冷却模式下 exit 只完成一半：奖励到账，本金进冷却
    function test_ExitLeavesPrincipalPending() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.exit();

        assertApproxEqAbs(rewardToken.balanceOf(alice), ONE_DAY_REWARD, 1e6, "reward paid immediately");
        assertEq(staking.balanceOf(alice), 0, "shares cleared");
        assertEq(staking.totalPending(), 10 ether, "principal pending, not lost");
        assertEq(alice.balance, 90 ether, "wallet still short");
    }

    /// 冷却为 0 时 exit 一笔完成：份额清零、本金与奖励都到账
    function test_ExitClearsEverythingWhenNoCooldown() public {
        _deploy(0);
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.exit();

        assertEq(staking.balanceOf(alice), 0, "no shares");
        assertEq(staking.totalSupply(), 0, "pool empty");
        assertEq(staking.rewards(alice), 0, "rewards cleared");
        assertEq(alice.balance, 100 ether, "principal returned");
        assertApproxEqAbs(rewardToken.balanceOf(alice), ONE_DAY_REWARD, 1e6, "reward paid");
    }

    /// 提前把奖励领光、仓位仍在时，`rewards` 为 0 的 exit 仍应正常返回
    function test_ExitWithZeroRewardDoesNotRevert() public {
        _stake(alice, 10 ether);
        vm.warp(block.timestamp + 1 days);

        _getReward(alice); // 先领一次，份额还在

        vm.prank(alice);
        staking.exit(); // 此时 rewards 为 0，仍应正常返回

        assertEq(staking.balanceOf(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              六、不变量
    //////////////////////////////////////////////////////////////*/

    /// 无论质押多少，合约持有的 ETH 都必须覆盖「仓位 + 冷却中本金」
    function testFuzz_ContractSolvent(uint96 amount) public {
        uint256 a = bound(uint256(amount), 1, 50 ether);

        _stake(alice, a);
        _requestUnstake(alice, a);

        (uint256 held, uint256 owed,) = staking.ethAccounting();
        assertGe(held, owed, "held must cover owed");
        assertEq(owed, a, "owed equals what was staked");
    }

    /// 提取之后合约里不留任何多头寸：held == owed == 0
    function testFuzz_WithdrawLeavesNothingBehind(uint96 amount) public {
        uint256 a = bound(uint256(amount), 1, 50 ether);

        _stake(alice, a);
        _requestUnstake(alice, a);
        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);

        (uint256 held, uint256 owed,) = staking.ethAccounting();
        assertEq(held, 0, "no ETH left");
        assertEq(owed, 0, "no liability left");
    }
}
