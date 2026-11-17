// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

/// @title ERC20 质押池的部署脚本（Sepolia）
/// @notice 一次跑完六件事：部署实现 → 部署代理并初始化 → 注资 → 开奖 → 种子质押 → 角色移交，
///         最后逐项自检。**这个脚本可以重复跑**，第二遍不会部署第二个池子。
///
/// @dev 幂等的做法分两层：
///      ① 「只能发生一次」的动作（部署实现、部署代理）靠 `deployments/sepolia.json` 跳过；
///      ② 「可以重复但语义上不该重复」的动作（注资、notify、种子质押）靠链上状态判断——
///         余额不够才转、周期没开才 notify、`totalSupply == 0` 才质押 1 wei。
///
///      自愈：如果清单里有地址但代理上没代码（例如上一轮是干跑、或者广播中 revert 了），
///      脚本会把它当成全新部署，而不是盲目跳过。
///
///      为什么广播前要校验：广播是一串**独立交易**，中途 revert 不会撤销前面已经上链的交易。
///      所以能提前拦下的一律提前拦，别指望「失败了重来」——重来只会多一个半成品。
contract Deploy is Script {
    // 脚本也要守在「返回值」这一层：ERC20 的 transfer 返回 false 而不是 revert 时，
    // 裸调用会让脚本以为注资成功了
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 常量
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant ADMIN_ROLE = 0x00;
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    /// 与合约里的 `MAX_UNSTAKE_COOLDOWN` 一致
    uint256 internal constant MAX_UNSTAKE_COOLDOWN = 30 days;

    string internal constant RECORD = "./deployments/sepolia.json";

    struct Cfg {
        address stakeToken;
        address rewardToken;
        address admin;
        address guardian;
        address manager;
        address upgrader;
        uint256 duration;
        uint256 cooldown;
        uint256 fund;
    }

    /*//////////////////////////////////////////////////////////////
                                 主流程
    //////////////////////////////////////////////////////////////*/

    function run() external {
        // 广播期间 msg.sender 就是 --sender；先抓下来，后面所有断言都用同一个值
        address me = msg.sender;

        // 这个脚本只服务测试网。主网要重写：gas 参数、角色地址、是否需要时间锁都不一样
        require(block.chainid == SEPOLIA_CHAIN_ID, "this script is Sepolia-only");

        Cfg memory c = _readConfig();

        (address impl, address proxy, bool fresh) = _resolveTarget();

        if (fresh) {
            _preflightFresh(c, me);

            vm.startBroadcast();
            impl = address(new StakingRewards());
            proxy = address(
                new ERC1967Proxy(
                    impl,
                    abi.encodeCall(
                        StakingRewards.initialize,
                        (IERC20(c.stakeToken), IERC20(c.rewardToken), c.duration, c.cooldown)
                    )
                )
            );
            vm.stopBroadcast();

            // 立刻落盘：哪怕后面几步 revert，下次重跑也知道池子已经存在，不会再造一个
            _writeRecord(impl, proxy, c, me);

            console2.log("deployed impl :", impl);
            console2.log("deployed proxy:", proxy);
        } else {
            _assertReusable(impl, proxy, c);
            console2.log("reusing proxy :", proxy);
            console2.log("reusing impl  :", impl);
        }

        _fundAndStart(proxy, c, me);
        _handOverRoles(proxy, c, me);
        _verify(proxy, impl, c, me);

        console2.log("");
        console2.log("=== STAKING (the only address users should use) ===");
        console2.log(proxy);
    }

    /*//////////////////////////////////////////////////////////////
                               读配置
    //////////////////////////////////////////////////////////////*/

    /// @dev 缺失的变量一次列全。逐个 `envUint` 会「报一个、改一个、再报下一个」，
    ///      三次试错才凑齐，而且第一次的报错信息往往看不出还差谁
    function _readConfig() internal view returns (Cfg memory c) {
        string[] memory missing = new string[](6);
        uint256 n;

        (c.stakeToken, missing, n) = _addrOrRecord("STAKE_TOKEN", missing, n);
        (c.rewardToken, missing, n) = _addrOrRecord("REWARD_TOKEN", missing, n);
        (c.admin, missing, n) = _addrOrRecord("ADDR_ADMIN", missing, n);
        (c.guardian, missing, n) = _addrOrRecord("ADDR_GUARDIAN", missing, n);
        (c.manager, missing, n) = _addrOrRecord("ADDR_MANAGER", missing, n);
        (c.upgrader, missing, n) = _addrOrRecord("ADDR_UPGRADER", missing, n);

        if (n > 0) {
            string memory message = string.concat("missing env (dot-source set-env.ps1 first):", _join(missing, n));
            revert(message);
        }

        c.duration = _uintOr("REWARDS_DURATION", 7 days);
        c.cooldown = _uintOr("UNSTAKE_COOLDOWN", 1 days);
        c.fund = _uintOr("FUND_AMOUNT", c.duration * 1e18);
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

    /// 空字符串当作「没设置」：set-env.ps1 里未填的变量就是 `""`，
    /// 直接喂给 `envAddress` 会报解析错误，报错信息还看不出是哪个变量
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

    /// @return impl 实现合约地址（全新部署时为空）
    /// @return proxy 代理地址（全新部署时为空）
    /// @return fresh 是否需要部署
    function _resolveTarget() internal view returns (address impl, address proxy, bool fresh) {
        if (!vm.exists(RECORD)) return (address(0), address(0), true);

        // 读的是本脚本自己写的清单，不是任意路径
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(RECORD);
        if (!vm.keyExistsJson(json, ".proxy")) return (address(0), address(0), true);

        impl = vm.parseJsonAddress(json, ".implementation");
        proxy = vm.parseJsonAddress(json, ".proxy");

        // 清单写了但链上没有代码：上一轮是干跑，或者广播到一半断了。
        // 这时必须当成全新部署，否则后面每一步都会对着空气调用
        if (proxy.code.length == 0) {
            console2.log("record exists but proxy has no code; deploying fresh");
            return (address(0), address(0), true);
        }

        return (impl, proxy, false);
    }

    /// @dev 复用已有池子时，配置必须和链上一致。错了就停，不要「顺手改一下」——
    ///      把 A 池当成 B 池注资，钱进去就出不来了
    function _assertReusable(address impl, address proxy, Cfg memory c) internal view {
        require(impl.code.length > 0, "recorded implementation has no code");

        StakingRewards pool = StakingRewards(proxy);
        require(address(pool.implementation()) == impl, "proxy points to another implementation");
        require(address(pool.stakingToken()) == c.stakeToken, "env STAKE_TOKEN != recorded pool");
        require(address(pool.rewardToken()) == c.rewardToken, "env REWARD_TOKEN != recorded pool");
        require(pool.rewardsDuration() == c.duration, "env REWARDS_DURATION != recorded pool");
        require(pool.unstakeCooldown() == c.cooldown, "env UNSTAKE_COOLDOWN != recorded pool");
    }

    /*//////////////////////////////////////////////////////////////
                            广播前校验
    //////////////////////////////////////////////////////////////*/

    function _preflightFresh(Cfg memory c, address me) internal pure {
        require(c.duration != 0, "duration must be > 0");
        require(c.fund % c.duration == 0, "FUND_AMOUNT must divide evenly by duration, else rate truncates");
        require(c.fund / c.duration > 0, "reward per second is zero");
        require(c.cooldown <= MAX_UNSTAKE_COOLDOWN, "cooldown above the contract cap");

        // 四个角色地址必须互不相同：合并成一个地址等于没有分层，
        // 而 GUARDIAN 的意义恰恰是「和 MANAGER 不是同一个人」
        require(
            c.admin != c.guardian && c.admin != c.manager && c.admin != c.upgrader && c.guardian != c.manager
                && c.guardian != c.upgrader && c.manager != c.upgrader,
            "the four role holders must be distinct addresses"
        );

        // 脚本最后会 renounce 部署者的全部角色。如果某个角色本来就填的部署者自己，
        // 那一步会把该角色清空，治理直接锁死
        require(
            c.admin != me && c.guardian != me && c.manager != me && c.upgrader != me,
            "role holder must differ from the deployer (the script renounces the deployer's roles)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        注资 / 开奖 / 种子质押
    //////////////////////////////////////////////////////////////*/

    function _fundAndStart(address proxy, Cfg memory c, address me) internal {
        StakingRewards pool = StakingRewards(proxy);
        IERC20 reward = IERC20(c.rewardToken);

        uint256 held = reward.balanceOf(proxy);
        bool needNotify = pool.periodFinish() <= block.timestamp;
        // 注资只在「要开奖」时做：周期还在跑的时候余额下降是正常的（用户领走了奖励），
        // 这时补钱等于悄悄往池子里塞一笔没人认领的余量
        bool needFund = needNotify && held < c.fund;
        bool needSeed = pool.totalSupply() == 0;

        if (!needFund && !needNotify && !needSeed) {
            console2.log("fund / notify / seed stake: already done, skipped");
            return;
        }

        if (needFund) {
            uint256 gap = c.fund - held;
            uint256 wallet = reward.balanceOf(me);
            require(
                wallet >= gap,
                string.concat("deployer needs ", vm.toString(gap), " more reward tokens, wallet has ", vm.toString(wallet))
            );
        }

        vm.startBroadcast();
        // 顺序不能改：先转账，再 notify（后者会校验余额覆盖整期），最后种子质押
        if (needFund) reward.safeTransfer(proxy, c.fund - held);
        if (needNotify) pool.notifyRewardAmount(c.fund);
        if (needSeed) {
            // ERC20 池的 stake 走 transferFrom，所以要先 approve 1 wei
            IERC20(c.stakeToken).forceApprove(proxy, 1);
            pool.stake(1);
        }
        vm.stopBroadcast();

        console2.log("funded      :", needFund);
        console2.log("notified    :", needNotify);
        console2.log("seed staked :", needSeed);

        if (needFund) {
            require(reward.balanceOf(proxy) >= c.fund, "funding did not land on the proxy");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              角色移交
    //////////////////////////////////////////////////////////////*/

    /// @dev 顺序是「先给、再验、后弃」。反过来的话，一旦 grant 失败，
    ///      部署者已经没了权限，谁都救不回来
    function _handOverRoles(address proxy, Cfg memory c, address me) internal {
        StakingRewards pool = StakingRewards(proxy);

        bool done = pool.hasRole(ADMIN_ROLE, c.admin) && pool.hasRole(GUARDIAN_ROLE, c.guardian)
            && pool.hasRole(MANAGER_ROLE, c.manager) && pool.hasRole(UPGRADER_ROLE, c.upgrader)
            && !pool.hasRole(ADMIN_ROLE, me) && !pool.hasRole(GUARDIAN_ROLE, me)
            && !pool.hasRole(MANAGER_ROLE, me) && !pool.hasRole(UPGRADER_ROLE, me);

        if (done) {
            console2.log("roles: already handed over, skipped");
            return;
        }

        vm.startBroadcast();
        if (!pool.hasRole(ADMIN_ROLE, c.admin)) pool.grantRole(ADMIN_ROLE, c.admin);
        if (!pool.hasRole(GUARDIAN_ROLE, c.guardian)) pool.grantRole(GUARDIAN_ROLE, c.guardian);
        if (!pool.hasRole(MANAGER_ROLE, c.manager)) pool.grantRole(MANAGER_ROLE, c.manager);
        if (!pool.hasRole(UPGRADER_ROLE, c.upgrader)) pool.grantRole(UPGRADER_ROLE, c.upgrader);

        if (pool.hasRole(ADMIN_ROLE, me)) pool.renounceRole(ADMIN_ROLE, me);
        if (pool.hasRole(GUARDIAN_ROLE, me)) pool.renounceRole(GUARDIAN_ROLE, me);
        if (pool.hasRole(MANAGER_ROLE, me)) pool.renounceRole(MANAGER_ROLE, me);
        if (pool.hasRole(UPGRADER_ROLE, me)) pool.renounceRole(UPGRADER_ROLE, me);
        vm.stopBroadcast();

        console2.log("roles: granted to the four wallets, deployer renounced all");
    }

    /*//////////////////////////////////////////////////////////////
                                自检
    //////////////////////////////////////////////////////////////*/

    /// @dev 这是脚本里唯一「部署完了才算数」的一段。前面每一步都假设自己成了，
    ///      这一段不接受假设——读回来是什么就是什么
    function _verify(address proxy, address impl, Cfg memory c, address me) internal view {
        StakingRewards pool = StakingRewards(proxy);

        require(address(pool.implementation()) == impl, "verify: implementation pointer");
        require(address(pool.stakingToken()) == c.stakeToken, "verify: staking token");
        require(address(pool.rewardToken()) == c.rewardToken, "verify: reward token");
        require(pool.rewardsDuration() == c.duration, "verify: duration");
        require(pool.unstakeCooldown() == c.cooldown, "verify: cooldown");
        require(pool.rewardRate() > 0, "verify: reward rate is zero");
        require(pool.periodFinish() > block.timestamp, "verify: reward period not started");
        require(pool.totalSupply() >= 1, "verify: empty pool, the first period would be unrecoverable");

        require(pool.hasRole(ADMIN_ROLE, c.admin), "verify: admin");
        require(pool.hasRole(GUARDIAN_ROLE, c.guardian), "verify: guardian");
        require(pool.hasRole(MANAGER_ROLE, c.manager), "verify: manager");
        require(pool.hasRole(UPGRADER_ROLE, c.upgrader), "verify: upgrader");

        require(!pool.hasRole(ADMIN_ROLE, me), "verify: deployer still holds admin");
        require(!pool.hasRole(GUARDIAN_ROLE, me), "verify: deployer still holds guardian");
        require(!pool.hasRole(MANAGER_ROLE, me), "verify: deployer still holds manager");
        require(!pool.hasRole(UPGRADER_ROLE, me), "verify: deployer still holds upgrader");
    }

    /*//////////////////////////////////////////////////////////////
                              落盘
    //////////////////////////////////////////////////////////////*/

    function _writeRecord(address impl, address proxy, Cfg memory c, address me) internal {
        // 干跑（没有 --broadcast）不落盘：否则下次真跑会读到一份「已部署」的清单，
        // 而链上根本没有这个代理，后面每一步都在对着空气调用
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("dry run: record NOT written (add --broadcast to commit)");
            return;
        }

        vm.createDir("./deployments", true);

        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "implementation", impl);
        vm.serializeAddress(obj, "stakeToken", c.stakeToken);
        vm.serializeAddress(obj, "rewardToken", c.rewardToken);
        vm.serializeAddress(obj, "admin", c.admin);
        vm.serializeAddress(obj, "guardian", c.guardian);
        vm.serializeAddress(obj, "manager", c.manager);
        vm.serializeAddress(obj, "upgrader", c.upgrader);
        vm.serializeAddress(obj, "deployer", me);
        vm.serializeUint(obj, "rewardsDuration", c.duration);
        vm.serializeUint(obj, "unstakeCooldown", c.cooldown);
        vm.serializeUint(obj, "fundAmount", c.fund);
        // 最后一个 serialize 的返回值是完整 JSON
        string memory json = vm.serializeAddress(obj, "proxy", proxy);

        vm.writeJson(json, RECORD);
    }
}
