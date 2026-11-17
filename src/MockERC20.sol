// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice 测试网 / 本地演练用的 ERC20，只有部署者能 mint。
/// @dev 绝不能当真实资产：owner 私钥泄露即无限铸币，且没有市场与价值支撑。
///      历史那批无 mint 权限控制的旧实例已作废（地址见 README「已作废的历史实例」），
///      权限控制只对新部署生效，链上的旧实例改不了。
contract MockERC20 is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /// @notice 铸造新币。只有部署者能调用
    /// @dev 用 Ownable 而不是 AccessControl：这里只有一个权限、一个动作，
    ///      角色分层在单动作场景下是纯粹的开销
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
