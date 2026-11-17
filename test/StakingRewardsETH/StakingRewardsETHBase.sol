// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {MockERC20} from "../../src/MockERC20.sol";

/// @title StakingRewardsETH（原生 ETH 池）的测试基座
/// @notice 与 ERC20 池的基座结构一致，差别只有三处：
///         ① 没有代理——这个合约还是 constructor 版，直接 `new`
///         ② 不 approve，ETH 通过 `msg.value` 进合约
///         ③ 测试合约要能收 ETH，否则 `recoverETH` 把余量转回 admin 时会失败
///
/// @dev `admin = address(this)`：合约部署者就是测试合约，构造函数的 `_grantRole` 把
///      三个角色都给了它。所以在治理用例里可以不 prank 直接调用管理函数，
///      而在「非授权者被拒」的用例里用 alice / bob 去当外人。
abstract contract StakingRewardsETHBase is Test {
    StakingRewardsETH internal staking;
    MockERC20 internal rewardToken;

    address internal admin = address(this);
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DURATION = 7 days;
    uint256 internal constant COOLDOWN = 1 days;
    /// 每秒释放 1 枚。与 ERC20 池取同一套参数，速率不产生整除截断
    uint256 internal constant RATE = 1e18;
    /// 恰好覆盖整期：604800 秒 × 1 枚/秒
    uint256 internal constant FUND = 604_800e18;
    /// 单池满额时一天的总产出。速率干净时它正好是 86,400 枚
    uint256 internal constant ONE_DAY_REWARD = 86_400e18;

    /// 角色 ID。与 StakingRewardsETH 里的定义逐字一致
    bytes32 internal constant MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE_ID = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant ADMIN_ROLE_ID = 0x00;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        _deploy(COOLDOWN);
    }

    /// @dev 默认带 1 天冷却：两阶段退出和 `totalPending` 是本合约的重点，
    ///      冷却为 0 时那条路径根本不存在
    function _deploy(uint256 cooldown) internal {
        rewardToken = new MockERC20("Reward", "RWD");
        staking = new StakingRewardsETH(IERC20(address(rewardToken)), DURATION, cooldown);

        // notifyRewardAmount 前必须先把奖励真正转进合约
        rewardToken.mint(address(staking), FUND);
        staking.notifyRewardAmount(FUND);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /// @dev 只部署不注资，给需要自己摆奖励开局的用例
    function _deployEmpty(uint256 cooldown) internal {
        rewardToken = new MockERC20("Reward", "RWD");
        staking = new StakingRewardsETH(IERC20(address(rewardToken)), DURATION, cooldown);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                辅助
    //////////////////////////////////////////////////////////////*/

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake{value: amount}();
    }

    function _requestUnstake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.requestUnstake(amount);
    }

    function _withdraw(address who) internal {
        vm.prank(who);
        staking.withdraw();
    }

    function _getReward(address who) internal {
        vm.prank(who);
        staking.getReward();
    }

    function _grantRole(bytes32 role, address who) internal {
        staking.grantRole(role, who);
    }

    /// @dev 以 caller 身份调合约，返回「是否成功」与「revert 数据」。
    ///      权限用例必须同时断言「失败」和「失败原因」，否则业务状态的 revert 会被当成权限生效
    function _callAs(address caller, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(staking).call(data);
    }

    function _revertSelector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }

    /// @dev `recoverETH` 把余量转给 admin，而 admin 就是本合约。
    ///      没有这个函数，那条用例会栽在「接收方没有 receive」上
    receive() external payable {}
}
