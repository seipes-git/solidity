// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETH} from "../../../src/StakingRewardsETH.sol";

/// @dev 在 receive 里重入 withdraw，并用 try/catch 吞掉失败。
///      **必须吞掉**：不吞的话递归到最后一次必然因余额不足而失败，
///      整笔交易回滚，攻击一分钱也拿不到，测试就失去了意义。
///      这也是重入测试最常见的假绿来源——看起来「防住了」，其实是攻击根本没成立
contract ReentrantReceiver {
    StakingRewardsETH internal immutable staking;
    bool internal attacking;
    uint256 public totalReceived;

    constructor(StakingRewardsETH staking_) {
        staking = staking_;
    }

    function setAttacking(bool on) external {
        attacking = on;
    }

    function stake() external payable {
        staking.stake{value: msg.value}();
    }

    function requestUnstake(uint256 amount) external {
        staking.requestUnstake(amount);
    }

    function withdrawPrincipal() external {
        staking.withdraw();
    }

    receive() external payable {
        totalReceived += msg.value;

        // 只要池子里还有钱，就继续尝试重入；失败被吞掉，不影响外层
        if (attacking && address(staking).balance >= 1 ether) {
            try staking.withdraw() {} catch {}
        }
    }
}

/// @dev 普通合约钱包：receive 里只记账，不重入
contract SimpleReceiver {
    StakingRewardsETH internal immutable staking;

    constructor(StakingRewardsETH staking_) {
        staking = staking_;
    }

    function stake() external payable {
        staking.stake{value: msg.value}();
    }

    function requestUnstake(uint256 amount) external {
        staking.requestUnstake(amount);
    }

    function withdrawPrincipal() external {
        staking.withdraw();
    }

    receive() external payable {}
}

/// @dev 拒绝收款的合约：用来验证 push 模式的失败路径。
///      本合约用 `call` 转账并检查返回值，所以这里会以 ETHTransferFailed 结束，
///      而不是像 `transfer` 那样因为 2300 gas 而静默失败
contract RejectingReceiver {
    StakingRewardsETH internal immutable staking;
    bool internal withdrawing;

    constructor(StakingRewardsETH staking_) {
        staking = staking_;
    }

    function stake() external payable {
        staking.stake{value: msg.value}();
    }

    function requestUnstake(uint256 amount) external {
        staking.requestUnstake(amount);
    }

    function withdrawPrincipal() external {
        withdrawing = true;
        staking.withdraw();
        withdrawing = false;
    }

    receive() external payable {
        if (withdrawing) revert("no thanks");
    }
}
