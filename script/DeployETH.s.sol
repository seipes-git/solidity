// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StakingRewardsETH} from "../src/StakingRewardsETH.sol";

/// @title 原生 ETH 质押池的部署脚本（Sepolia）
/// @notice 与 `Deploy.s.sol` 的 ERC20 池并列，部署的是**不可升级**的 ETH 池：
///         构造函数一次成型，没有代理、没有 initialize、没有 UPGRADER_ROLE。
///
/// @dev 为什么这个池不套代理：
///      ETH 池的资金路径是 `call{value}`，重入面比 ERC20 大。给它留一条「换逻辑」的通路，
///      等于把「升级权限能替换资金怎么算」这件事又放大一层。第一版刻意做成不可升级，
///      要改就重新部署、把仓位迁过去——这个代价换取的是「谁都不能悄悄改规则」。
///
///      幂等靠 `deployments/sepolia.eth.json`：清单里有地址且链上有代码就复用，
///      注资 / 开奖 / 种子质押各自看链上状态（余额、periodFinish、totalSupply），
///      重复跑不会产生第二个池子。
///
///      与 ERC20 池的三处流程差异：
///      ① 没有 implementation / proxy 两步，只有一笔创建交易
///      ② 种子质押用 `stake{value: 1}()`，不需要 approve
///      ③ 只有三个角色（admin / guardian / manager），没有 upgrader
contract DeployETH is Script {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 常量
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant ADMIN_ROLE = 0x00;
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    /// 与合约里的 `MAX_UNSTAKE_COOLDOWN` 一致
    uint256 internal constant MAX_UNSTAKE_COOLDOWN = 30 days;
    /// 种子质押。只为了把 totalSupply 从 0 抬起来，让第一期奖励有归属
    uint256 internal constant SEED_STAKE = 1;

    string internal constant RECORD = "./deployments/sepolia.eth.json";

    struct Cfg {
        address rewardToken;
        address admin;
        address guardian;
        address manager;
        uint256 duration;
        uint256 cooldown;
        uint256 fund;
    }

    /*//////////////////////////////////////////////////////////////
                                 主流程
    //////////////////////////////////////////////////////////////*/

    function run() external {
        address me = msg.sender;

        // 这一条不能省。`--account deployer` 只决定「谁签名广播」，不改变脚本里的 msg.sender：
        // 不加 `--sender` 时 msg.sender 是 Foundry 的默认地址 0x1804c8AB…。
        // 那样会出两个后果，而且都不会报错：
        //   ① 后面 renounceRole 撤的是默认地址（它本来就没角色），真部署者保留全部角色；
        //   ② _verify 里的 !hasRole(ROLE, me) 查的也是默认地址，于是「自检通过」。
        // 也就是脚本说成功、治理却留在部署者手上。所以这里必须硬拦。
        require(me != DEFAULT_SENDER, "pass --sender <your deployer address> (or the roles stay with the deployer)");

        // 允许再上一道保险：env 里的 DEPLOYER 与实参不一致就停。set-env.ps1 里那个就是真相源
        address declared = _addrOrZero("DEPLOYER");
        require(declared == address(0) || declared == me, "env DEPLOYER != the --sender address");

        require(block.chainid == SEPOLIA_CHAIN_ID, "this script is Sepolia-only");

        Cfg memory c = _readConfig();

        (address pool, bool fresh) = _resolveTarget();

        if (fresh) {
            _preflight(c, me);

            vm.startBroadcast();
            pool = address(new StakingRewardsETH(IERC20(c.rewardToken), c.duration, c.cooldown));
            vm.stopBroadcast();

            // 先落盘：后面任何一步 revert，下次重跑也不会再造一个池子
            _writeRecord(pool, c, me);

            console2.log("deployed ETH pool:", pool);
        } else {
            _assertReusable(pool, c);
            console2.log("reusing ETH pool:", pool);
        }

        _fundAndStart(pool, c, me);
        _handOverRoles(pool, c, me);
        _verify(pool, c, me);

        console2.log("");
        console2.log("=== ETH STAKING (the only address users should use) ===");
        console2.log(pool);
        console2.log("stake with: cast send <pool> \"stake()\" --value 0.01ether --account <you>");
    }

    /*//////////////////////////////////////////////////////////////
                               读配置
    //////////////////////////////////////////////////////////////*/

    /// @dev 缺失的变量一次列全，别让使用者「报一个、改一个、再报下一个」
    function _readConfig() internal view returns (Cfg memory c) {
        string[] memory missing = new string[](4);
        uint256 n;

        (c.rewardToken, missing, n) = _addrOrRecord("REWARD_TOKEN", missing, n);
        (c.admin, missing, n) = _addrOrRecord("ADDR_ADMIN", missing, n);
        (c.guardian, missing, n) = _addrOrRecord("ADDR_GUARDIAN", missing, n);
        (c.manager, missing, n) = _addrOrRecord("ADDR_MANAGER", missing, n);

        if (n > 0) {
            revert(string.concat("missing env (dot-source set-env.ps1 first):", _join(missing, n)));
        }

        c.duration = _uintOr("REWARDS_DURATION", 7 days);
        c.cooldown = _uintOr("UNSTAKE_COOLDOWN", 1 days);
        // ETH 池单独一份预算：两个池子各跑各的周期，共用一份钱会互相挤占
        c.fund = _uintOr("ETH_FUND_AMOUNT", c.duration * 1e18);
    }

    function _addrOrRecord(string memory name, string[] memory missing, uint256 n)
        internal
        view
        returns (address value, string[] memory, uint256)
    {
        value = _addrOrZero(name);
        if (value == address(0)) {
            missing[n] = name;
            ++n;
        }
        return (value, missing, n);
    }

    function _join(string[] memory names, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; ++i) {
            out = string.concat(out, " ", names[i]);
        }
    }

    /// 空字符串当作「没设置」：set-env.ps1 里未填的变量就是 `""`
    function _addrOrZero(string memory name) internal view returns (address) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return address(0);
        return vm.parseAddress(raw);
    }

    function _uintOr(string memory name, uint256 defaultValue) internal view returns (uint256) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return defaultValue;
        return vm.parseUint(raw);
    }

    /*//////////////////////////////////////////////////////////////
                            幂等：找已有部署
    //////////////////////////////////////////////////////////////*/

    function _resolveTarget() internal view returns (address pool, bool fresh) {
        if (!vm.exists(RECORD)) return (address(0), true);

        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(RECORD);
        if (!vm.keyExistsJson(json, ".pool")) return (address(0), true);

        pool = vm.parseJsonAddress(json, ".pool");

        // 清单有地址、链上没代码：上一轮是干跑或广播中断。必须当全新部署，
        // 否则后面每一步都在对着空地址调用
        if (pool.code.length == 0) {
            console2.log("record exists but pool has no code; deploying fresh");
            return (address(0), true);
        }

        return (pool, false);
    }

    /// @dev 复用已有池子时配置必须一致。ETH 池没有代理，改不了参数，
    ///      对不上就是「这不是同一个池子」，必须停
    function _assertReusable(address poolAddr, Cfg memory c) internal view {
        StakingRewardsETH pool = StakingRewardsETH(payable(poolAddr));

        require(address(pool.rewardToken()) == c.rewardToken, "env REWARD_TOKEN != recorded pool");
        require(pool.rewardsDuration() == c.duration, "env REWARDS_DURATION != recorded pool");
        require(pool.unstakeCooldown() == c.cooldown, "env UNSTAKE_COOLDOWN != recorded pool");
    }

    /*//////////////////////////////////////////////////////////////
                            广播前校验
    //////////////////////////////////////////////////////////////*/

    function _preflight(Cfg memory c, address me) internal view {
        require(c.rewardToken.code.length > 0, "REWARD_TOKEN has no code on this chain");

        require(c.duration != 0, "duration must be > 0");
        // 除不尽就会截断：604800 秒配 604801 枚，最后 1 枚永远发不出去
        require(c.fund % c.duration == 0, "ETH_FUND_AMOUNT must divide evenly by duration");
        require(c.fund / c.duration > 0, "reward per second is zero");
        require(c.cooldown <= MAX_UNSTAKE_COOLDOWN, "cooldown above the contract cap");

        // ETH 池只有三个角色。合并成一个地址等于没有分层——
        // GUARDIAN 的全部意义就是「和 MANAGER 不是同一个人」
        require(
            c.admin != c.guardian && c.admin != c.manager && c.guardian != c.manager,
            "the three role holders must be distinct addresses"
        );

        // 脚本最后会 renounce 部署者的全部角色，某个角色本来就填部署者会导致治理锁死
        require(
            c.admin != me && c.guardian != me && c.manager != me,
            "role holder must differ from the deployer (the script renounces the deployer's roles)"
        );

        // 种子质押要花自己的 ETH，1 wei 都没有就别往下走了
        require(me.balance >= SEED_STAKE, "deployer has no ETH to seed the pool");
    }

    /*//////////////////////////////////////////////////////////////
                        注资 / 开奖 / 种子质押
    //////////////////////////////////////////////////////////////*/

    function _fundAndStart(address poolAddr, Cfg memory c, address me) internal {
        StakingRewardsETH pool = StakingRewardsETH(payable(poolAddr));
        IERC20 reward = IERC20(c.rewardToken);

        uint256 held = reward.balanceOf(poolAddr);
        bool needNotify = pool.periodFinish() <= block.timestamp;
        // 周期还在跑时余额下降是正常的（用户领走了），这时补钱等于塞一笔没人认领的余量
        bool needFund = needNotify && held < c.fund;
        bool needSeed = pool.totalSupply() == 0;

        if (!needFund && !needNotify && !needSeed) {
            console2.log("fund / notify / seed stake: already done, skipped");
            return;
        }

        if (needFund) {
            uint256 gap = c.fund - held;
            uint256 wallet = reward.balanceOf(me);
            if (wallet < gap) {
                // 不自动 mint：脚本凭空造币会让人分不清「演示币」和「真钱」。
                // 明确告诉人该干什么，由人自己决定
                console2.log("deployer RWD balance:", wallet);
                console2.log("need at least       :", gap);
                console2.log("mint with:");
                console2.log("  cast send <REWARD_TOKEN> \"mint(address,uint256)\" <deployer> <amount> --account deployer");
                revert("deployer does not hold enough reward tokens");
            }
        }

        vm.startBroadcast();
        // 顺序不能改：先转钱，再 notify（后者校验余额覆盖整期），最后种子质押
        if (needFund) reward.safeTransfer(poolAddr, c.fund - held);
        if (needNotify) pool.notifyRewardAmount(c.fund);
        // 与 ERC20 池一样，1 wei 种子是为了让第一期有归属。ETH 池直接随调用送进去
        if (needSeed) pool.stake{value: SEED_STAKE}();
        vm.stopBroadcast();

        console2.log("funded      :", needFund);
        console2.log("notified    :", needNotify);
        console2.log("seed staked :", needSeed);

        if (needFund) {
            require(reward.balanceOf(poolAddr) >= c.fund, "funding did not land on the pool");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              角色移交
    //////////////////////////////////////////////////////////////*/

    /// @dev 「先给、再验、后弃」。反过来一旦 grant 失败，部署者已经没权限，谁都救不回来
    function _handOverRoles(address poolAddr, Cfg memory c, address me) internal {
        StakingRewardsETH pool = StakingRewardsETH(payable(poolAddr));

        bool done = pool.hasRole(ADMIN_ROLE, c.admin) && pool.hasRole(GUARDIAN_ROLE, c.guardian)
            && pool.hasRole(MANAGER_ROLE, c.manager) && !pool.hasRole(ADMIN_ROLE, me)
            && !pool.hasRole(GUARDIAN_ROLE, me) && !pool.hasRole(MANAGER_ROLE, me);

        if (done) {
            console2.log("roles: already handed over, skipped");
            return;
        }

        vm.startBroadcast();
        if (!pool.hasRole(ADMIN_ROLE, c.admin)) pool.grantRole(ADMIN_ROLE, c.admin);
        if (!pool.hasRole(GUARDIAN_ROLE, c.guardian)) pool.grantRole(GUARDIAN_ROLE, c.guardian);
        if (!pool.hasRole(MANAGER_ROLE, c.manager)) pool.grantRole(MANAGER_ROLE, c.manager);

        if (pool.hasRole(ADMIN_ROLE, me)) pool.renounceRole(ADMIN_ROLE, me);
        if (pool.hasRole(GUARDIAN_ROLE, me)) pool.renounceRole(GUARDIAN_ROLE, me);
        if (pool.hasRole(MANAGER_ROLE, me)) pool.renounceRole(MANAGER_ROLE, me);
        vm.stopBroadcast();

        console2.log("roles: granted to three wallets, deployer renounced all");
    }

    /*//////////////////////////////////////////////////////////////
                                自检
    //////////////////////////////////////////////////////////////*/

    /// @dev 这一段不接受假设：读回来是什么就是什么
    function _verify(address poolAddr, Cfg memory c, address me) internal view {
        StakingRewardsETH pool = StakingRewardsETH(payable(poolAddr));

        require(address(pool.rewardToken()) == c.rewardToken, "verify: reward token");
        require(pool.rewardsDuration() == c.duration, "verify: duration");
        require(pool.unstakeCooldown() == c.cooldown, "verify: cooldown");
        require(pool.rewardRate() > 0, "verify: reward rate is zero");
        require(pool.periodFinish() > block.timestamp, "verify: reward period not started");
        require(pool.totalSupply() >= SEED_STAKE, "verify: empty pool, the first period would be unrecoverable");

        // 本金必须全覆盖：合约余额 ≥ 在质押的 + 冷却中待退的。
        // 少一个 wei 都说明刚才某一步没落地上，用户 withdraw 时会拿不到钱
        require(
            poolAddr.balance >= pool.totalSupply() + pool.totalPending(),
            "verify: ETH balance does not cover principal"
        );

        require(pool.hasRole(ADMIN_ROLE, c.admin), "verify: admin");
        require(pool.hasRole(GUARDIAN_ROLE, c.guardian), "verify: guardian");
        require(pool.hasRole(MANAGER_ROLE, c.manager), "verify: manager");

        require(!pool.hasRole(ADMIN_ROLE, me), "verify: deployer still holds admin");
        require(!pool.hasRole(GUARDIAN_ROLE, me), "verify: deployer still holds guardian");
        require(!pool.hasRole(MANAGER_ROLE, me), "verify: deployer still holds manager");
    }

    /*//////////////////////////////////////////////////////////////
                              落盘
    //////////////////////////////////////////////////////////////*/

    function _writeRecord(address poolAddr, Cfg memory c, address me) internal {
        // 干跑不落盘，否则下次真跑会读到一份「已部署」的清单，而链上没有这个池子
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("dry run: record NOT written (add --broadcast to commit)");
            return;
        }

        vm.createDir("./deployments", true);

        string memory obj = "ethDeployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "rewardToken", c.rewardToken);
        vm.serializeAddress(obj, "admin", c.admin);
        vm.serializeAddress(obj, "guardian", c.guardian);
        vm.serializeAddress(obj, "manager", c.manager);
        vm.serializeAddress(obj, "deployer", me);
        vm.serializeUint(obj, "rewardsDuration", c.duration);
        vm.serializeUint(obj, "unstakeCooldown", c.cooldown);
        vm.serializeUint(obj, "fundAmount", c.fund);
        vm.serializeUint(obj, "seedStake", SEED_STAKE);
        vm.serializeUint(obj, "createdAtBlock", block.number);
        string memory json = vm.serializeAddress(obj, "pool", poolAddr);

        vm.writeJson(json, RECORD);
    }
}
