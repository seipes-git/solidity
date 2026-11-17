# V1 → V2 升级执行手册（Sepolia）

本文只做一件事：把已经跑起来的代理 `0xa10313F4…015D` 的逻辑，从 V1 换成 V2。
读完应该能独立执行一次，也知道哪一步出错意味着什么。

## 这次升级的性质

| 项目 | 结论 | 依据 |
|---|---|---|
| 状态变量 | **零新增**，17 个槽逐一相同（含 `claimPaused` 与 `uint256[34] __gap`） | `forge inspect … storageLayout` 逐行 diff 为空 |
| 迁移逻辑 | **不需要**，`upgradeToAndCall` 第二个参数传空 `0x` | 无新增变量，也没有需要初始化的新状态 |
| 代理地址 | **不变**，仍是 `0xa10313F4…015D` | 升级只改 EIP-1967 的 impl 槽 |
| 用户资产 | 不动。仓位、冷却、已计未领奖励全部留在原槽 | 槽位一致即安全 |
| 新增能力 | `version()` / `emergencyWithdraw()` / `totalOwedLive()` / `solvencyRatio()`，`recoverERC20` 改为「只取盈余」 | `src/StakingRewardsV2.sol` |

## 执行前必须先过的三关

```powershell
. .\set-env.ps1

# 1. 布局一致（无输出即通过；只比 slot/offset/名字/类型，跳过 Contract 列）
$l1 = forge inspect src/StakingRewards.sol:StakingRewards storageLayout --json | ConvertFrom-Json
$l2 = forge inspect src/StakingRewardsV2.sol:StakingRewardsV2 storageLayout --json | ConvertFrom-Json
Compare-Object ($l1.storage | ForEach-Object { "$($_.slot):$($_.offset) $($_.label) $($_.type)" }) `
               ($l2.storage | ForEach-Object { "$($_.slot):$($_.offset) $($_.label) $($_.type)" })

# 2. 这笔部署能不能塞进一笔交易（EIP-7825 上限 16,777,216）
cast estimate --rpc-url $env:SEPOLIA_RPC_URL --create `
  $(forge inspect src/StakingRewardsV2.sol:StakingRewardsV2 bytecode)
# 期望 ≈ 16,356,000，余量 2.5%

# 3. 升级签名者有没有 gas（UPGRADER 目前是 0）
cast balance 0x06aB17f11A98C536149193cCfCF7bC2B8511511B --rpc-url $env:SEPOLIA_RPC_URL --ether
```

三项里任何一项不满足，后面都会失败，且失败得很贵（第 2 项失败是整笔 revert 掉 gas）。

## 步骤 1：部署 V2 实现

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-v2.ps1
```

脚本里写死 `--gas-limit 16700000`，**不能用 `-g`**：`-g`（`--gas-estimate-multiplier`）是在节点估算值上乘一个百分比，
16.36M × 130% = 21M，直接越过 EIP-7825 的单笔上限，节点连打包都不会打包，直接拒收。
`forge create` 的 `--gas-limit` 就是这笔交易的 `gasLimit`，是绝对值，不参与倍数换算——所以这里只能用它。

记住输出里的 `Deployed to:`，下面称 `<NEW_IMPL>`。

## 步骤 2：验证实现源码

```powershell
forge verify-contract <NEW_IMPL> src/StakingRewardsV2.sol:StakingRewardsV2 `
  --chain sepolia --etherscan-api-key $env:ETHERSCAN_API_KEY
```

没有构造参数（`_disableInitializers()` 的 constructor 从 V1 继承，无入参），所以不要带 `--constructor-args`。
代币与代理不需要重新验证源码。

**但代理识别要重做一次**：升级换的是 EIP-1967 的 impl 槽，Etherscan 记录的 `Implementation`
不会自己跟着变。升级后它仍然指向旧实现，`Read as Proxy` 里就还是 V1 的 ABI——看不到 `version()`、
`emergencyWithdraw`。这一步在步骤 5 之后。本次实测过，确认不会自动刷新。

## 步骤 3：给 UPGRADER 打 gas

`0x06aB17f1…511B` 是升级权限的持有者，但它当前余额是 **0**，发不出交易。
`upgradeToAndCall` 约 3.5 万 gas，0.005 ETH 足够。

```powershell
# 从部署者打过去（会再要一次 keystore 密码）
cast send 0x06aB17f11A98C536149193cCfCF7bC2B8511511B `
  --value 0.005ether --account deployer --rpc-url $env:SEPOLIA_RPC_URL
```

也可以在 MetaMask 里直接转，效果一样。

## 步骤 4：发起升级

### 走浏览器（推荐，私钥不出钱包）

1. 打开 `0xa10313F4…015D` 的 **`Write as Proxy`** 标签（不是 `Write Contract`）
2. `Connect to Web3`，连上持有 `UPGRADER_ROLE` 的那个账户（`0x06aB…511B`）
3. 展开 `upgradeToAndCall`，填：
   - `newImplementation` = `<NEW_IMPL>`
   - `data` = 留空（不要填 `0x` 也不要填任何东西，空就是空 calldata）
4. `Write` → 确认

失败会带自定义错误：`AccessControlUnauthorizedAccount` 说明连错钱包；
`ERC1967InvalidImplementation` 说明地址填错或那个地址没有代码；
`UUPSUnauthorizedCallContext` 说明打到了实现合约而不是代理。

### 走命令行（需要先 `cast wallet import upgrader --interactive`）

```powershell
cast send 0xa10313F431f506028b7AB1b06be33556EA21015D `
  "upgradeToAndCall(address,bytes)" <NEW_IMPL> 0x `
  --account upgrader --rpc-url $env:SEPOLIA_RPC_URL
```

## 步骤 5：验收

升级前后各拍一次快照，逐项对比。**除 `implementation` 外，所有值必须一模一样。**

```powershell
$P = "0xa10313F431f506028b7AB1b06be33556EA21015D"
foreach ($s in "implementation()(address)","totalSupply()(uint256)","rewardRate()(uint256)",
               "periodFinish()(uint256)","lastUpdateTime()(uint256)",
               "rewardPerTokenStored()(uint256)","totalOwed()(uint256)",
               "claimPaused()(bool)","unstakeCooldown()(uint256)") {
  "$s = " + (cast call $P $s --rpc-url $env:SEPOLIA_RPC_URL)
}

# V2 才有的：升级前调用会 revert，升级后必须返回 2
cast call $P "version()(uint256)" --rpc-url $env:SEPOLIA_RPC_URL
cast call $P "totalOwedLive()(uint256)" --rpc-url $env:SEPOLIA_RPC_URL
cast call $P "solvencyRatio()(uint256)" --rpc-url $env:SEPOLIA_RPC_URL
```

本次升级前记录下来的基线（2026-11-17，升级动作之前）：

| 项 | 值 |
|---|---|
| `implementation` | `0xAa02E88c49097ac27fb77BAbF11F0df8E525d99D` |
| `totalSupply` | `100000000000000000001` |
| `rewardRate` | `1000000000000000000` |
| `periodFinish` | `1795486140` |
| `lastUpdateTime` | `1794882492` |
| `rewardPerTokenStored` | `1128000000000000000000000000000000000000` |
| `totalOwed` | `1128000000000000000000` |
| `claimPaused` | `false` |
| `unstakeCooldown` | `86400` |
| `balanceOf(部署者)` | `100000000000000000001` |

`totalOwed` 之所以已经到 1128 个代币，是因为部署时那 1 wei 的种子仓位吃下了
`notifyRewardAmount` 之后约 1152 秒的全部排放——1 wei 独占整池时，每秒 1 个全归它。
这是「用最小额种子激活 `totalSupply`」的已知副作用，不是 V1 的 bug；唯一的修法是部署后立刻清掉种子仓位。

## 步骤 6：刷新 Etherscan 的代理识别

不刷新的话，浏览器上 `Read as Proxy` 仍是 V1 的方法集，看不到 `version()`。

页面上点 `Contract` 标签下方的 `Is this a proxy?`，或调一次接口（只接受 POST）：

```bash
curl -X POST -d "address=0xa10313F431f506028b7AB1b06be33556EA21015D" \
  "https://api.etherscan.io/v2/api?chainid=11155111&module=contract&action=verifyproxycontract&apikey=$ETHERSCAN_API_KEY"
# 拿返回的 guid 查结果
curl "https://api.etherscan.io/v2/api?chainid=11155111&module=contract&action=checkproxyverification&guid=<guid>&apikey=$ETHERSCAN_API_KEY"
```

出现 `implementation contract is found at 0x1a81… and is successfully updated` 即完成。
`getsourcecode` 里 `Implementation` 应从 `0xaa02…` 变成 `0x1a81…`。

## 执行记录（2026-11-17 已完成）

| 项 | 值 |
|---|---|
| 新实现部署 | `0x1A81e04A8B01580b44d3e84fF49D0518D8B45437`，10,332 B，实耗 16,410,065 gas（上限 16,700,000） |
| 升级交易 | `0x97bc3dd2be31c94e0074b50e2d106e94e920e301f9ea79ef05ddde259d29b4e5` |
| 区块 / gas | `12153519` / `40,032`，`from = 0x06aB17f1…511B`，`status = 1` |
| 事件 | `Upgraded(0x1a81e04a8b01580b44d3e84ff49d0518d8b45437)`，1 条 log |
| 升级后 | `implementation()` = 新实现，`version()` = `2`，`totalOwedLive()` = 26,579.99e18，`solvencyRatio()` = 22.73e18 |
| 快照对比 | 9 项全部与升级前一致，零漂移 |

`deployments/sepolia.json` 里 `.implementation` 保留的是 **V1**（`Deploy.s.sol` 的预检要求
`proxy.implementation() == implementation`，改成 V2 会让那条断言失去意义）；
V2 与升级交易记在 `.implementationV2` / `.upgradeTx` / `.upgradeBlock`。

## 回滚

V2 出问题就把实现指回 V1：

```
upgradeToAndCall(0xAa02E88c49097ac27fb77BAbF11F0df8E525d99D, 0x)
```

槽位一致，所以回滚同样不需要迁移。**前提是旧实现地址没有被自毁**——UUPS 的实现合约没有自毁入口，
这个前提永远成立。

## 这次升级留下的技术债

V2 的 runtime 是 10,332 字节，Sepolia 上单笔已经只剩 2.5% 余量。
下次再往这个合约里加东西（哪怕只加一个函数），在 Sepolia 上就会撞 EIP-7825 而部署不动。
主网不受影响（code deposit 还是 200 gas/字节，约 2.3M），但测试网先死。
真到 V3，必须先瘦身：把 `recoverERC20` 的盈余计算抽成内部库、把观测接口拆到单独的 periphery 合约，
或者干脆改用「实现合约分片 + 多代理」的结构。
