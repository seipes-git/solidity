// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title 每次转账抽 1% 手续费的 ERC20
/// @notice 只为在 fork 上证明一件事：这类代币**不被支持**，而且失败模式是可预期的
///         —— 池子记 100，实际只收到 99，于是 `totalSupply` 大于真实余额。
/// @dev README 声明了「rewardToken / stakingToken 必须是标准 ERC20」，但声明不是证据。
///      这条 mock 把「声明之外会发生什么」变成一条会跑的用例，而不是一句口头约定
contract FeeOnTransferERC20 is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev 手续费直接烧掉，最简单也最容易验证：
    ///      转出方扣 100，接收方只收到 99，差额不留在任何地方
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * FEE_BPS) / 10_000;
        if (fee > 0) {
            super._update(from, address(0), fee); // burn
        }
        super._update(from, to, value - fee);
    }
}
