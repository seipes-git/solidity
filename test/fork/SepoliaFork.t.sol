// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {StakingRewardsV2} from "../../src/StakingRewardsV2.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";

/// @title fork 测试：对着**真实已部署的实例**跑，而不是测试里新部署的副本
/// @notice 前面 268 条都在本地 EVM 上，测的是「代码逻辑对不对」。
///         这一组补三类本地测不出来的东西：
///           ① 代理 + 实现这个真实组合能不能用（升级过的实例，代码与存储分在两个地址）
///           ② 真实计价下的 gas（Sepolia 已启用 EIP-8037，本地 cancun 按 200/字节算）
///           ③ 非标准代币的失败模式（README 声明「必须是标准 ERC20」，这里把后果跑出来）
///
/// @dev 门禁：没有 `SEPOLIA_RPC_URL` 就整组 skip。
///      CI 里没有 RPC、也不该让 CI 依赖公网节点——fork 测试是本地/手动的一道关卡，
///      不是每次 push 都要跑的东西。这个判断放在 setUp 里，四个用例一起跳过，
///      不会出现「部分红部分绿」的半截状态。
contract SepoliaForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                          真实链上的地址
    //////////////////////////////////////////////////////////////*/

    /// ERC20 池：代理（用户唯一交互的地址），实现已在 2026-11-17 换到 V2
    address internal constant PROXY = 0xa10313F431f506028b7AB1b06be33556EA21015D;
    address internal constant IMPL_V2 = 0x1A81e04A8B01580b44d3e84fF49D0518D8B45437;
    address internal constant STK = 0x3F0211345ce621f3845455E6937670f1F4acBf29;
    address internal constant RWD = 0xC3F080d818D8433cB6ffc5c31E1283Da705545B0;

    /// ETH 池：构造版，没有代理
    address internal constant ETH_POOL = 0x2F8663eDa091976c2257c3B1534aEb75F3a833d6;

    /// STK / RWD 的 owner，也就是部署者。fork 上它仍然能 mint
    address internal constant TOKEN_OWNER = 0x42f3F79D6bA98aaE7D82ee48eB191fdcd4B8870e;

    address internal user = makeAddr("forkUser");

    function setUp() public {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            // 不打 revert：本地没有 RPC 时应当安静跳过，而不是让整次 `forge test` 变红
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
    }

    /// @dev 复刻合约里 `_updateReward` 的增量算式，但不写状态：
    ///      `totalOwed` 只在结算点增长，外部直接读它算偿付率会偏低
    function _liveOwed(StakingRewardsETH pool) internal view returns (uint256) {
        uint256 delta = pool.rewardPerToken() - pool.rewardPerTokenStored();
        return pool.totalOwed() + (pool.totalSupply() * delta) / 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                    ① 真实实例：代理 + V2 实现这个组合
    //////////////////////////////////////////////////////////////*/

    /// @dev 本地写 20 条升级用例也证明不了「线上那个代理指向的确实是 V2」——
    ///      这条用例读的是链上真实状态，不依赖任何本地部署
    function test_Fork_ERC20PoolIsLiveAndPointsToV2() public view {
        // 读 version() 得用 V2 的类型：代理上是 V2，V1 的 ABI 里没有这个函数
        StakingRewardsV2 pool = StakingRewardsV2(PROXY);

        assertEq(pool.version(), 2, "live proxy is not on V2");
        assertEq(pool.implementation(), IMPL_V2, "implementation drifted");
        assertEq(address(pool.stakingToken()), STK, "staking token");
        assertEq(address(pool.rewardToken()), RWD, "reward token");
        assertGt(pool.periodFinish(), block.timestamp, "reward period already over");
    }

    /// @dev 完整走一遍「存入 → 计息 → 领取」，对手是真实部署的合约
    function test_Fork_StakeAndClaimAgainstLivePool() public {
        StakingRewards pool = StakingRewards(PROXY);

        // fork 上 owner 仍然能 mint，照它的真实权限来造币，比直接改存储更接近真实路径
        vm.prank(TOKEN_OWNER);
        MockERC20(STK).mint(user, 100e18);

        vm.startPrank(user);
        IERC20(STK).approve(PROXY, type(uint256).max);
        pool.stake(10e18);
        vm.stopPrank();

        assertEq(pool.balanceOf(user), 10e18, "position not credited");

        // 池子里原本只有 100 STK + 1 wei，这里会稀释，但「有没有在涨」不受影响
        vm.warp(block.timestamp + 1 hours);
        uint256 accrued = pool.earned(user);
        assertGt(accrued, 0, "no reward accrued on a live pool");

        uint256 before = IERC20(RWD).balanceOf(user);
        vm.prank(user);
        pool.getReward();
        assertEq(IERC20(RWD).balanceOf(user) - before, accrued, "paid amount != earned");
    }

    /*//////////////////////////////////////////////////////////////
                    ② ETH 池：连 emergencyWithdraw 一起跑
    //////////////////////////////////////////////////////////////*/

    /// @dev `emergencyWithdraw` 此前只有单测证据，从没在真实部署的实例上执行过。
    ///      fork 是它最接近生产的一次验证：合约代码、存储、余额都是链上那份，
    ///      只是执行发生在本地副本里，不会动到真实测试网状态
    function test_Fork_ETHPoolEmergencyWithdrawOnLiveContract() public {
        StakingRewardsETH pool = StakingRewardsETH(payable(ETH_POOL));

        vm.deal(user, 1 ether);
        uint256 walletBefore = user.balance;

        vm.prank(user);
        pool.stake{value: 0.01 ether}();
        assertEq(pool.balanceOf(user), 0.01 ether, "stake not recorded");

        vm.warp(block.timestamp + 1 hours);
        uint256 forfeitable = pool.earned(user);
        assertGt(forfeitable, 0, "nothing to forfeit, the test proves nothing");

        uint256 supplyBefore = pool.totalSupply();
        // totalOwed 是惰性的：直接读它是「上次结算时」的值，跟放弃额不可比。
        // 必须先按同一套公式算出「此刻的实时负债」，才能验证销账是否精确
        uint256 owedLiveBefore = _liveOwed(pool);

        vm.prank(user);
        pool.emergencyWithdraw();

        // 本金一分不少地回来了：不扣奖励、不打折、不看冷却
        assertEq(user.balance, walletBefore, "principal not returned in full");
        assertEq(pool.balanceOf(user), 0, "position not cleared");
        assertEq(pool.totalSupply(), supplyBefore - 0.01 ether, "totalSupply not decremented");

        // 负债权同步销账，且金额正好等于放弃的那笔——多销是吞钱，少销是留假账
        assertEq(pool.rewards(user), 0, "forfeited reward still booked");
        assertApproxEqAbs(pool.totalOwed(), owedLiveBefore - forfeitable, 1e6, "liability not written off exactly");
    }

    /*//////////////////////////////////////////////////////////////
                        ③ 真实计价下的 gas
    //////////////////////////////////////////////////////////////*/

    /// @dev 只打印不卡死：gas 会随存储状态变化，写死阈值等于给自己埋一颗定时炸弹。
    ///      这里保留宽松上下界，只为拦住「量级错了」这种回归。
    ///
    ///      **口径要说清**：fork 测试沿用 `foundry.toml` 的 `evm_version`（cancun），
    ///      Foundry 不会套用 Sepolia 上的 EIP-8037。所以这里量到的是**本地计价下的基线**，
    ///      不是 Sepolia 的真实花费——后者要按 1,530 gas/字节换算（见 README 的两套天花板表）。
    ///      换句话说：这组数字能当回归基准，不能当部署预算
    function test_Fork_GasBaselineUnderLocalSchedule() public {
        StakingRewards pool = StakingRewards(PROXY);

        vm.prank(TOKEN_OWNER);
        MockERC20(STK).mint(user, 100e18);

        vm.startPrank(user);
        IERC20(STK).approve(PROXY, type(uint256).max);

        uint256 g0 = gasleft();
        pool.stake(10e18);
        uint256 stakeGas = g0 - gasleft();
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(user);
        uint256 g1 = gasleft();
        pool.getReward();
        uint256 claimGas = g1 - gasleft();

        console2.log("stake()     gas (local schedule):", stakeGas);
        console2.log("getReward() gas (local schedule):", claimGas);

        assertGt(stakeGas, 50_000, "suspiciously cheap: wrong schedule?");
        assertLt(stakeGas, 1_000_000, "suspiciously expensive: schedule regression?");
        assertGt(claimGas, 30_000);
        assertLt(claimGas, 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                  ④ 非标准代币：把「不支持」跑成证据
    //////////////////////////////////////////////////////////////*/

    /// @dev 池子的记账假设「转多少收到多少」。手续费代币打破这条假设后，
    ///      池子会记 100 而实际只有 99 —— 这不是 bug，是被声明过的限制。
    ///      把它写成用例，是为了将来有人接入这类代币时，有一条会红的线提醒他
    function test_Fork_FeeOnTransferTokenBreaksAccounting() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        StakingRewards impl = new StakingRewards();

        bytes memory initData =
            abi.encodeCall(StakingRewards.initialize, (feeToken, IERC20(RWD), 7 days, 0));
        StakingRewards pool = StakingRewards(address(new ERC1967Proxy(address(impl), initData)));

        feeToken.mint(user, 100e18);
        vm.startPrank(user);
        feeToken.approve(address(pool), type(uint256).max);
        pool.stake(100e18);
        vm.stopPrank();

        // 仓位记 100，池子实际只有 99：差额就是被烧掉的那 1%
        assertEq(pool.balanceOf(user), 100e18, "position recorded at face value");
        assertEq(feeToken.balanceOf(address(pool)), 99e18, "pool received less than recorded");

        // 于是「余额 == totalSupply」这条等式在手续费代币下必然不成立——
        // 这正是 README 要求「标准 ERC20」的原因，而不是一句风格建议
        assertLt(feeToken.balanceOf(address(pool)), pool.totalSupply(), "accounting should diverge here");
    }
}
