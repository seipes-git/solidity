// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {ReentrantReceiver, SimpleReceiver, RejectingReceiver} from "./mocks/Receivers.sol";

/// @title ETH 池的重入面与收款方类型
/// @notice ETH 转账会把控制权交给对方，这是本合约与 ERC20 池最大的差别。
///         要证明两件事：
///           ① 重入拿不到别人的本金（上限就是自己的本金）；
///           ② push 模式下，接收方拒绝收款会让转账失败 —— 这是必须如实记录的代价。
///
/// @dev 重入测试最容易写成假绿，三条前置条件缺一不可：
///      1. 池子里必须有**别人**的钱（否则掏空自己也算「成功」）
///      2. 攻击者必须吞掉重入失败（否则整笔回滚，等于没攻击）
///      3. 必须有一条对照用例证明「同一个合约在不攻击时能正常取钱」，
///         否则失败可能只是因为合约根本转不出 ETH
contract ETHReentrancyTest is StakingRewardsETHBase {
    /// 重入要能偷到钱，前提是池子里有**别人**的本金。
    /// 攻击者在 receive 里循环重入，直到池子被掏空或调用失败
    function test_ReentrantWithdrawCannotDrainPool() public {
        // alice 的本金是攻击目标
        _stake(alice, 100 ether);

        ReentrantReceiver attacker = new ReentrantReceiver(staking);
        vm.deal(address(attacker), 10 ether);
        attacker.stake{value: 10 ether}();
        attacker.requestUnstake(10 ether);

        vm.warp(block.timestamp + COOLDOWN);
        attacker.setAttacking(true);

        attacker.withdrawPrincipal();

        // 上限就是自己的本金 —— 多拿一个 wei 都算防线失效
        assertLe(attacker.totalReceived(), 10 ether, "must not exceed own principal");
        assertEq(address(staking).balance, 100 ether, "alice principal untouched");
    }

    /// 对照实验：关闭攻击模式，同一个合约能正常取出自己的本金。
    /// 证明上一条的失败是重入造成的，不是合约本身转不出 ETH
    function test_SameReceiverWithdrawsNormallyWhenNotAttacking() public {
        _stake(alice, 100 ether);

        ReentrantReceiver receiver = new ReentrantReceiver(staking);
        vm.deal(address(receiver), 10 ether);
        receiver.stake{value: 10 ether}();
        receiver.requestUnstake(10 ether);

        vm.warp(block.timestamp + COOLDOWN);
        receiver.withdrawPrincipal();

        assertEq(receiver.totalReceived(), 10 ether, "own principal returned");
        assertEq(address(staking).balance, 100 ether, "alice principal untouched");
    }

    /// 正常的合约钱包（receive 里做点事但不重入）能收到钱
    function test_ContractWalletCanReceive() public {
        SimpleReceiver receiver = new SimpleReceiver(staking);

        // 不需要预先给 receiver 打钱：测试合约直接带 value 调用它的 stake
        receiver.stake{value: 10 ether}();
        receiver.requestUnstake(10 ether);

        vm.warp(block.timestamp + COOLDOWN);
        receiver.withdrawPrincipal();

        assertEq(address(receiver).balance, 10 ether, "principal arrived");
    }

    /// 接收方 revert 会让转账失败。这是 push 模式的固有代价，如实记录：
    /// 这类用户必须先换一个能收款的地址，合约侧没有 pull 模式的替代路径
    function test_RejectingReceiverBlocksWithdraw() public {
        RejectingReceiver receiver = new RejectingReceiver(staking);
        vm.deal(address(receiver), 10 ether);

        receiver.stake{value: 10 ether}();
        receiver.requestUnstake(10 ether);

        vm.warp(block.timestamp + COOLDOWN);

        vm.expectRevert(StakingRewardsETH.ETHTransferFailed.selector);
        receiver.withdrawPrincipal();
    }

    /// 拒绝收款只影响自己：他的本金留在 pending 里，别人的仓位和池子余额都不受影响
    function test_RejectingReceiverDoesNotAffectOthers() public {
        _stake(alice, 10 ether);

        RejectingReceiver receiver = new RejectingReceiver(staking);
        vm.deal(address(receiver), 5 ether);
        receiver.stake{value: 5 ether}();
        receiver.requestUnstake(5 ether);

        vm.warp(block.timestamp + COOLDOWN);

        vm.expectRevert(StakingRewardsETH.ETHTransferFailed.selector);
        receiver.withdrawPrincipal();

        // 他的本金仍然挂在 pending 上，alice 的本金一分未动
        assertEq(address(staking).balance, 15 ether, "both principals still held");
        _requestUnstake(alice, 10 ether);
        vm.warp(block.timestamp + COOLDOWN);
        _withdraw(alice);
        assertEq(alice.balance, 100 ether, "alice unaffected");
    }
}
