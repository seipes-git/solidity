// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StakingRewardsBase} from "./StakingRewardsBase.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../../src/MockERC20.sol";

/// @title ERC20 池的 handler
/// @notice 只调用合约的公开函数，不直接改余额、不直接 transfer。
///         一旦 handler 自己动了余额，等式类不变量就会被它自己打破，测出来的红全是噪音。
///
/// @dev 每个动作都用 try/catch 吞掉「本来就该失败」的调用（例如冷却期内 withdraw），
///      否则一次合法失败就会中断整轮序列。
contract ERC20PoolHandler is Test {
    StakingRewards public immutable staking;
    MockERC20 public immutable stakeToken;
    MockERC20 public immutable rewardToken;

    address[] public actors;

    /// @dev 解锁时间的影子账本：每次挂起请求时按「当时的 block.timestamp + 当时的冷却」
    ///      算一个候选值，取历史最大值。它只由 handler 自己看到的输入推导，不读合约的
    ///      `unlockTime`，否则两边共用一个来源，断言就成了自证
    mapping(address => uint256) private _expectedUnlock;

    constructor(StakingRewards staking_, MockERC20 stakeToken_, MockERC20 rewardToken_) {
        staking = staking_;
        stakeToken = stakeToken_;
        rewardToken = rewardToken_;

        // 只造地址，不发币：mint 权限在测试合约（MockERC20 的 owner）手里，
        // handler 自己铸不出来。发币与 approve 由测试的 setUp 完成
        for (uint256 i; i < 3; ++i) {
            actors.push(makeAddr(string.concat("erc20Actor", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice 影子账本里这个地址的解锁时间下限
    function expectedUnlock(address actor) external view returns (uint256) {
        return _expectedUnlock[actor];
    }

    /// @notice 改冷却。需要 DEFAULT_ADMIN_ROLE，由测试的 setUp 授予
    function setCooldown(uint256 seed) external {
        try staking.setUnstakeCooldown(bound(seed, 0, 30 days)) {} catch {}
    }

    function stake(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 wallet = stakeToken.balanceOf(actor);
        if (wallet == 0) return;

        amount = bound(amount, 1, wallet);
        vm.prank(actor);
        try staking.stake(amount) {} catch {}
    }

    function requestUnstake(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        uint256 position = staking.balanceOf(actor);
        if (position == 0) return;

        amount = bound(amount, 1, position);
        // 冷却必须在调用前读：合约用的是调用那一刻的值，影子要与它同源同时刻
        uint256 cooldown = staking.unstakeCooldown();

        vm.prank(actor);
        try staking.requestUnstake(amount) {
            if (cooldown != 0) _noteRequest(actor, cooldown);
        } catch {}
    }

    function withdraw(uint256 seed) external {
        address actor = _actor(seed);
        vm.prank(actor);
        try staking.withdraw() {
            // 提取会清空 pendingUnstake，影子跟着归零，否则下一次请求会拿旧下限比对
            delete _expectedUnlock[actor];
        } catch {}
    }

    function getReward(uint256 seed) external {
        vm.prank(_actor(seed));
        try staking.getReward() {} catch {}
    }

    function exit(uint256 seed) external {
        address actor = _actor(seed);
        uint256 position = staking.balanceOf(actor);
        uint256 cooldown = staking.unstakeCooldown();
        // exit 会先把「已解锁」的待提本金提走（清空 pending），再用剩余余额挂新请求。
        // 不把这个内嵌的 withdraw 记进影子，影子会留着一条已经兑现的下限
        (, bool unlocked) = staking.withdrawable(actor);

        vm.prank(actor);
        try staking.exit() {
            if (unlocked) delete _expectedUnlock[actor];
            // exit 内部会以同一时刻、同一冷却调 requestUnstake
            if (position != 0 && cooldown != 0) _noteRequest(actor, cooldown);
        } catch {}
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 12 hours));
    }

    /// @dev 续投：先把奖励币转进合约再 notify。失败时币留在合约里，
    ///      体积上变成「多于负债」，不破坏等式类不变量
    function notify(uint256 amount) external {
        uint256 wallet = rewardToken.balanceOf(address(this));
        if (wallet == 0) return;

        amount = bound(amount, 1, wallet);
        if (!rewardToken.transfer(address(staking), amount)) return;
        try staking.notifyRewardAmount(amount) {} catch {}
    }

    function _noteRequest(address actor, uint256 cooldown) internal {
        uint256 candidate = block.timestamp + cooldown;
        if (candidate > _expectedUnlock[actor]) _expectedUnlock[actor] = candidate;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// @title ERC20 池的状态型不变量
/// @notice 与单点用例的区别：fuzzer 自己拼操作序列（存 → 存 → 部分退 → 跳时间 → 领奖 → 再存），
///         每次 run 从同一个 setUp 出发但走不同的路径。本金安全恰好是序列性质，
///         单点用例走不到这种组合。
///
/// @dev 等式而不是 ≥：`≥` 在「只入不出」的路径上容易恒真，等于没测。
contract ERC20PoolInvariantsTest is StdInvariant, StakingRewardsBase {
    /// @dev 取整 dust 的容差。见 `invariant_RewardLiabilityWithinBalance` 的说明
    uint256 private constant ROUNDING_DUST = 1e6;

    ERC20PoolHandler internal handler;

    function setUp() public override {
        // 带冷却：零冷却时 pendingUnstake 永远为空，等式会退化成「余额 == totalSupply」
        vm.warp(1_700_000_000);
        _deploy(COOLDOWN);

        handler = new ERC20PoolHandler(staking, stakeToken, rewardToken);

        // 给 actors 发币并授权：mint 只有 owner（本测试合约）能调
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            stakeToken.mint(actor, 10_000e18);
            vm.prank(actor);
            stakeToken.approve(address(staking), type(uint256).max);
        }

        rewardToken.mint(address(handler), 1_000_000e18);

        // handler 要能改冷却，否则 `setCooldown` 每次都撞权限、参数抖动这条路径根本不存在
        _grantRole(ADMIN_ROLE_ID, address(handler));

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              不变量
    //////////////////////////////////////////////////////////////*/

    /// 合约持有的质押币 == 账面仓位 + 所有地址冷却中的本金
    function invariant_PrincipalFullyBacked() public view {
        uint256 pending;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            (uint256 amount,) = staking.pendingUnstake(handler.actors(i));
            pending += amount;
        }

        assertEq(stakeToken.balanceOf(address(staking)), staking.totalSupply() + pending, "principal fully backed");
    }

    /// 双向夹逼：所有地址挂账之和不超过负债，负债不超过奖励币余额
    ///
    /// @dev 左边的 dust 容差只服务于本不变量自身，**不再承担「绕过已知取整缺陷」的角色**：
    ///      两处取整口径本来就不同——`totalOwed` 每个结算边界各 floor 一次
    ///      （`supply * delta / PRECISION`），而某个用户的 `rewards` 是他跨多个边界的
    ///      **一次性** floor（Σfloor ≤ floor(Σ)），逐户求和可以超出负债 n-1 wei。
    ///      这个差额在 `getReward` / `emergencyWithdraw` 里由「`reward >= owed` 则清零」的
    ///      夹逼吸收，不会下溢；本不变量仍用 1e6 只是为了让「序列级求和」不因这几 wei 抖动。
    ///      上限量级：深度 32 的序列里每个 actor 最多几十 wei
    function invariant_RewardLiabilityWithinBalance() public view {
        uint256 booked;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            booked += staking.rewards(handler.actors(i));
        }

        uint256 owed = staking.totalOwed();
        assertLe(booked, owed + ROUNDING_DUST, "booked rewards <= liability (+ dust)");
        assertLe(owed, rewardToken.balanceOf(address(staking)), "liability <= reward balance");
    }

    /// 挂着的解锁请求，其解锁时间不早于「历次请求里最晚的那次」。
    /// 手续费在这里：冷却可以在序列中途被改短，而已经挂起的额度按请求发生时的冷却算
    function invariant_UnlockTimeNeverShortened() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            (, uint256 unlockTime) = staking.pendingUnstake(actor);
            assertGe(unlockTime, handler.expectedUnlock(actor), "unlock time never moved earlier");
        }
    }

    /*//////////////////////////////////////////////////////////////
                          夹具自检
    //////////////////////////////////////////////////////////////*/

    /// handler 的调用能真的落到合约上。没有这一条，一次「所有调用都失败」的
    /// handler 会让两个不变量在空状态上平凡成立
    function test_HandlerReachesContract() public {
        uint256 poolBefore = stakeToken.balanceOf(address(staking));

        handler.stake(0, 10e18);
        assertEq(staking.balanceOf(handler.actors(0)), 10e18, "stake reached the pool");
        assertEq(stakeToken.balanceOf(address(staking)) - poolBefore, 10e18, "tokens moved");

        handler.requestUnstake(0, 10e18);
        (uint256 pending,) = staking.pendingUnstake(handler.actors(0));
        assertEq(pending, 10e18, "request reached the pool");
    }

    /// 改冷却这个动作真的落到了合约上，且影子账本跟着走。
    /// 没有这一条，`invariant_UnlockTimeNeverShortened` 在「影子恒为 0」时会平凡成立
    function test_CooldownChangeReachesContractAndShadowTracks() public {
        handler.setCooldown(20 days);
        assertEq(staking.unstakeCooldown(), 20 days, "cooldown applied");

        handler.stake(0, 100e18);
        handler.requestUnstake(0, 100e18);

        address actor = handler.actors(0);
        (uint256 pending, uint256 unlockTime) = staking.pendingUnstake(actor);
        assertEq(pending, 100e18, "request landed");
        assertEq(unlockTime, block.timestamp + 20 days, "deadline from the cooldown of that moment");
        assertEq(handler.expectedUnlock(actor), unlockTime, "shadow matches the pool");

        // 冷却改短后再挂一笔：老额度的解锁时间更晚，必须被保留
        handler.setCooldown(1 days);
        handler.stake(0, 100e18);
        handler.requestUnstake(0, 100e18);

        (, uint256 unlockTimeAfter) = staking.pendingUnstake(actor);
        assertEq(unlockTimeAfter, unlockTime, "a shorter cooldown does not pull the deadline forward");
        assertEq(handler.expectedUnlock(actor), unlockTimeAfter, "shadow keeps the later deadline");
    }
}
