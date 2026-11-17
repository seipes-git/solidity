// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "../../../src/MockERC20.sol";

/// @title 会在转账时回调外部合约的 ERC20
/// @notice 专供重入用例：把 `transfer` / `transferFrom` 变成攻击的触发点。
///         ERC20 池的重入面就在这里——`stake` 走 `transferFrom`，`withdraw` / `getReward`
///         走 `safeTransfer`，两条路径都会把控制权交给代币合约。
///
/// @dev 三个刻意的设计：
///      ① **吞掉回调的失败**。不吞的话整笔交易回滚，池子看起来「安全」，
///         但实际上只是攻击没打成——和防线有效是两件事
///      ② **只打一发**（`attacking` 在回调前置 false）。否则回调里再触发转账会无限递归
///      ③ **记录失败原因的选择器**。只断言「没成功」是不够的：
///         同样「没成功」，可能是被 `nonReentrant` 挡住（防线有效），
///         也可能是因为余额不够 / 参数不对（防线压根没被触发）
contract ReentrantERC20 is MockERC20 {
    /// 重入的目标（质押池）与调用载荷
    address public target;
    bytes public payload;

    /// 攻击开关。用例在真正需要触发的那一步才打开
    bool public armed;

    /// 上一次回调的结果，供断言使用
    bool public reentrySucceeded;
    bytes4 public lastRevertSelector;
    bool public attacked;

    constructor() MockERC20("Reentrant", "RE") {}

    /// @notice 打开攻击：下一次转账会向 `target` 发起 `payload`
    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
        reentrySucceeded = false;
        lastRevertSelector = bytes4(0);
        attacked = false;
    }

    function disarm() external {
        armed = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        _maybeAttack();
        return ok;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool ok = super.transferFrom(from, to, value);
        _maybeAttack();
        return ok;
    }

    function _maybeAttack() internal {
        if (!armed) return;

        // 先关再打：回调里若再触发一次转账，不会无限递归
        armed = false;
        attacked = true;

        (bool ok, bytes memory ret) = target.call(payload);
        reentrySucceeded = ok;

        if (!ok && ret.length >= 4) {
            // 取 revert 数据前 4 字节，用例据此区分「被守卫挡住」与「其它原因失败」
            bytes4 sel;
            assembly {
                sel := mload(add(ret, 32))
            }
            lastRevertSelector = sel;
        }
    }
}
