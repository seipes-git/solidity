// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice 仅供测试网与本地演练使用的 ERC20，铸造权归部署者。
/// @dev 早期版本没有 mint 权限控制，任何人都能无限铸，只能用来验证逻辑。
///      现在加了 onlyOwner：部署者（构造函数的 msg.sender）是唯一能铸的人。
///
///      **注意**：已经部署在链上的旧实例改不了，权限控制只对**新部署**生效。
///      旧地址 `0x354C959d…F8Bf` / `0x416a8c97…d90A` 仍然谁都能铸，不要在上面放真东西。
///
///      这个合约依然**绝不能**当作真实资产：owner 私钥泄露就等于无限铸币，
///      而且它没有市场、没有流动性、没有任何价值支撑。
contract MockERC20 is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /// @notice 铸造新币。只有部署者能调用
    /// @dev 用 Ownable 而不是 AccessControl：这里只有一个权限、一个动作，
    ///      角色分层在单动作场景下是纯粹的开销
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
