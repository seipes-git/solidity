// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../../src/MockERC20.sol";

/// @title StakingRewards（ERC20 池）的测试基座
/// @notice 这里只做三件事：把时间钉死、把币和合约造好、提供几个简化调用的 helper。
///         每个用例自己负责「摆场景 → 做动作 → 断言」，基座不替它摆场景，
///         否则用例之间会通过共享状态互相影响——那正是常见的假绿来源。
///
///         **代理部署是本基座唯一的「非业务」复杂度**：所有用例操作的都是 proxy 地址，
///         而 `staking` 这个变量指向 proxy，接口与实现合约完全相同。
///         这也是为什么改造 UUPS 只需要改这一个文件，其余用例不用动。
///
/// @dev 为什么默认 unstakeCooldown = 0：
///      冷却为 0 时 requestUnstake 直接到账，等价于「一次交易完成提取」。
///      Rewards.t.sol 和 Staking.t.sol 关心的是记账与数学，不该被冷却噪音干扰；
///      冷却本身由 Cooldown.t.sol 用另一套 setUp 专门测。
abstract contract StakingRewardsBase is Test {
    /// @notice 用户交互的地址（代理）。测试里对它的调用都会 delegatecall 到实现合约
    StakingRewards internal staking;
    /// @notice 实现合约地址。平时用不到，升级测试和「实现合约不能直接初始化」要用
    address internal implementation;
    MockERC20 internal stakeToken;
    MockERC20 internal rewardToken;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// 7 天，恰好 604800 秒
    uint256 internal constant DURATION = 7 days;
    /// 每秒释放 1 个 token
    uint256 internal constant RATE = 1e18;
    /// 恰好覆盖整期：604800 秒 × 1e18/秒。选成能被 DURATION 整除，
    /// 这样 rewardRate 没有截断，后面可以用 assertEq 而不是容差
    uint256 internal constant FUND = 604_800e18;
    /// 单池满额时一天的总产出
    uint256 internal constant ONE_DAY_REWARD = 86_400e18;
    /// 冷却测试用的标准等待时长
    uint256 internal constant COOLDOWN = 1 days;

    /// 角色 ID。Solidity 不允许通过合约类型访问 public constant，测试侧重复一份；
    /// 值必须与 StakingRewards 里的定义逐字一致，改合约时记得同步
    bytes32 internal constant MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE_ID = keccak256("GUARDIAN_ROLE");
    /// 与 AccessControl.DEFAULT_ADMIN_ROLE 相同
    bytes32 internal constant ADMIN_ROLE_ID = 0x00;

    function setUp() public virtual {
        // 时间是最重要的输入之一，起点必须确定
        vm.warp(1_700_000_000);
        _deploy(0);
    }

    /// @dev 部署一整套环境。cooldown 由调用方决定，其余参数固定
    function _deploy(uint256 cooldown) internal {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");

        // 实现合约的构造函数只做一件事：把自身的初始化器锁死，不写任何业务状态。
        // 所以这里不需要（也不能）prank——地址是谁都不影响
        StakingRewards impl = new StakingRewards();
        implementation = address(impl);

        // 代理部署与 initialize 在同一笔交易内完成。
        // prank 加在 new 之前：proxy 构造函数里的 delegatecall 会保留 msg.sender，
        // 于是 initialize 里 `_grantRole(..., msg.sender)` 授予的是 admin，而不是测试合约
        bytes memory initData =
            abi.encodeCall(StakingRewards.initialize, (stakeToken, rewardToken, DURATION, cooldown));
        vm.prank(admin);
        staking = StakingRewards(address(new ERC1967Proxy(address(impl), initData)));

        stakeToken.mint(alice, 1_000e18);
        stakeToken.mint(bob, 1_000e18);

        // approve 和 stake 是两次独立调用，各自需要 prank
        vm.prank(alice);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stakeToken.approve(address(staking), type(uint256).max);

        // notifyRewardAmount 前必须先把奖励真正转进合约
        rewardToken.mint(address(staking), FUND);
        vm.prank(admin);
        staking.notifyRewardAmount(FUND);
    }

    /// @dev 只部署到「初始化完成、但还没注资」的状态，给需要自己摆开局的用例用
    function _deployEmpty(uint256 cooldown) internal {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");

        StakingRewards impl = new StakingRewards();
        implementation = address(impl);

        bytes memory initData =
            abi.encodeCall(StakingRewards.initialize, (stakeToken, rewardToken, DURATION, cooldown));
        vm.prank(admin);
        staking = StakingRewards(address(new ERC1967Proxy(address(impl), initData)));
    }

    /// @dev 把代理指向新的实现合约，由 UPGRADER 发起
    function _upgradeTo(address newImplementation) internal {
        vm.prank(admin);
        staking.upgradeToAndCall(newImplementation, "");
    }

    /*//////////////////////////////////////////////////////////////
                                辅助
    //////////////////////////////////////////////////////////////*/

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
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
        vm.prank(admin);
        staking.grantRole(role, who);
    }

    /// @dev 以 caller 身份调合约，返回「是否成功」与「revert 数据」。
    ///      必须把 ret 一起返回：只判断 ok 会把「无权限」和「业务状态不符」混为一谈，
    ///      权限被摘掉时仍然 PASS（A-23）
    function _callAs(address caller, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(staking).call(data);
    }

    /// @dev 取 revert 数据前 4 字节，用于断言错误类型；不足 4 字节返回 0
    function _revertSelector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }
}
