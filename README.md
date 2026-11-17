# StakingRewards

单池质押挖矿：用户质押 `stakingToken`，按每秒恒定速率瓜分 `rewardToken`（Synthetix 式）。

```text
src/StakingRewards.sol      ERC20 单池：质押 ERC20，奖励也是 ERC20。UUPS 可升级（V1）
src/StakingRewardsV2.sol    V1 的升级版：修 recoverERC20 边界、加 emergencyWithdraw 与观测接口
src/StakingRewardsETH.sol   ETH 单池：质押原生 ETH，奖励是 ERC20。不可升级，但已有 emergencyWithdraw
src/MockERC20.sol           测试用 ERC20，mint 权限归部署者（onlyOwner）

script/
├── DeployTokens.s.sol      测试网造两个代币并打额度（一次性，跑完写清单）
└── Deploy.s.sol            ERC20 池：部署 → 注资 → 开奖 → 种子质押 → 角色移交 → 自检
deployments/                部署清单（脚本写、脚本读，幂等的依据）

test/
├── StakingRewards/              V1：ERC20 池（UUPS 代理）
│   ├── StakingRewardsBase.sol   基座：代理 + initialize + 造币 + helper
│   ├── Staking.t.sol            本金流转：存入 / 解押 / 提取 / 退出
│   ├── Rewards.t.sol            奖励数学：线性累积、份额分配、周期边界、预算保护
│   ├── Cooldown.t.sol           解质押冷却：两阶段退出、解锁时间、上限
│   ├── Pause.t.sol              暂停语义：只冻入口不冻出口
│   ├── Access.t.sol             权限分层：四个角色各自的边界
│   ├── RoleHandover.t.sol       部署后的角色移交：正确顺序、软拆分、锁死警示
│   ├── Upgrade.t.sol            UUPS 升级通路：四类代理事故各一条用例
│   ├── Limits.t.sol             V1 做不到的三件事（与 V2 目录对照阅读）
│   ├── Invariants.t.sol         状态型不变量：handler + 三条等式/序关系（含改冷却的动作）
│   └── mocks/StakingRewardsV2Mock.sol   升级通路夹具（只加函数，不动存储布局）
├── StakingRewardsV2/            V2：只测「比 V1 多做了什么」
│   ├── StakingRewardsV2Base.sol 基座：V1 部署 + 真实升级到 V2
│   ├── Behaviour.t.sol          V2 新增能力：观测接口、盈余回收、紧急退出
│   └── Upgrade.t.sol            V1→V2 真实升级：20 项状态快照逐项比对
├── StakingRewardsETH/           ETH 池（constructor 版，未 UUPS 化）
│   ├── StakingRewardsETHBase.sol 基座：constructor 部署 + vm.deal + helper
│   ├── Staking.t.sol            质押、本金归属、totalPending、exit
│   ├── Cooldown.t.sol           冷却时序、构造函数参数校验
│   ├── Rewards.t.sol            奖励数学与周期参数
│   ├── Recover.t.sol            recoverETH 上限、三种钱分离、走 receive() 的真实误转
│   ├── Pause.t.sol              两级闸门
│   ├── Access.t.sol             权限分层
│   ├── Reentrancy.t.sol         重入面与收款方类型
│   ├── EmergencyWithdraw.t.sol  紧急退出：绕过冷却与两个闸门、会计不被当成余量
│   ├── RoleHandover.t.sol       角色移交：正确顺序、ADMIN 不可逆、治理锁死但资金可用
│   ├── Invariants.t.sol         状态型不变量：`余额 == 仓位 + 冷却本金` + 解锁时间序关系
│   └── mocks/Receivers.sol      重入 / 拒收 / 普通合约钱包
└── MockERC20/
    └── MockERC20.t.sol          铸币权限与基本转账语义

audit/FINDINGS.md               审计发现与修复状态（审计对话与编写对话共用）
```

> **部署脚本于 2026-11-12 重写**，当前只有 ERC20 池的测试网版本（`script/Deploy.s.sol`），
> ETH 池与 V2 升级的脚本尚未落地，所以下文「升级怎么做 / 链上演武 / 源码验证」里引用的
> `DeployETH.s.sol`、`UpgradeToV2.s.sol`、`DemoFlow.s.sol` 暂不可运行。
> 旧脚本备份在 `D:\web3\new_9.9\foundry\_archive_test_learn_scripts_20261112\`。
>
> **新脚本可以重复跑。** 它把已经做过的步骤读 `deployments/sepolia.json` 跳过，
> 把「该做还没做」的步骤补齐（例如上次注资成功但 notify 失败）。干跑（不加 `--broadcast`）
> 不会写清单，所以试跑一百次也不会让链上多出一个池子。

## 测试结构：一个合约一个目录

`test/` 下的目录名就是被测算的合约名，目录内再按**关注点**分文件。这样做的理由有两条：

1. **看目录就知道缺什么**。`StakingRewardsETH/` 里没有 `Upgrade.t.sol`，一眼能看出这个池还没 UUPS 化；
   `StakingRewards/Limits.t.sol` 和 `V2/Behaviour.t.sol` 摆在一起，就是「缺口 → 修复」的对照。
2. **跑子集不用记文件名**。改奖励数学时只跑 `Rewards.t.sol`，不用在十几个文件里挑。

三个目录的基座是同一套思路，且**只继承不复用代码副本**：

```text
StakingRewardsBase        （代理 + initialize + 造币 + approve + helper）
├── StakingRewardsV2Base  （+ 部署 V2 实现、把代理指过去）
└── 各测试合约

StakingRewardsETHBase     （constructor 部署 + vm.deal + helper，与上面平行，不继承）
└── 各测试合约
```

V2 的基座继承 V1 的基座，是因为 V2 就是 V1 的升级——测试环境也照着这条路径搭，而不是直接
`new StakingRewardsV2()`：那样部署出来的实例既没有角色也没有状态，测的东西与线上无关。

```powershell
forge test --match-path "test/StakingRewards/*"        # V1
forge test --match-path "test/StakingRewardsV2/*"      # V2（含真实升级）
forge test --match-path "test/StakingRewardsETH/*"     # ETH 池
forge test --match-path "test/MockERC20/*"             # 测试代币
forge test --match-contract ETHRecoverTest -vvv        # 单个关注点 + 完整调用轨迹
```

命名约定：测试合约名 = `<合约简称><关注点>Test`。`StakingTest` 属于 ERC20 池，
ETH 池一律带前缀（`ETHStakingTest`、`ETHPauseTest`），否则 `--match-contract` 会撞名。

### 两类测试，分工不同

| 类型 | 写法 | 能回答的问题 | 不能回答的问题 |
|---|---|---|---|
| 单点用例 | `test_*` | 某条路径下这个数是几 | 多步操作组合起来还成立吗 |
| 无状态 fuzz | `testFuzz_*` | 参数取遍一个区间还成立吗 | 同上（每次从同一个 `setUp` 出发） |
| **状态型不变量** | `invariant_*` + handler | fuzzer 自己拼序列（存 → 部分退 → 跳时间 → 领奖 → 再存）后还成立吗 | 具体的数值 |

`Invariants.t.sol` 里的 handler 只调合约的公开函数，不直接 `vm.deal`、不直接 `transfer`——
handler 一旦自己动了余额，等式类不变量就会被它自己打破，红出来的全是噪音。
轮数与深度在 `foundry.toml` 的 `[invariant]` 里（`runs = 256`、`depth = 32`），
跑法：

```powershell
forge test --match-path "test/StakingRewards/Invariants.t.sol" -vv   # 会打印每个 handler 函数被调用了多少次
```

那份调用统计表是判断「不变量有没有真的被行使」的依据之一：如果某个函数一次都没被调用，
对应的路径就没被覆盖到。

有一条不变量比的是 handler 自己记的**影子账本**（`expectedUnlock`），不是合约状态：
「解锁时间不早于历次请求里最晚的那次」这句话的参照物是操作历史，而历史只有 handler 知道。
影子只由 handler 亲眼看过的输入（当时的时间 + 当时的冷却）推导，**不读合约的 `unlockTime`**，
否则两边同源，断言就成了自证。配套的两条 `test_CooldownChangeReachesContractAndShadowTracks`
用来证明影子不是恒为 0——否则那条不变量会在空账本上平凡成立。

## 可升级（UUPS）

`StakingRewards` 现在是 UUPS 代理模式：用户交互的是一个 163 字节的代理合约，
逻辑在实现合约里，代理通过 `delegatecall` 执行它。**换实现只换代码，数据一直留在代理地址的存储里。**

### 改了四个地方，每一处都是必须的

| 原来 | 现在 | 不改会怎样 |
|---|---|---|
| `constructor` 里赋值 | `initialize()` + `initializer` 修饰器 | 构造函数只在部署实现合约时跑，代理的存储永远是空的 |
| `IERC20 public immutable stakingToken` | 普通 storage 变量 | `immutable` 烤进 runtime 字节码，代理读到的还是实现合约里的那份，且所有克隆共享 |
| `AccessControl` / `Pausable` | `AccessControlUpgradeable` / `PausableUpgradeable` | 这两个基类用顺序 slot（`_roles` 在 slot 0、`_paused` 在下一个），会和业务变量抢位置。它们已改成 ERC-7201 命名空间存储 |
| 升级入口不存在 | `_authorizeUpgrade` + `UPGRADER_ROLE` | 不写访问控制，**任何人都能把实现换成转走资金的合约**。OZ 把它设成 abstract，不写就编译不过 |

`Initializable`、`UUPSUpgradeable`、`ReentrancyGuard` 在 OZ 5.7 里已经是命名空间存储，直接用主包即可，不需要 Upgradeable 版。

### 升级权是第四个角色，刻意和另外三个分开

升级能替换**全部逻辑**，包括「你的钱怎么算」。所以它既不属于 `REWARDS_MANAGER_ROLE`（改参数），也不属于 `GUARDIAN_ROLE`（拉闸门）：

```solidity
function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
```

测试 `test/StakingRewards/Upgrade.t.sol` 里专门有一条 `test_ManagerAndGuardianCannotUpgrade` 钉住这个边界。

**但要说清一个 AccessControl 的固有性质**：`UPGRADER_ROLE` 的管理员是 `DEFAULT_ADMIN_ROLE`，
所以持有 ADMIN 的人可以把自己加成 UPGRADER，等于隐式拥有升级权。
要做到彻底分离，需要在 `initialize` 里再 `_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)`，
代价是 UPGRADER 一旦全部丢失就永久锁死升级。现在的版本选了「简单、可恢复」，并在合约注释里写明。

### 存储布局是唯一不能违反的规则

V1 的状态变量顺序就是布局。**V2 只能在这 16 个槽之后追加**，删除、重排、改类型都会让已存数据错位，
而且**编译器不会报错**——它只会读到一堆看起来合法、实际是垃圾的数字。

合约末尾留了 `uint256[34] private __gap;`（16 + 34 = 50）。V2 加变量时从 gap 里取，并把 gap 长度减掉相应数量。
升级前务必对比两份布局，逐个槽位核对：

```powershell
forge inspect src/StakingRewards.sol:StakingRewards storageLayout
forge inspect src/StakingRewardsV2.sol:StakingRewardsV2 storageLayout
```

### 升级怎么做

```powershell
# 1. 部署新实现（它同样是 _disableInitializers 锁死的，不能直接用）
forge create src/StakingRewardsV2.sol:StakingRewardsV2 --rpc-url sepolia --account deployer

# 2. 让代理指向它。data 为空 = 不在升级时顺手调别的函数
cast send $env:STAKING "upgradeToAndCall(address,bytes)" $env:NEW_IMPL 0x --rpc-url sepolia --account deployer

# 3. 回读确认
cast call $env:STAKING "implementation()(address)" --rpc-url sepolia   # 应为新实现地址
```

`upgradeToAndCall` 的第二个参数是「升级后立刻调用哪个函数」，用来做「初始化 V2 新增状态的迁移」。
传 `0x` 表示不调。**如果 V2 需要迁移数据，这一步必须和升级原子完成**，否则中间态会被别人利用。

## V2 做了什么

V2 只修 V1 上线后的两个运营缺口，**没有新增任何状态变量**——V1 的 16 个槽和 `__gap` 一个字节都没动，所以升级不需要迁移。

### ① `recoverERC20` 对 rewardToken 从「一律禁止」改成「只能取真正多余的部分」

V1 里 rewardToken 是死禁令，后果是注资过量就永远取不回来：按 7 天算好的 `FUND_AMOUNT` 只跑了 3 天、或者连续两期注入第二期没开始，那笔钱就锁在合约里。

V2 的判据是：

```
可动额度 = 余额 − 已欠 − 已许诺未释放
         = balance − totalOwed − rewardRate × (periodFinish − now)
```

**第二项是关键。** 我第一版写的是 `balance − totalOwed`，测试直接抓到了洞：注资 604800 覆盖 7 天，跑到第 2 天时 `totalOwed` 只有 172800，按那个公式管理员能取走 432000——**那是后面 5 天要发的钱**。取走之后周期不会停，到第 7 天用户 `getReward` 就是 `safeTransfer` 失败。

`notifyRewardAmount` 里的 `available` 不扣这一项是对的（它要拿剩余预算来合并新一期），而 `recover` 是往外拿钱，必须把未来要发的锁住。两个「available」不是同一个东西。

### ② 新增 `emergencyWithdraw()`：放弃奖励，立即取回本金

V1 的 `unstakeCooldown` 是自己给用户加的一道锁——发起解押后 24 小时内一分钱拿不回来，哪怕他愿意放弃奖励。这和「管理员的开关伸不到用户本金」那条原则有张力。

三个语义点：

- **不受 `paused` / `claimPaused` 影响**，它退的是本金
- **无视 `unlockTime`**，这是它和 `withdraw` 的唯一区别
- **放弃的奖励从 `totalOwed` 销账**，于是这笔钱从「名花有主」变成「可用盈余」，可由 `recoverERC20` 取回

第三条形成闭环：用户不要的奖励不会变成无主差额卡在合约里，而是回到项目方手上。

### ③ 三个观测接口

| 函数 | 作用 |
|---|---|
| `version()` | 返回 2。V1 没有这个函数，所以升级前调用必然 revert——这本身就是「还没升」的判据 |
| `totalOwedLive()` | 实时负债 = `totalOwed` + 未结算应计。V1 的 `totalOwed` 是惰性的，外部拿它算偿付率会偏低 |
| `solvencyRatio()` | 余额 / 实时负债，1e18 精度。**负债为 0 时返回 `type(uint256).max`**，前端必须和「偿付率为零」分开处理 |

### 刻意没做的三件事

| 没做 | 原因 |
|---|---|
| `totalPending()` | 需要一个全局计数器 → 必须 override `requestUnstake` / `withdraw` / `emergencyWithdraw` 三个函数去维护。override 已有函数是升级里最容易出逻辑分叉的动作，为一个展示字段不值得 |
| `pendingUnstake` 改成数组 | 能根治 A-28（已到期额度被新请求推后），但要新增动态数组 + 升级时迁移。迁移写错的后果是用户本金丢失，应当单独做一次升级专门测迁移 |
| 多奖励币 | `notifyRewardAmount` / `getReward` / `totalOwed` 全部重写，存储布局大改，与单池定位也矛盾 |

### 升级怎么做

**目前没有链上升级脚本。** `script/` 下只剩部署用的 `Deploy.s.sol` 与 `DeployTokens.s.sol`，
旧版的 `UpgradeToV2.s.sol` 已于 2026-11-12 随全部旧脚本移除（备份在
`../_archive_test_learn_scripts_20261112/`）。

升级本身的验证没有丢，它搬进了测试：`test/StakingRewardsV2/Upgrade.t.sol` 走一次真实升级，
前后拍 **20 项状态快照**逐项比对（`rewardRate`、`periodFinish`、`rewardPerTokenStored`、
`totalSupply`、`totalOwed`、两个代币地址、两个闸门状态、四个角色、冷却中的本金金额与解锁时刻…），
少一项就少一个「数据没丢」的证据。**每次改代码都会重跑，比跑一次的脚本更可靠。**

要真的在链上升一次，得先写一个新脚本，最小步骤是：读实现地址 → 拍同一组快照 → `upgradeToAndCall` → 逐项 `require` 不变。

### 部署预算：两套天花板，别混着用

代码体积的上限取决于**在哪条链上部署**，因为存代码的单价不同：

| 场景 | 单笔限制来自 | 存代码单价 | 部署 V2 需要的 gas | 还能加多少字节 |
|---|---|---|---|---|
| Ethereum 主网**现在** | EIP-170，runtime ≤ 24,576 B | 200 / 字节 | 约 2.32 M | **14,244 B** |
| **Sepolia 现在** | EIP-7825，单笔 ≤ 16,777,216 | **1,530 / 字节**（EIP-8037 预演） | **约 16.32 M** | **约 297 B** |
| 主网**若** 8037 落地 | 同上 16,777,216 | 1,530 / 字节 | 约 16.32 M | 约 297 B |

| 版本 | runtime（`forge build --sizes`） | 主网部署 | Sepolia 部署 | Sepolia 余量 |
|---|---|---|---|---|
| V1 | 9,329 B | 2,119,214 | 约 14,787,000 | 199 万（11.9%） |
| V2 | **10,332 B** | 约 2,319,800 | **约 16,322,000** | **45.5 万（2.7%）** |
| ETH 池 | 7,421 B | 1,831,372 | 约 12,480,000 | 430 万（25.6%） |

> **Sepolia 那列怎么来的**：锚点是 2026-11-11 的一次真实部署回执（`tx 0xa8c63db2…`，
> runtime 6,325 B，`gasUsed 10,885,170`），拆开是 `6,325 × 1,530 = 9,677,250`（存代码）
> 加约 1.21 M 构造开销（旧版在构造函数里 `grantRole` 四次，写约 12 个槽 × 97,920）。
> 若按 200 / 字节算，那笔整笔只会有约 1.5 M —— 所以这条回执本身就是 8037 在 Sepolia 生效的证据。
> 其余版本按 runtime 线性折算，误差在百位。
>
> **主网那列**是 `forge test --gas-report` 的实测 Deployment Cost（200 / 字节计价）。
> 同一份代码两条链差 7 倍，不是谁算错了，是计价规则不同。

两点必须记住：

1. **在 Sepolia 部署，gasLimit 要给到 16.35 M 以上**：V1 用 `-g 750`（15.89 M）够，
   **V2 不够**，得走 `forge create --gas-limit 16777216` 或 `-g 780`。
   **在主网部署不需要**，2.32 M 随便哪个默认估算都够
2. **「V3 之前必须先瘦身」只在 8037 生效的环境成立。** 主网现在还剩 14.2 KB（EIP-170 的 24,576 B），
   不需要为体积做任何妥协；只有当 8037 真的上了主网，单笔 runtime 天花板才变成约 10,629 B，
   V2 从 10,332 B 只剩约 297 B。届时再拆 view、降 `optimizer_runs` 才划算



## 两个池：ETH 与 ERC20 分开

`StakingRewards` 收 ERC20，`StakingRewardsETH` 收原生 ETH。**为什么不合成一个池支持双资产**：

1. ERC20 池已经上链运行、有真实仓位。改它的资金路径等于让已部署的代码失效
2. 单资产池只回答一个问题：「这个资产怎么分奖励」。混在一起，每个函数都要多一个分支
3. ETH 转账会触发接收者代码，重入面比 ERC20 大，独立出来才能针对性地守

两者共享同一套奖励数学、角色分层、两级闸门、解押冷却。实质差异只有三处：

| | ERC20 池 | ETH 池 |
|---|---|---|
| 存入 | `stake(amount)`，先 `approve` | `stake()` **payable**，金额就是 `msg.value` |
| 转出 | `safeTransfer` | `call{value}` |
| 救援 | `recoverERC20` 直接禁止动 `stakingToken` | `recoverETH` 只能取「余额 − 欠用户的本金」 |

`emergencyWithdraw()` 两个池都有（放弃全部未领奖励，立即取回本金，绕过冷却与两个闸门）。
**ETH 版多一笔账要减**：`totalPending` 必须同步下降，否则
`recoverETH` 的上限（`balance − totalSupply − totalPending`）会把刚退回去的本金当成余量，
管理员一次 `recoverETH` 就能把它取走。这是 ETH 池唯一需要额外小心的地方，
`test_ReturnsBothStakedAndPendingPrincipal` 直接盯这一点。

另外 ETH 池**不可升级**，所以这个出口只能在部署前决定要不要；上线后再想加，只能重新部署并迁移资金。

### ETH 池特有的一个状态变量：`totalPending`

ERC20 版可以简单地「禁止取回 stakingToken」。ETH 版没有这个开关——本金就是 ETH，和误转的 ETH 混在同一个余额里。

所以必须有算术上的边界：

```
可被管理员取走的余量 = address(this).balance − totalSupply − totalPending
```

`totalPending` 记录「已发起解押、还在冷却期」的本金总额。**没有它，`recoverETH` 就能把用户还没取回的冷资本金直接拿走**——那不是救援，是挪用。三笔测试专门钉这条：

```
test_RecoverETHTakesOnlySurplus            只取误转的那部分
test_RecoverETHCannotTouchCoolingPrincipal 冷却中的本金一分不能动
test_RecoverETHSeparatesAllThreePots       计息本金 / 冷却本金 / 误转，三者分开
```

### push 模式必须接受的代价

转出用 `call{value}` 而不是 `transfer`：`transfer` 只给 2300 gas，多签钱包和智能合约钱包会在 `receive` 里失败。代价是**接收方必须能收 ETH**——如果它在 `receive` 里 revert，本金就取不出来。这是 push 模式的固有限制，测试里如实记录（`test_RejectingReceiverBlocksWithdraw`）。

真正要彻底消除这个风险，只能改成 pull 模式（用户自己 `claim`，合约不主动转账），代价是多一次交互。

### 部署

```powershell
forge script script/DeployETH.s.sol --rpc-url sepolia --sender $env:DEPLOYER --gas-estimate-multiplier 800 --slow --broadcast
```

**倍数要按链算**：runtime 7,421 字节、主网约 **1,831,372 gas**；Sepolia 按 1,530/字节折算约 **1,248 万**。
本地估算 × 倍数必须落在 16,777,216 以内：`-g 800`（1,465 万）够用，`-g 1000` 会越过上限被拒。

## 链上实例

> **下面这个实例已作废（2026-11-12）。** 它是 `constructor` + `immutable` 的不可升级版本，
> 部署时 UUPS 改造还没做。它的角色、存储、接口都与当前代码不同，不要与新代码混用。
> 当前版本需要重新部署，跑完把**代理地址**填到本节。

| 合约 | 地址 | 状态 |
|---|---|---|
| `StakingRewards`（旧，不可升级） | `0xB39a4222BCc65656FDFCF7d14622a7cE42F4e681` | 作废 |
| `pSTK`（MockERC20） | `0x354C959d4e6Ad44eDA2cE68285ADC3C197e8F8Bf` | **作废**（见下） |
| `pRWD`（MockERC20） | `0x416a8c972630e5b6A74f348f851881B24072d90A` | **作废**（见下） |

**这两个 Mock 代币在 2026-11-17 一并作废，新部署不再复用**，原因有两条：

1. **它们的 `mint` 是公开的**——连 `owner()` 都不存在，任何人都能凭空铸 pSTK 再质押进来分走整期奖励。
   当前 `MockERC20` 已经改成 `ERC20 + Ownable`，`mint` 只有部署者能调，用新币才守得住这条。
2. `pRWD` 只剩 395,200 枚，不够一期 604,800，补铸也只能治标。

新部署请走：`DeployTokens.s.sol` 造两个新币 → 把打印的两个地址填进 `set-env.ps1` → `Deploy.s.sol` 部署。

旧实例的部署参数：`rewardsDuration = 604800`、`unstakeCooldown = 86400`、`FUND_AMOUNT = 604800e18`、
种子质押 1 wei，创建交易实耗 10,885,170 gas。可升级版更大，实测见下。

## 角色与权限

合约不用 `Ownable`，改成四个角色。拆开的理由是**紧急响应的权限应该小于日常运营的权限**：

| 角色 | 能做什么 | 不能做什么 |
|---|---|---|
| `REWARDS_MANAGER_ROLE` | `notifyRewardAmount`、`setRewardsDuration`、`setMinStakeAmount` | 改冷却、回收代币、暂停、分配角色、升级 |
| `GUARDIAN_ROLE` | `pause` / `pauseClaim` 两个闸门 | 改任何参数。紧急响应的第一反应者不必握有改写奖励曲线的权力 |
| `DEFAULT_ADMIN_ROLE` | `setUnstakeCooldown`、`recoverERC20`、分配角色 | 直接调不了 `upgradeToAndCall`（但能把人加成 UPGRADER） |
| `UPGRADER_ROLE` | `upgradeToAndCall`，替换实现合约 | 改不了任何业务参数 |

`initialize` 把四个角色都给初始化者，方便起步。生产环境应当在部署后立刻拆开：`GUARDIAN_ROLE` 交给独立的监控地址，
`UPGRADER_ROLE` 交给时间锁或多签，`DEFAULT_ADMIN_ROLE` 移交多签。

#### `DEFAULT_ADMIN_ROLE` 等价于超级权限，不是日常治理权

`AccessControl` 里 `UPGRADER_ROLE` 的管理员就是 `DEFAULT_ADMIN_ROLE`，所以被攻破的 ADMIN 只需要两步：

```solidity
staking.grantRole(UPGRADER_ROLE, attacker);        // 先把自己加成升级者
staking.upgradeToAndCall(maliciousImpl, "");       // 换掉实现，转走全部本金
```

**结论：给 UPGRADER 上的时间锁/多签，在实际攻击面上不起作用**——攻击者不走那条门。
`test_ManagerAndGuardianCannotUpgrade` 钉住的是 MANAGER / GUARDIAN 这一层，管不到 ADMIN。

三种处理方式，上主网前必须选一个：

| 做法 | 效果 | 代价 |
|---|---|---|
| **ADMIN 与 UPGRADER 放进同一个多签 / 时间锁** | 攻击者要突破同一道门，时间锁才真正生效 | 需要多签，测试网做不了 |
| `_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)` | ADMIN 无法自提 UPGRADER，两权真正分离 | UPGRADER 全丢 = 升级永久锁死，不可恢复 |
| 保持现状 | 起步最快，四个 EOA 分开持有 | **ADMIN 即超级权限**，必须按这个前提做威胁建模 |

测试网当前用第三种：`set-env.ps1` 把四个角色分给四个地址，读起来像分离的，
**但那只是热钱包暴露面不同，不是权限隔离**。上线主网前换第一种。

### 部署后移交角色

`Deploy.s.sol` 里已经内置这一步，填两个可选变量即可（不填就跳过并打印 `[warn]`）：

```powershell
$env:GUARDIAN_ADDRESS = "0x监控地址"
$env:ADMIN_MULTISIG = "0x多签地址"
```

脚本执行的是 **grant → 验证 → renounce**：

```solidity
staking.grantRole(GUARDIAN_ROLE_ID, guardianAddr);
require(staking.hasRole(GUARDIAN_ROLE_ID, guardianAddr));   // 确认写进去了
staking.renounceRole(GUARDIAN_ROLE_ID, deployer);           // 才放弃自己的
```

**顺序不能颠倒。** `renounceRole` 只能自己放弃、且不可恢复。先放弃再授予的写法在第二步就会 revert，如果当时没人持有 `DEFAULT_ADMIN_ROLE`，协议永久失去管理能力——合约不可升级，没有任何补救手段。

三个注意事项：

1. **只拆守卫是「软拆分」。** 只要还握着 `DEFAULT_ADMIN_ROLE`，部署者随时能把自己加回 `GUARDIAN_ROLE`。降低的是热钱包暴露面，不是权限转移。真正的转移要连 ADMIN 一起交给多签。
2. **链上验证不了「对方有私钥」。** `hasRole` 只证明记录写对了，证明不了地址背后有人。地址填错一个字符就永久锁死，广播前必须人工核对两遍——这是自动化替代不了的一步。
3. **治理锁死不等于资金锁死。** `test_RenouncingAdminWithoutSuccessorLocksGovernanceForever` 验证了这件事：管理员全部消失后，用户的 `requestUnstake` / `withdraw` / `getReward` 照常工作，因为所有角色检查都只挂在管理函数上，提款路径从不检查角色。

## Gas：做了什么、故意没做什么

按「存储 → 计算 → 函数 → 类型」过了一遍，结论是**大部分条目要么不适用、要么与安全/兼容冲突**，
真正的欠账只有一处，已经补上。

### 用了的

| 手段 | 位置 | 效果 |
|---|---|---|
| 自定义 error 代替 `require("…")` | 全部 13 个错误 | 每条省 50–100 gas，还省 30–50 字节 |
| `constant` / `immutable` | `PRECISION`、三个角色 hash、`MAX_UNSTAKE_COOLDOWN`；ETH 池的 `rewardToken` | 读常量 3 gas，对比 SLOAD 2,100 |
| 一次读齐 storage、算式内联 | `_updateReward` | 见下表 |
| 算式只留一份 | `_rewardOf` 同时服务 `earned()` 与 `_updateReward` | 省掉一份乘除的字节码（90 B） |
| 清零换退款 | `withdraw` / `emergencyWithdraw` 里的 `delete pendingUnstake` | 释放槽位可拿回部分 gas |
| 延迟结算 | `rewardPerTokenStored` + `userRewardPerTokenPaid` | 把 O(n) 遍历用户变成 O(1) |
| 事件只留必要 `indexed` | 每个事件最多 1 个 topic 参数 | 避免 topic 溢出到 data 反而更贵 |

### 补上的那一处

`_updateReward` 原写法调 `rewardPerToken()` 取 rpt，又在 `earned()` 里第二次调它，
`rewardPerTokenStored` / `totalSupply` / `lastUpdateTime` / `periodFinish` 因此各被多读一遍；
`getReward` 还要回读一次刚写过的 `rewards[msg.sender]`。

改法：`supply` / `lastTime` / `stored` 提到局部变量，曲线算式内联，`_updateReward` 返回本次应发奖励
供 `getReward` 直接用。逻辑逐字等价——空池时 `supply == 0` 直接取 stored，`lastUpdateTime` 照样推进。

| 操作（avg） | 改前 | 改后 | 省 |
|---|---|---|---|
| `stake` | 103,354 | 102,815 | −539 |
| `getReward` | 149,754 | 148,017 | −1,737 |
| `requestUnstake` | 42,545 | 40,979 | −1,566 |
| `withdraw` | 34,450 | 33,440 | −1,010 |
| `exit` | 122,809 | 120,617 | −2,192 |
| ETH 池 `getReward` | 135,064 | 133,659 | −1,405 |
| ETH 池 `exit` | 157,372 | 155,461 | −1,911 |

代价：runtime **+81 B**（V1）/ **+83 B**（V2）/ **+85 B**（ETH），部署约 +1.2 万 gas（本地）、
+12.7 万（Sepolia 按 1,530 gas/字节）。按一笔 `getReward` 省 1,737 算，**主网十几笔就回本**。

### 故意没做的

| 条目 | 为什么不做 |
|---|---|
| `unchecked`（0 处） | `totalOwed -= reward`、`balanceOf[x] -= amount` 的下溢检查**就是安全边界**。不变量测试抓到过 `Σ rewards` 可能比 `totalOwed` 多 1 wei，靠的正是这道检查会 revert 而不是静默回绕 |
| 存储重排打包 | `claimPaused`(bool) 独占一槽确实浪费 20,000 gas，但布局被 UUPS 兼容性锁定，重排等于让已部署实例和 V2 全部失效 |
| 循环优化（缓存 length、`++i`） | 合约里 `for` / `while` 共 0 处——奖励靠累计量分摊，不遍历用户 |
| `bytes32` 代替 `string` | 没有 `string` 状态变量 |
| `calldata` 代替 `memory` | 没有动态数组或结构体参数 |
| V1 的 `stakingToken` / `rewardToken` 改 `immutable` | 它们走代理存储、在 initialize 时才写入，物理上做不到 |

一句话：这份合约的 gas 特征由「O(1) 结算 + 两级闸门 + UUPS」这几个设计决定，微优化空间只有百分之几；
要再降一个量级得换架构（pull 模式、批量领取），不是改几行能到的事。

## 三个机制的设计取舍

**① 两级闸门：本金永不冻结，奖励可以单独停。**

| 入口 | 可否暂停 | 理由 |
|---|---|---|
| `stake` | ✅ `pause()` | 入口。挡住新资金扩大敞口 |
| `requestUnstake` / `withdraw` | ❌ 永不可暂停 | 用户本金。冻结它等于挪用 |
| `getReward` | ✅ `pauseClaim()` | 项目方承诺。余额不足时应有序发放，而不是让先到的人抢光 |

这条和很多实现相反——常见做法是把 `pause` 挂在 `withdraw` 上，紧急情况下用户本金被锁在里面。**冻结提款防不住挤兑，它只是把挤兑改成排队，而且通常加速死亡**：挤兑的本质不是钱不够，是信任不够，冻结恰恰是承认了信任不够。

行业里活得最久的两个借贷协议都是这个语义：Aave V3 的 `setReserveFreeze` 禁止 supply 和 borrow，但 repay 和 withdraw 完全正常；Compound 在 2021 年 COMP 分发 bug 期间也没冻结提款。

三个细节：

- 暂停期间奖励照常累积（`rewardRate` 由时间决定，与发放动作无关），恢复后一次补齐，用户不损失
- `exit()` 在 `pauseClaim` 期间会**跳过领奖但照常退出本金**，不会因为发奖被停就整笔失败
- 两个开关彼此独立：恢复存入不会顺手恢复发奖

**② 解质押冷却：两阶段退出。** 防的是「存进来、等一秒、连本带息拿走」的闪电贷套利。

```
requestUnstake(amount)  →  本金离开仓位、记入 pendingUnstake、解锁时间 = now + cooldown
        ↓  等待 cooldown
withdraw()              →  本金到账
```

- `unstakeCooldown == 0` 时退化成单笔完成，不牺牲普通用户体验
- 多次发起时解锁时间取**最晚**，新额度不能插队让老额度提前解锁。
  **副作用**：已经过了解锁时间、本可立即提走的老额度，会被新请求一并推后。
  用法上应当先 `withdraw()` 取走已到期的部分，再发起新的解押（A-28）
- 改 `unstakeCooldown` 只影响之后发起的请求，已排队的 `unlockTime` 不变
- 上限 `MAX_UNSTAKE_COOLDOWN = 30 days`，防止管理员把它设成一年来变相锁死本金

**③ 最小质押额。** 挡粉尘攻击，省 gas。只约束之后的 `stake`，不影响已有仓位，也不拦提取。

## 应急预案

代码只提供开关，预案要靠人写下来。下面是这套开关的正确使用顺序——**顺序错了，止血会变成失血**。

| 场景 | 动作 | 用户受影响的部分 |
|---|---|---|
| 发现可疑流量、疑似被套利 | `pause()` 停存入 | 只有新资金进不来 |
| `totalOwed > rewardToken.balanceOf(this)`，偿付不足 | `pauseClaim()` 停发奖 | 只有奖励延后，本金照提 |
| 奖励计算有偏差，需先冻结发放 | `pauseClaim()` + 公告 | 同上 |
| 修复完成 / 补足奖励 | 先 `unpauseClaim()`，再 `unpause()` | —— |

**永远不要做的三件事：**

1. **不要为了「稳住流动性」去冻结 `withdraw`。** 合规上这是挪用，声誉上等于提前宣告死亡。2022 年 Celsius、BlockFi 冻结提款之后，没有一个活下来。
2. **不要只 `pause()` 而不公告。** 链上动作是可观测的，沉默会被解读成跑路。
3. **不要在奖励没补足时就 `unpauseClaim()`。** 那会让 `safeTransfer` 在最后一批用户身上失败，问题从「延后」变成「违约」。

**不需要信任的那层保险：** `totalOwed` 和 `rewardToken.balanceOf(this)` 都是公开可读的，任何人都能算当前偿付率。透明本身是最好的挤兑抑制剂——用户不需要相信运营方，只需要自己验证：

```powershell
cast call $env:STAKING "totalOwed()(uint256)" --rpc-url sepolia
cast call $env:REWARD "balanceOf(address)(uint256)" $env:STAKING --rpc-url sepolia
cast call $env:STAKING "claimPaused()(bool)" --rpc-url sepolia
```

## 部署序列

`script/Deploy.s.sol` 把第 2–6 步合成一次广播（实现合约也在脚本里部署）。手工部署时按这个顺序走，顺序不能改，第 5 步漏了会锁死奖励。

### 怎么跑（Sepolia）

```powershell
. .\set-env.ps1                      # 载入地址与参数（不含私钥）

# 一次性：造两个代币，跑完把打印出来的两行粘回 set-env.ps1
forge script script/DeployTokens.s.sol --rpc-url $env:SEPOLIA_RPC_URL `
  --account deployer --sender $env:DEPLOYER -g 300 --slow --broadcast

# 干跑：不发交易、不写清单，只看每一步会不会过
forge script script/Deploy.s.sol --rpc-url $env:SEPOLIA_RPC_URL `
  --sender $env:DEPLOYER

# 真跑。倍数说明见下面那一段，不要随手改成 800
forge script script/Deploy.s.sol --rpc-url $env:SEPOLIA_RPC_URL `
  --account deployer --sender $env:DEPLOYER -g 750 --slow --broadcast
```

**为什么是 `-g 750` 而不是常用的 800**：forge 的本地估算按主网价（200 gas/字节）算，
而 Sepolia 已经生效的 EIP-8037 是 1,530 gas/字节，差 7.65 倍，所以要用倍数补。
V1 实现合约本地估 2,119,214，×7.5 = 1,589 万，够需要的 1,479 万；
×8 = 1,695 万，已经越过 EIP-7825 的单笔上限 16,777,216，会被节点直接拒。
**报 OOG 才小幅上调到 780，不要一步跳到 800。**
这条只覆盖 V1：V2 要 1,632 万，`-g 750`（1,589 万）**不够**，得用
`forge create --gas-limit 16777216` 或 `-g 780`。

`--slow` 不是可选项：脚本里后一步依赖前一步的结果（注资依赖代理已存在），
批量发送时如果某笔失败，后面几笔会打在一个不完整的状态上。

0. **先有代币。** 测试网上不存在现成的 `stakingToken` / `rewardToken`，`script/DeployTokens.s.sol` 负责造出这两个并给部署地址打额度。真实项目里这一步换成「确认两个币的地址」，不要部署 Mock。
1. **两项前置检查。** ① `stakingToken != rewardToken`：同一地址会让 `available = balance - totalOwed` 里混进用户本金，manager 能把本金当奖励预算许诺出去，退出潮中后提者拿不到本金（A-9）。**这条现在由 `initialize` 自己拦**，填错会停在第 3 步并回 `InvalidToken()`，不消耗后续任何一步的 gas；零地址同样在这一步被拒。② `rewardToken` 必须是标准 ERC20，不支持 fee-on-transfer 与负向 rebase（A-19）：负向 rebase 会让余额低于负债，`available` 的减法退化成 `Panic(0x11)` 而不是可读的错误；fee-on-transfer 会让实际到账少于许诺额，负债与余额长期背离。
2. **部署实现合约**（无构造参数）。它自己的构造函数只调 `_disableInitializers()`，所以这个地址不可直接使用。
   脚本里就是一句 `new StakingRewards()`；想手工拆开，用 `forge create src/StakingRewards.sol:StakingRewards --gas-limit 16000000`（这个参数是绝对值，不走倍数换算）。
3. **部署代理并初始化**，一步完成：

   ```solidity
   new ERC1967Proxy(impl, abi.encodeCall(StakingRewards.initialize, (stakeToken, rewardToken, duration, cooldown)))
   ```

   代理和 initialize 必须在**同一笔交易**里。分成两笔会留抢跑窗口：任何人看到待打包的初始化交易，都能用更高的 gas 抢先把自己的地址设成四个角色。
4. 把 `rewardToken` 转到**代理地址**，金额 ≈ 每秒速率 × 周期长度。脚本用 `transfer`（不是 `transferFrom`），因此部署地址在跑脚本前必须已持有 `FUND_AMOUNT`。注意所有交互都指向代理，不是实现合约。
5. `notifyRewardAmount(金额)`。它会校验余额是否覆盖整期，并先扣掉已产生未转出的负债（含未结算应计）。
6. **立刻 `stake(1 wei)`。** 空池期间不累积，这段产出没有任何人有资格领取，且 `recoverERC20` 禁止取回 `rewardToken`——整期空池就是 100% 锁死（A-8）。1 wei 随时可 `requestUnstake` 取回，成本可忽略。脚本已包含这一步。
7. 断言九项：`rewardRate() > 0`、`periodFinish() == now + rewardsDuration`、`totalSupply() == 1`、`totalOwed() == 0`、`unstakeCooldown` 回读，以及 `implementation()` 指向刚部署的实现、`stakingToken()` 确实存在代理的存储里、三个角色落在部署地址上。脚本内已内置。

### 倍数为什么要卡在 750

实现合约 9,329 字节，Sepolia 上部署约需 **1,479 万 gas**，而单笔执行的硬上限是 16,777,216（EIP-7825）。
forge 的 `--gas-estimate-multiplier` 是「本地估算 × 倍数」，而本地估算按主网价（200 gas/字节）算，
所以倍数同时承担了两件事：补 7.65 倍的计价差，以及留出安全余量。按本地估算 2,119,214 算：

| 倍数 | 给到 | 结果 |
|---|---|---|
| `-g 700` | 14,834,498 | 比需要的 1,479 万只多 0.3%，估算稍有偏差就 OOG |
| **`-g 750`** | **15,894,105** | **V1 用这个，余 7.5%** |
| `-g 780` | 16,529,869 | V2（需 1,632 万）用这个，余 1.5% |
| `-g 800` | 16,953,712 | **越过 16,777,216，节点直接拒** |

代理那一笔只有 387,299 gas（本地实测），同样的倍数有大量余量，所以整份脚本只用一个倍数就够。

## 跑脚本

四个参数全部走环境变量，脚本里不写死任何地址或金额。

**这些变量都在 `set-env.ps1` 里了，开新窗口只需一行载入**（注意前面是「点 + 空格」，这叫 dot-source，不加点变量会随子进程一起消失）：

```powershell
. .\set-env.ps1
```

手工设置的话对应这些：

```powershell
$env:STAKE_TOKEN = "0x..."
$env:REWARD_TOKEN = "0x..."          # 部署地址需已持有 FUND_AMOUNT
$env:REWARDS_DURATION = "604800"
$env:FUND_AMOUNT = "604800000000000000000000"
$env:DEPLOYER = (cast wallet address --account deployer)   # 会提示输入 keystore 密码
$env:UNSTAKE_COOLDOWN = "0"          # 可选，缺省 0；真实池子建议 86400（1 天）
$env:GUARDIAN_ADDRESS = "0x..."      # 可选，守卫地址；不填则留给部署者并打印警告
$env:ADMIN_MULTISIG = "0x..."        # 可选，多签地址；不填则留给部署者并打印警告

# 先干跑：看 trace、不写链
forge script script/Deploy.s.sol --rpc-url sepolia --account deployer --sender $env:DEPLOYER -vvvv

# 确认无误再真发（--gas-estimate-multiplier 1000 不能省，见下）
forge script script/Deploy.s.sol --rpc-url sepolia --account deployer --sender $env:DEPLOYER --gas-estimate-multiplier 1000 --slow --broadcast --verify
```

bash / Git Bash 里把 `$env:X = "v"` 换成 `export X=v`，**引用时也要一起换**：`$env:DEPLOYER` 在 bash 里是 `$DEPLOYER`。两种写法不通用，混用会展开成空字符串，命令静默少一个参数照跑不误。

**地址只在一个地方出现。** `$env:DEPLOYER` 取的是 `cast wallet address --account deployer`，和 `--account` 同源，不可能对不上。手抄两遍同一个地址的真实风险不是打错字——**打错一个字会被脚本的 `require(msg.sender == deployer)` 拦住；两边错成同一个才致命**，那次检查恰好通过，错误落到链上才暴露。

变量没设时 PowerShell 把它展开成空串，命令照样执行。广播前先自查一遍：

```powershell
foreach ($k in "DEPLOYER","STAKE_TOKEN","REWARD_TOKEN","FUND_AMOUNT") {
    if (-not [Environment]::GetEnvironmentVariable($k)) { "缺少变量: $k" }
}
```

干跑不是「随便跑跑」：它对**当前链上状态**做模拟，余额不足、地址错误、断言不过都会在这里红。干跑通过了才加 `--broadcast`。

**`-g 1000` 是必须显式给的。** 注意 `--gas-limit` 是 `--block-gas-limit` 的别名（管区块上限），**对单笔交易无效**；能放大交易上限的是 `-g, --gas-estimate-multiplier`，默认 130%。

原因是 Sepolia 已启用 Glamsterdam 的 **EIP-8037**，把 code deposit 从 200 gas/字节提到 **1,530 gas/字节**（8.65 倍），本地 foundry 仍按 cancun 规则估算：

| 合约 | 运行时字节 | 本地估出（×130%） | Sepolia 实际需要 | `-g 1000` 给出 |
|---|---|---|---|---|
| `MockERC20` | 1,884 | 674,208 | **3,383,645** | 5,186,220 ✅ |
| `StakingRewards` | 6,325 | 2,097,514 | **10,972,727** | 16,134,720 ✅ |

不给够上限就会 `status: 0x0`、且 `gasUsed == gasLimit`——那是 gas 耗尽，不是普通 revert。

**`StakingRewards` 的 `-g` 已经不能随便加大。** 16,134,720 距 EIP-7825 的 16,777,216 单笔上限只剩 64 万，`-g 1100` 就会被节点直接拒绝（`exceeds max transaction gas limit`）。加功能的余量只有约 4%，再往合约里塞逻辑就得先做优化：调低 `optimizer_runs`、拆合约、或者把不常用的读函数改成 `view` 外部库。gas 上限高**不会多花钱**，只按实际消耗结算。

`foundry.toml` 里 `[rpc_endpoints]` / `[etherscan]` 已经配好，只需 export `SEPOLIA_RPC_URL` 与 `ETHERSCAN_API_KEY`，就能把上面命令里的长 URL 换成 `--rpc-url sepolia`。这两个变量没 export 时 `forge build` / `forge test` 照常跑，插值是惰性的。

> 在 PowerShell 里环境变量不是 `export`，要写 `$env:STAKE_TOKEN = "0x..."`，且只对当前窗口生效。

## 链上演武

部署完只是「存在」，跑一遍才算「能用」。`script/DemoFlow.s.sol` 把一次完整的用户旅程拆成两段——
冷却期在链上没法快进，所以退出流程必然跨两条命令，这不是脚本的缺陷，是它要演示的东西本身。

```powershell
. .\set-env.ps1     # 一行载入全部变量；点号不能省，否则变量随子进程一起消失
```

`set-env.ps1` 里 `DEPLOYER` 写的是固定地址，与 `--account deployer` 保持一致。换账户时两处一起改，脚本会在广播前用 `require(msg.sender == DEPLOYER)` 拦住不一致的情况。

**第一段**（现在跑）：存入 → 发起解押，断言本金确实离开仓位、解锁时间落在冷却窗口内

```powershell
forge script script/DemoFlow.s.sol:DemoStep1 --rpc-url sepolia --account deployer --sender $env:DEPLOYER --gas-estimate-multiplier 800 --slow --broadcast
```

**第二段**（冷却结束后跑）：取回本金 → 领奖励，断言资金守恒且合约仍有偿付能力

```powershell
forge script script/DemoFlow.s.sol:DemoStep2 --rpc-url sepolia --account deployer --sender $env:DEPLOYER --gas-estimate-multiplier 800 --slow --broadcast
```

**这里的 `-g` 是 800，`Deploy.s.sol` 是 1000，两者防的不是同一件事：**

- 部署脚本防的是 **code deposit**：6,325 字节 runtime × 1,530 gas
- 演武脚本防的是 **SSTORE 冷槽位**：首次写一个全新槽位在 Sepolia 上是 **97,920 gas**（主网 20,000）

实测三个调用在 Sepolia 上的真实消耗，与 forge 本地估算差 3~4 倍：

| 调用 | forge 估算 | Sepolia 真实需要 | 写几个新槽位 |
|---|---|---|---|
| `approve` | 46,000 | 128,299 | 1（allowance） |
| `stake` | 167,694 | **565,352** | 5 |
| `requestUnstake` | ~230,000 | **739,958** | 7（含结算累积奖励） |

`requestUnstake` 比 `stake` 贵，是因为它除了写仓位，还要先把这段时间累积的奖励结算进 `rewards` 和 `totalOwed`——**冷槽位数量决定开销，跟函数名字看着复不复杂无关**。

**估算永远偏低的原因**：forge 用本地 EVM 规则估算，Sepolia 已启用 EIP-8037 的存储提价。不是参数写错，是两边计价规则不同。所以这类调用只能靠倍数兜底。

怀疑某个调用要多少，直接问链，这个数永远准：

```powershell
cast estimate $env:STAKING "stake(uint256)" $env:DEMO_AMOUNT --from $env:DEPLOYER --rpc-url sepolia
```

**如果倍数调了还是失败，改用 `cast send`**——它让节点自己估算，没有本地/链上规则差异这一层：

```powershell
cast send $env:STAKE_TOKEN "approve(address,uint256)" $env:STAKING $env:DEMO_AMOUNT --rpc-url sepolia --account deployer
cast send $env:STAKING "stake(uint256)" $env:DEMO_AMOUNT --rpc-url sepolia --account deployer
cast send $env:STAKING "requestUnstake(uint256)" $env:DEMO_AMOUNT --rpc-url sepolia --account deployer
```

代价是没有脚本里那几条断言，成功与否只能靠事后 `cast call` 回读。

冷却没到就跑第二段会红，报 `Demo: still locked`；这是预期行为——**提前取不回来本身就是这个机制要证明的事**。

手动验证冷却拦截（不消耗 gas，因为估算阶段就 revert）：

```powershell
cast send $env:STAKING "withdraw()" --rpc-url sepolia --account deployer
# 报 StillLocked(unlockTime)，unlockTime 就是第一段打印的那个时间戳
```

## 上测试网

### 一次性准备

```shell
# 1. 私钥进 keystore，不要出现在命令行历史与环境变量里
cast wallet import deployer --interactive

# 2. 记下地址，去水龙头领 Sepolia ETH（0.5 ETH 够跑十几次）
cast wallet address --account deployer

# 3. RPC 与浏览器 key（Infura / Alchemy / QuickNode 任选）
export SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/<key>
export ETHERSCAN_API_KEY=<key>
```

### 每次部署

> **下面每条命令都是完整的一行，直接整行粘贴。** 不要用 `\` 或反引号切成多行——PowerShell 不认 `\` 续行，切行后后半段（通常正好是 `-g` 那个参数）会被丢掉，命令照跑，但 gas 上限没放大，结果就是广播出去的交易 `gasLimit` 回到默认值，状态 `0x0`。

```powershell
# 第一步：造两个代币（只有测试网需要）
$env:DEPLOYER = (cast wallet address --account deployer)   # 会提示输入 keystore 密码
$env:MINT_TO = $env:DEPLOYER      # 铸给自己；想铸给别人就换成对方地址
$env:MINT_AMOUNT = "1000000000000000000000000"
forge script script/DeployTokens.s.sol --rpc-url sepolia --account deployer --sender $env:DEPLOYER --gas-estimate-multiplier 1000 --slow --broadcast

# 终端会打印两行，抄进环境变量
$env:STAKE_TOKEN = "0x..."      # pSTK
$env:REWARD_TOKEN = "0x..."     # pRWD
$env:REWARDS_DURATION = "604800"
$env:FUND_AMOUNT = "604800000000000000000000"
$env:UNSTAKE_COOLDOWN = "86400"

# 第二步：部署实现合约（单独一笔，用绝对 gas 上限，不走倍数）
forge create src/StakingRewards.sol:StakingRewards --rpc-url sepolia --account deployer --gas-limit 16000000

# 终端会打印 "Deployed to: 0x..."，抄进变量。
# 这一笔要约 1,479 万 gas，16,000,000 的上限留了 8% 余量，且低于 EIP-7825 的 16,777,216
$env:IMPLEMENTATION = "0x实现合约地址"

# 第三步：干跑，确认变量与链上状态都对（不花钱）
forge script script/Deploy.s.sol --rpc-url sepolia --account deployer --sender $env:DEPLOYER -vvvv

# 第四步：部署代理 + 初始化 + 注资 + 开奖 + 种子质押 + 自检
forge script script/Deploy.s.sol --rpc-url sepolia --account deployer --sender $env:DEPLOYER --gas-estimate-multiplier 800 --slow --broadcast
```

**为什么部署要分两段**：实现合约 9,329 字节，Sepolia 上约需 1,479 万 gas，离单笔上限只剩 199 万。
`-g 900` 会算到 1,907 万、被节点直接拒收；`-g 800` 到 1,695 万，也越线。
`forge create --gas-limit` 给的是绝对值，不受本地/链上计价规则差异影响。
代理那笔只有 38 万 gas（本地）／约 150 万（Sepolia），`-g 800` 余量充足。

**第四步的所有交互都指向代理地址**，不是 `$env:IMPLEMENTATION`。填错不会报错，只会发现读出来的状态全是 0——
因为实现合约的存储从来没被写过。

**`--sender $env:DEPLOYER` 每一处都不能省。** 只用 `--account deployer` 而不写 `--sender`，forge 会把 `msg.sender` 设成 `0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38`（它自己的默认地址，没有任何人有私钥）。后果是连锁的：

- `mint(msg.sender, ...)` 把币铸给那个死地址，**链上不报错，交易照样成功**
- `initialize` 把四个角色全部授予 `msg.sender`，落错地址等于四个角色一起作废。合约虽然是可升级的，但**改角色需要 ADMIN，改实现需要 UPGRADER，两者都在那个死地址上**——等于同时失去治理和升级能力，比不可升级版更难救
- 注资的 `transfer` 从那个地址的余额出，不是你的

脚本里已经加了闸门：`Deploy.s.sol` 广播前 `require(msg.sender == DEPLOYER)`，`DeployTokens.s.sol` 用 `MINT_TO` 显式指定收款方并回读余额。两处都对不上就一粒 gas 都不花。

`--slow` 让每笔交易等上一笔上链再发下一笔，公共 RPC 上能避免 nonce 与状态不同步。

### 广播前先确认 gas 上限真的放大了

参数有没有生效，不看命令行，看两个地方：

1. 脚本第一行会打印 `tx gas budget`。**约 500 万才正常；显示 67 万左右说明 `--gas-estimate-multiplier` 没进到命令里**，此时按 Ctrl+C 中止，一分钱不花。
2. 万一已经广播，用交易哈希反查：`cast tx <hash> --rpc-url sepolia -f gasLimit`。`674208` 就是没放大；`5186220` / `10113210` 才是对的。

`674208` 这个数字的来历是本地估算 `518622 × 130%`（默认倍率）。它每次失败都一模一样，所以看到同一个数字反复出现，基本可以断定是参数丢了，不是合约逻辑问题。

### 部署后回读

```shell
cast call $STAKING "rewardRate()(uint256)"        --rpc-url sepolia   # 应为 1e18
cast call $STAKING "totalSupply()(uint256)"       --rpc-url sepolia   # 应为 1，种子质押已到位
cast call $STAKING "totalOwed()(uint256)"         --rpc-url sepolia   # 应为 0
cast call $STAKING "periodFinish()(uint256)"      --rpc-url sepolia   # 约等于部署时刻 + 604800
```

`periodFinish` 会比「本地当前时间 + 604800」晚几秒，因为脚本里的断言跑在模拟块上，真实周期从**打包时刻**起算。

## 源码验证

没验证的合约在区块浏览器上只是一串字节码。别人点开链接看不到源码，等于没交付。

**代理模式下要验证的是实现合约，不是代理。**

```powershell
$env:ETHERSCAN_API_KEY = "在 etherscan.io/apis 免费申请"

# 验证实现合约：它没有构造参数，所以不需要 --constructor-args
forge verify-contract $env:IMPLEMENTATION src/StakingRewards.sol:StakingRewards --chain sepolia --etherscan-api-key $env:ETHERSCAN_API_KEY

# 代理地址不用手动验证：Etherscan 会自动识别 ERC1967 的标准字节码，
# 并在实现验证通过后把它标成 "Read as Proxy" / "Write as Proxy"
```

**实现合约没有构造参数**（业务参数全在 `initialize` 里），所以这里不能带 `--constructor-args`。
带了会报 `constructor args mismatch`——因为验证比的是「这份字节码是不是由这份源码 + 这组参数编译出来的」。

验证通过后，在 Etherscan 上点 `Read as Proxy` / `Write as Proxy` 标签，看到的才是你的业务函数。
直接看 `Contract` 标签只能看到代理那 163 字节的 fallback。这条命令不消耗 gas。

## 踩过的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 创建交易 `status 0x0`，且 `gasUsed == gasLimit`，两个 mint 却「成功」 | gas 耗尽（不是普通 revert）。Sepolia 已启用 EIP-8037，code deposit 1,530 gas/字节，本地 cancun 只按 200 估，×130% 远远不够 | 加 `--gas-estimate-multiplier 1000`；mint 的「成功」是因为打到了没有代码的空地址，实际什么都没铸 |
| 明明写了 `-g 1000`，广播出去 `gasLimit` 还是 674,208 | 它被写在了 `\` 续行的第二行。PowerShell 不认 `\` 续行，后半段根本没执行，等于没加 | 整条命令写成一行；脚本首行打印的 `tx gas budget` 是 67 万级就是没生效 |
| 代币部署「成功」，`totalSupply` 也对，但自己的 `balanceOf` 是 0 | 没写 `--sender`，`msg.sender` 是 forge 默认地址 `0x1804c8AB…`，币全铸给它了。mint 到无主地址不会 revert | 补铸：`cast send <token> "mint(address,uint256)" <你的地址> <数量>`；以后每条广播命令都带 `--sender` |
| 加了 `--gas-limit 8000000`，但广播出去仍是 674,208 | `--gas-limit` 在本版本是 `--block-gas-limit` 的别名，管的是**区块**上限，对单笔交易无效 | 改用 `-g 1000`（`--gas-estimate-multiplier`） |
| `stake` 的 gas 比预期高好几倍 | EIP-8037 同时把新 storage slot 从 20,000 提到 97,920 状态 gas | 正常现象，不是合约写错 |
| `HTTP error 502`，连本地 anvil 也失败 | 本机设了 `HTTP_PROXY`，把 `127.0.0.1` 也代理走了 | 本地命令前加 `NO_PROXY=127.0.0.1,localhost` |
| 干跑报 `ERC20InsufficientBalance` | 干跑基于真实余额模拟，额度已被前一次广播用掉 | 先 `cast call balanceOf` 核对，别怀疑脚本 |
| `--verify` 报 `Missing etherscan-api-key` | 只配了 RPC，没 export 浏览器 key | `export ETHERSCAN_API_KEY=<key>` 后重跑 |
| 广播后浏览器查不到源码 | verify 与广播是两个动作，verify 失败不回滚部署 | 补跑 `forge verify-contract <addr> src/StakingRewards.sol:StakingRewards --chain sepolia` |
| 部署成功但池子锁死 | 漏了第 5 步的 `stake(1 wei)`，整期空池 | 脚本已内置，手工部署时别漏 |
| 代理部署成功，但读什么都是 0 | 交互打到了**实现合约**地址，不是代理。实现合约的存储从来没被写过，也不会报错 | 所有读写都指向代理地址；`implementation()` 能看出代理指向谁 |
| `forge script` 部署实现时报 `exceeds block gas limit` 或直接被拒 | 实现合约 9,329 字节，Sepolia 上要约 1,479 万 gas。`-g 900` 算出来 1,907 万，超过 EIP-7825 的 16,777,216 | 用 `forge create --gas-limit 16000000` 单独部署实现，这个参数是绝对值，不走倍数换算 |
| 升级时报 `UUPSUnauthorizedCallContext` | 直接对实现合约调 `upgradeToAndCall`，或者把代理指向了没有代码的地址 | 升级只能通过代理发起，且新实现必须已部署 |
| 升级后用户仓位还在，但新加的函数读出来是旧值 | V2 的状态变量插错了位置，读到了别的槽 | 升级前用 `forge inspect <合约> storageLayout` 对比两份布局 |

## 静态检查：`forge lint` 为什么还剩 14 条 note

`forge lint` = 编译器警告（`solc`）+ Foundry 自己的规则集。**warning 级别已经清零**，
包括部署脚本里那条最该修的 `erc20-unchecked-transfer`（`transfer` 返回 false 而不 revert 时，
脚本会以为注资成功了——现在统一走 `SafeERC20`）。剩下 14 条都是 **note**，全部是「改了要付代价」：

| 规则 | 条数 | 位置 | 为什么不动 |
|---|---|---|---|
| `screaming-snake-case-immutable` | 9 | `src/StakingRewardsETH.sol` 的 `rewardToken`，以及测试 handler 持有的 `staking` / `stakeToken` / `rewardToken` | src 里那个是 `public immutable`，改名等于改 ABI（getter 名就是变量名），所有测试与前端都会跟着崩；测试里的改成 `STAKING.balanceOf(...)` 可读性反而更差 |
| `unwrapped-modifier-logic` | 2 | `src/StakingRewards.sol` / `StakingRewardsETH.sol` 的 `whenNotClaimPaused` | 把 modifier 体包成 internal 函数能省十几字节，但**会改变字节码**；V2 在 Sepolia 的单笔余量只剩约 297 字节，动它要先重测部署 gas，收益不值 |
| `mixed-case-function` | 2 | `recoverETH`、`_sendETH` | 前者是 ABI 名，改了就破坏已部署实例与集成方；后者是内部函数，跟着一起保持对称 |
| `mixed-case-variable` | 1 | `__gap` | OpenZeppelin 的升级预留槽惯例就是双下划线，不是笔误 |

判断标准：**note 不改变正确性**。真要压，用 `// forge-lint: disable-next-line(<规则名>)` 就地注明理由，
不要为了让工具闭嘴去改 ABI——那才是把工具意见当成需求。

## 常用命令

```shell
forge test                                                      # 全部（23 套件 / 263 条）
forge test --match-path "test/StakingRewardsETH/*"              # 只跑 ETH 池
forge test --match-test test_ZeroCooldownReturnsPrincipalImmediately -vvvv    # 单条 + 完整调用轨迹
forge test --match-contract ETHRecoverTest -vv                   # 一个关注点 + 事件与返回值
forge test --match-path "test/StakingRewardsV2/*" -vv            # 升级相关
forge lint                                                      # 静态检查（warning 应为 0）
forge lint script/Deploy.s.sol                                  # 只查部署脚本
```
