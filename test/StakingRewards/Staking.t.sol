// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";

/// @title 本金流转：存入、提取、退出
/// @notice 这一组只关心「钱进出时的记账是否同步」，不关心奖励算法（那是 Rewards.t.sol）。
///         断言的共同点是四个数字必须一起变：totalSupply、balanceOf、用户钱包、合约余额
contract StakingTest is StakingRewardsBase {
    /*//////////////////////////////////////////////////////////////
                          一、质押本身的记账
    //////////////////////////////////////////////////////////////*/

    function test_StakeUpdatesAccounting() public {
        _stake(alice, 100e18);

        assertEq(staking.totalSupply(), 100e18, "totalSupply");
        assertEq(staking.balanceOf(alice), 100e18, "user balance");
        assertEq(stakeToken.balanceOf(alice), 900e18, "wallet");
        assertEq(stakeToken.balanceOf(address(staking)), 100e18, "contract holds principal");
    }

    /// 往合约直转 stakingToken 不改变任何记账（不能用 balanceOf 当 totalSupply）
    function test_DonationDoesNotInflateAccounting() public {
        _stake(alice, 100e18);

        stakeToken.mint(address(staking), 50e18); // 模拟「手滑直转」

        assertEq(staking.totalSupply(), 100e18, "totalSupply untouched");
        assertEq(staking.balanceOf(alice), 100e18, "user share untouched");
        assertEq(stakeToken.balanceOf(address(staking)), 150e18, "contract balance did grow");
    }

    /*//////////////////////////////////////////////////////////////
              二、冷却为 0：提取退化成单笔，一次交易完成
    //////////////////////////////////////////////////////////////*/

    function test_ZeroCooldownTransfersImmediately() public {
        _stake(alice, 100e18);

        // cooldown = 0 时 requestUnstake 直接转账，不产生挂起请求
        _requestUnstake(alice, 40e18);

        assertEq(staking.balanceOf(alice), 60e18, "shares deducted");
        assertEq(staking.totalSupply(), 60e18, "supply deducted");
        assertEq(stakeToken.balanceOf(alice), 940e18, "principal returned in the same tx");

        (uint256 pending,) = staking.pendingUnstake(alice);
        assertEq(pending, 0, "no pending request when cooldown is zero");
    }

    function test_ZeroCooldownWithdrawReverts() public {
        _stake(alice, 100e18);
        _requestUnstake(alice, 40e18);

        // 本金已经在 requestUnstake 里到账，withdraw 没有东西可取
        vm.prank(alice);
        vm.expectRevert(StakingRewards.NothingToWithdraw.selector);
        staking.withdraw();
    }

    /*//////////////////////////////////////////////////////////////
                            三、失败路径
    //////////////////////////////////////////////////////////////*/

    function test_StakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_RequestUnstakeZeroReverts() public {
        _stake(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.requestUnstake(0);
    }

    function test_RequestUnstakeMoreThanBalanceReverts() public {
        _stake(alice, 100e18);

        vm.prank(alice);
        // expectRevert 写在「触发 revert 的那次调用」之前，中间不能插别的外部调用
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InsufficientBalance.selector, 200e18, 100e18));
        staking.requestUnstake(200e18);
    }

    function test_WithdrawWithoutRequestReverts() public {
        // 从没发起过解押，直接来取本金
        vm.prank(alice);
        vm.expectRevert(StakingRewards.NothingToWithdraw.selector);
        staking.withdraw();
    }

    /*//////////////////////////////////////////////////////////////
                            四、最小质押额
    //////////////////////////////////////////////////////////////*/

    function test_MinStakeEnforced() public {
        vm.prank(admin);
        staking.setMinStakeAmount(10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.BelowMinStake.selector, 5e18, 10e18));
        staking.stake(5e18);

        // 刚好等于下限应当通过（边界是 >=）
        _stake(alice, 10e18);
        assertEq(staking.balanceOf(alice), 10e18, "boundary accepted");
    }

    /// 调整下限不能影响已有仓位：用户可以继续持有低于新下限的份额
    function test_MinStakeDoesNotRetroact() public {
        _stake(alice, 5e18);

        vm.prank(admin);
        staking.setMinStakeAmount(10e18);

        assertEq(staking.balanceOf(alice), 5e18, "existing position untouched");

        // 但不能只追加 1 wei 来绕过下限，单次 stake 仍要满足最小值
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.BelowMinStake.selector, 1, 10e18));
        staking.stake(1);

        // 提取不受下限约束
        _requestUnstake(alice, 5e18);
        assertEq(staking.balanceOf(alice), 0, "exit below minimum allowed");
    }

    /*//////////////////////////////////////////////////////////////
                              五、退出
    //////////////////////////////////////////////////////////////*/

    /// cooldown = 0 时 exit 应当一笔完成：份额清零、本金与奖励都到账
    function test_ExitClearsEverything() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        uint256 walletBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        staking.exit();

        assertEq(staking.balanceOf(alice), 0, "no shares");
        assertEq(staking.totalSupply(), 0, "pool empty");
        assertEq(staking.rewards(alice), 0, "rewards cleared");
        assertEq(stakeToken.balanceOf(alice), 1_000e18, "principal returned");
        assertEq(rewardToken.balanceOf(alice) - walletBefore, ONE_DAY_REWARD, "reward paid");
    }

    /// 提前把奖励领光、仓位仍在时，`rewards` 为 0 的 exit 仍应正常返回
    function test_ExitWithZeroRewardDoesNotRevert() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.getReward(); // 先领一次，份额还在

        vm.prank(alice);
        staking.exit(); // 此时 rewards 为 0，仍应正常返回

        assertEq(staking.balanceOf(alice), 0);
    }
}
