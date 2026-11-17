// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewards} from "../../../src/StakingRewards.sol";

/// @title 升级通路的最小夹具（不是产品 V2）
/// @notice 只做一件事：证明「代理指向新实现之后，新函数可调用、旧状态不丢」。
///         所以它**只加函数，不加状态变量**——继承 V1 完整布局，存储槽一个不动。
///
/// @dev 真实的 V2 应该怎么做：
///      - 新增变量必须插在 V1 的 `claimPaused` 之后、`__gap` 之前，并从 gap 里扣掉相应长度
///      - 删除、重排、改类型都会让已存数据错位，而且编译器不会报错
///      - 升级前用 `forge inspect <V2> storageLayout` 对比两份布局，逐个槽位核对
contract StakingRewardsV2Mock is StakingRewards {
    /// @notice 一个只读标记，用来确认「现在跑的确实是新实现」
    function version() external pure returns (uint256) {
        return 2;
    }

    /// @notice 模拟 V2 新增的业务函数：给用户额外记一笔「忠诚度」
    /// @dev 纯计算，不写存储——夹具不该引入新的布局风险
    function loyaltyScore(address account) external view returns (uint256) {
        return balanceOf[account] / 1e18;
    }

    /// @notice 模拟 V2 修改已有逻辑：这里故意不改任何现有函数，
    ///         真实升级里最危险的动作就是「顺手改一个已有函数的算法」
    function extraInfo() external pure returns (string memory) {
        return "v2";
    }
}
