# 测试验证报告

> 本文件由**测试对话**维护，2026-11-12。上一版「审计与编写交接板」已废弃。
>
> **测试对话不改任何代码。** 只做三件事：跑测试、往实现里注入错误看测试是否变红、把结论写在这里。
> 测试由编写对话写——**写测试的人不能同时验证测试**，这是本文件所有结论可信的前提。

## 0. 三方分工

| 窗口 | 拥有 | 能做什么 | 不能做什么 |
|---|---|---|---|
| **编写** | `src/` + `test/` | 写合约、写测试、改自己写的测试 | 不能声称「测试已验证」 |
| **测试**（本窗口） | 只有本文件 | 跑全量、定向变异、出结论 | **不写测试、不改合约** |
| **审计** | 无 | 读代码 + 读本报告，出风险结论 | 不改任何文件；不重复 §5 已覆盖的内容 |

闭环固定：**编写写实现+测试 → 测试验证出报告 → 审计把关 → 问题回流编写**。

---

## 1. 结论

| 项 | 状态 |
|---|---|
| 基线 | **268 条 / 24 个套件**，`forge test` → `0 failed`（2026-11-17 实测：补 ERC20 池重入 5 条；此前 263 / 23） |
| 上一轮验证时 | 233 条。本轮分两批落地：先 6 条（建议 H 两条误转、建议 I 两池各一条不变量 + 一条影子自检），验证途中又 3 条 |
| 有效性 | 累计 **28 个注入点，全部被抓**。2026-11-17 新增 27/28 两条，打的是 `stake` / `getReward` 上的 `nonReentrant` |
| 缺口状态 | 建议 **A ~ I 全部闭合**；§6.1（ETH 池紧急退出）与 §6.3（ERC20 池重入）已于 2026-11-17 闭合，§6 只剩 lint 风格项 |
| 实现缺陷 | `initialize` 不拦 `stakingToken == rewardToken` → **本轮中途修掉**，三条用例 + 三次注入验收（24~26），见 §5 |
| 全局进度 | **约 86%**（口径见 §1.1） |
| **上线就绪** | **否**，但性质变了：不再有已知代码缺陷，部署脚本（两池 + 升级手册）已齐，缺的是**独立第三方审计**与 **CI** |
| 代码侧待定 | ETH 池没有 `emergencyWithdraw`，等 user 拍板（§6.1） |

一句话：**三本账（本金 / 冷却本金 / 奖励负债）在两个池上都有序列级证据了。**

先说那条阻断，**它在本轮中途被修掉了**。我最初取基线时 `src/` 哈希与上轮完全一致（缺陷还在），
写报告写到一半再跑全量，条数从 239 变成 242、两个源文件哈希也变了——编写窗口正在同时改。于是重新取基线重验：

- `StakingRewards.initialize:241` 新增 `if (address(stakingToken_) == address(rewardToken_)) revert InvalidToken();`
- `StakingRewardsETH` 构造函数新增 `if (address(rewardToken_) == address(0)) revert InvalidToken();`
- 配三条用例（`test_InitializeRejectsSameToken` / `test_InitializeRejectsZeroToken` /
  `test_ConstructorRejectsZeroRewardToken`），三次注入逐个打红，都是「目标红 1、相邻全绿」

所以现在**没有已知的代码缺陷**了。但「没缺陷」不等于「能上线」——缺的换成了流程面那两项（审计、CI）。

再说这一轮真的变好的那部分：新增的 `invariant_UnlockTimeNeverShortened` 是**第一条覆盖
「治理动作 × 用户操作」交叉的不变量**。此前「改短冷却不能把老额度提前放出来」只有一条单点用例守着
（`test_LoweringCooldownDoesNotUnlockOldAmountEarly`），现在两个池的 handler 都会在序列中间改冷却，
不变量拿一本影子账本（`_expectedUnlock`）比对。注入验证过：删掉「取最晚」那一行，
两个池的不变量分别报 `unlock time never moved earlier`。

另一条是 ETH 的 `receive()` 终于被真实转账走过一次——此前三处「误转」全用 `vm.deal` 绕过这一层，
这个函数的存在性只由编译保证。

### 1.1 全局进度口径

> user 要求每次验证后报一次全局进度。口径写死在这里，避免下次随手改数字。

分母是**五条资金/安全命题 + 两条工程命题**，看的是「有没有独立证据」，不是「写了多少条用例」：

| 命题 | 状态 | 证据 |
|---|---|---|
| 本金账平（`held == totalSupply + pending`） | 满分 | 两池各一条等式不变量 + 注入命中 |
| 奖励负债账平（`Σ rewards ≤ totalOwed ≤ 余额`） | 满分 | 两池各一条夹逼不变量 + 上下界各注入一次 |
| 奖励发放正确（线性 / 对半 / 无补发 / 周期停付） | 满分 | 两池各 15 条单点 + 2 条守恒 fuzz |
| 权限制衡（没钱的角色动不了钱） | 满分 | 两池表驱动拒外人 + 角色移交 + 误挂权限注入 |
| 升级保状态 | 满分 | V2 20 项快照 + 三条「跨升级仍可取/仍累积」 |
| 异常路径（挪走本金的手段都堵死） | 满分 | 回收上限、暂停期退出、重入、误转单点覆盖；本轮落地三件：`receive()` 真实转账、「改短冷却 × 已挂起请求」进不变量、同币/零地址部署在初始化就被拒。**2026-11-17 补齐最后一块**：ERC20 池重入 5 条 + 两次守卫变异（§6.3 / §5 的 27、28） |
| 真实环境（fork / 非标准代币 / gas 基准） | 零分 | 见 §7.1、§7.2，**有意的取舍 + 未做的基准** |

七行等权：`(6×1 + 1×0) / 7 ≈ 86%`。

**与上轮 90% 的差异要说清，否则像是退步了**：上轮那个 90% 是我算错的——
式子里写 `4×1 + 3×1 + …` 一共 7 项，却除了 8，而且 7.8/8 也不等于 92%。按 7 行等权，上轮真实值应是 83%。
本轮异常路径从 0.8 升到 0.95（三件事落地），得 85%。所以：**−7 个点是纠正我自己的算术错误，
+2 个点是命题状态真的变了**。

剩下的 14% 集中在**一处**：真实环境那一行的 0 分（fork / 非标准代币 / gas 基准）。
异常路径那 0.05 已在 2026-11-17 补平（ERC20 池重入 5 条 + 两次守卫变异）。
要再往上走，动的是 §7.1 那个取舍，不是继续加用例。

---

## 2. 被测对象

| 合约 | 行数 | 形态 | 测试基座 |
|---|---|---|---|
| `StakingRewards.sol` | 542 | UUPS 可升级（`initialize` + `__gap`） | `StakingRewards/StakingRewardsBase.sol`，经 `ERC1967Proxy` 交互 |
| `StakingRewardsV2.sol` | 190 | V1 的升级版，只加函数、零新增状态变量 | `StakingRewardsV2/StakingRewardsV2Base.sol`，继承 V1 基座后真实升级 |
| `StakingRewardsETH.sol` | 473 | constructor 版，原生 ETH 质押 | `StakingRewardsETH/StakingRewardsETHBase.sol`，`admin = address(this)` |
| `MockERC20.sol` | 25 | 测试燃料，`mint` 受 `onlyOwner` | 独立 |

四者共享同一套 Synthetix 式奖励数学、三角色分层、两级闸门、解押冷却。ETH 版三处实质差异：
`stake()` 无参 payable、转出用 `call{value}`、多一个 `totalPending` 记账。

两个基座的关键差别（写测试时别混）：
- ERC20 池 `FUND = 604800e18` 能被 `DURATION` 整除，速率无截断 → 可以 `assertEq`
- ETH 池现为 `RATE = 1e18`（每秒 1 枚，`FUND = 604800e18`），**速率同样干净**，`ONE_DAY_REWARD` 正好 `86400e18`。
  精确值断言原则上可以 `assertEq`；但 `rewardPerToken` 的 `/ totalSupply` 会按用户 floor，
  多一个质押者就可能残留几 wei，所以负债类断言仍留 `1e6` 容差（§3.16 的注释写了这个理由）

---

## 3. 逐条用例清单（268 条）

> 条数与 §2 行数由编写窗口按 2026-11-12 实测值刷新（新增 13 条：F-1 取整回归 2 条、
> ETH `emergencyWithdraw` 7 条、`exit` 重锁 2 条、两个 `emergencyWithdraw` 的取整差额各 1 条）。
> **2026-11-17 再补 5 条**（§3.23，ERC20 池重入），实测 `268 passed, 0 failed`（24 套件）。
> 本节以下的分条统计与 §5 的注入表
> **仍是 242 基线那一轮的记录**，需要测试窗口重跑后更新。

> 3.1–3.19 是基础版本，3.20–3.22 是迭代中新增的文件与用例。
> 小节编号沿用上一版不重排，方便和旧报告对照。

### 3.1 `test/MockERC20/MockERC20.t.sol` — 10 条

| 用例 | 守什么 |
|---|---|
| `test_Metadata` | name / symbol / decimals(18) / 初始总量为 0 |
| `test_DeployerIsOwner` | 部署者即 owner |
| `test_OwnerCanMint` | owner 铸币后余额与总量同步 |
| `test_NonOwnerCannotMint` | 非 owner 铸币被拒，且错误类型是 `OwnableUnauthorizedAccount` |
| `test_MintToZeroAddressReverts` | 铸给零地址由 ERC20 内部拦下（`ERC20InvalidReceiver`） |
| `test_OwnershipTransferMovesMintRight` | 移交后原 owner 铸不出来，新 owner 能铸 |
| `test_ApproveAndTransferFrom` | approve → transferFrom 消费额度到 0，双方余额正确 |
| `test_TransferFromWithoutAllowanceReverts` | 无授权时错误为 `ERC20InsufficientAllowance(bob, 0, 1)` |
| `test_TransferMoreThanBalanceReverts` | 超余额转出错误为 `ERC20InsufficientBalance` |
| `testFuzz_MintKeepsSupplyConsistent` | 任意两次铸币后 `totalSupply == 两人余额之和` |

### 3.2 `test/StakingRewards/Access.t.sol` — 15 条

| 用例 | 守什么 |
|---|---|
| `test_DeployerHoldsAllRoles` | 初始化者同时持有 ADMIN / MANAGER / GUARDIAN |
| `test_OtherAddressesHaveNoRoles` | 普通用户三个角色都没有 |
| `test_NotifyRejectsOutsider` | `notifyRewardAmount` 拒绝外人 |
| `test_SetDurationRejectsOutsider` | `setRewardsDuration` 拒绝外人（先 warp 到周期结束，避免被 `PeriodStillActive` 抢先） |
| `test_SetMinStakeRejectsOutsider` | `setMinStakeAmount` 拒绝外人 |
| `test_SetCooldownRejectsOutsider` | `setUnstakeCooldown` 拒绝外人 |
| `test_RecoverRejectsOutsider` | `recoverERC20` 拒绝外人 |
| `test_PauseRejectsOutsider` | `pause` 拒绝外人 |
| `test_PauseClaimRejectsOutsider` | `pauseClaim` 拒绝外人 |
| `test_UnpauseRejectsOutsider` | `unpause` 拒绝外人 |
| `test_AllAdminFunctionsRejectOutsider` | 表驱动兜底 9 个入口，**断言到 `AccessControlUnauthorizedAccount` selector**，区分「无权限」与「业务状态不符」 |
| `test_ManagerCannotTouchAdminOnlyFunctions` | manager 能改最小质押额，但动不了冷却与回收 |
| `test_GuardianCannotChangeRewardParams` | guardian 能拉两个闸门，但改不了奖励参数 |
| `test_GrantAndRevokeRoundTrip` | 授权 → 可用 → 撤销 → 不可用 |
| `test_ManagerCannotGrantRoles` | manager 不能自我复制 ADMIN |

### 3.3 `test/StakingRewards/Cooldown.t.sol` — 12 条

| 用例 | 守什么 |
|---|---|
| `test_RequestCreatesPending` | 发起解押后份额扣除、本金进 pending、`withdrawable()` 报告未解锁 |
| `test_WithdrawOneSecondBeforeUnlockReverts` | 解锁前 1 秒拒绝，错误带 `unlockTime` |
| `test_WithdrawAtUnlockSucceeds` | 边界是 `>=`，正好等于解锁时刻通过，请求被清 |
| `test_WithdrawTwiceReverts` | 提过一次后状态清零，第二次报 `NothingToWithdraw` |
| `test_SecondRequestExtendsUnlock` | 二次请求金额累加、解锁时间取较晚 |
| `test_LoweringCooldownDoesNotUnlockOldAmountEarly` | **「取最晚」真正起作用的场景**：30 天发起 → 改 1 天 → 再发起，老额度仍锁到首次解锁时刻 |
| `test_RequestSettlesRewardUpToThatMoment` | 发起时结清此前奖励，冷却期内仓位为 0 不再累积 |
| `test_ExitLeavesPrincipalPending` | `exit` 在冷却模式下奖励到账、本金进排队 |
| `test_CooldownChangeDoesNotAffectPending` | 管理员改冷却不动已排队请求 |
| `test_SetCooldownAboveCapReverts` | 超过 30 天上限拒绝，等于上限通过 |
| `test_InitializeRejectsCooldownAboveCap` | 初始化时同样受上限约束（参数校验从构造函数搬到 `initialize` 后仍在） |
| `testFuzz_UnlockBoundary` | 解锁前任意秒数一律失败、解锁后一律成功，中间无缝隙 |

### 3.4 `test/StakingRewards/EdgeCases.t.sol` — 12 条

| 用例 | 守什么 |
|---|---|
| `test_SetRewardsDurationRejectedWhileActive` | 周期未结束时不能改 duration |
| `test_SetRewardsDurationAfterFinish` | 周期结束后可改；`duration == 0` 被拒 |
| `test_InitializeRejectsZeroDuration` | 初始化时挡住 `duration == 0`（否则 notify 除法 panic） |
| `test_InitializeRejectsSameToken` | **同币部署在初始化就被拒**。守的是那个洞：两币相同会让 `available = balance - totalOwed` 混进用户本金，manager 就能把本金当奖励许诺出去 |
| `test_InitializeRejectsZeroToken` | 两个代币地址分别置零都拒（原来这条判断存在但没用例） |
| `test_RecoverERC20RefusesBothPoolTokens` | `stakingToken` / `rewardToken` 都不可回收 |
| `test_RecoverERC20ReturnsForeignTokenToCaller` | 外来代币可救回，转给调用者 |
| `test_RewardPerTokenFrozenWhenEmpty` | 空池时 `rewardPerToken() == 0` |
| `test_EarnedZeroForUnseenAccount` | 从未质押的地址 `earned == 0` |
| `testFuzz_NeverWithdrawMoreThanStaked` | 任意金额/时长下顶格提取后钱包精确回到存入前（先记 `walletBefore`，不写死理想值） |
| `testFuzz_EarnedNeverExceedsBudget` | `earned ≤ RATE × DURATION`，且与 `RATE × t` 相对误差 1e-8 |
| `testFuzz_SolventAlways` | 余额 ≥ `earned`。**强度有限**：余额恒为 `FUND`，实际等价于上一条，抓不到负债口径（注释已写明，那类风险归 `invariant_RewardLiabilityWithinBalance`） |

### 3.5 `test/StakingRewards/Limits.t.sol` — 3 条

| 用例 | 守什么 |
|---|---|
| `test_RefusesRewardTokenEvenWithHugeSurplus` | V1 对 `rewardToken` 是死禁令，哪怕有明显盈余也取不回 |
| `test_HasNoLiveDebtViews` | V1 没有 `totalOwedLive` / `solvencyRatio` / `version` |
| `test_HasNoExitDuringCooldown` | V1 没有 `emergencyWithdraw`，冷却期内只能干等 |

> 这三条在 V1 上**永远绿**，断言的是「能力缺失」。它们的意义在于与 `StakingRewardsV2/` 对着看，
> 构成「发现问题 → 升级修复」的闭环。若哪天这些能力下放回 V1，这里会变红——那是提醒更新文档。

### 3.6 `test/StakingRewards/Pause.t.sol` — 17 条

| 用例 | 守什么 |
|---|---|
| `test_PauseBlocksStake` | `pause` 后 `stake` 报 `EnforcedPause` |
| `test_PauseEmitsEvent` | `pause` 发出 `Paused(guardian)` 事件 |
| `test_UnpauseRestoresStake` | 恢复后 `stake` 可用 |
| `test_PauseAllowsRequestUnstake` | 暂停期间仍可发起解押 |
| `test_PauseAllowsWithdraw` | **暂停的手伸不到本金**：冷却结束后照提 |
| `test_PauseAllowsGetReward` | 暂停存入不影响领奖 |
| `test_PauseAllowsExit` | `exit` 两步都不受暂停影响 |
| `test_PauseDoesNotStopAccrual` | 暂停只挡新资金，仓内照常计息 |
| `test_PauseClaimBlocksGetReward` | 停发奖励后 `getReward` 报 `ClaimIsPaused` |
| `test_PauseClaimDoesNotBlockWithdraw` | **停发奖励的手伸不到本金** |
| `test_PauseClaimDoesNotBlockRequestUnstake` | 停发奖励不影响发起解押 |
| `test_ExitSkipsRewardWhenClaimPaused` | 停奖期间 `exit` 不 revert、跳过领奖、奖励留在账上 |
| `test_RewardAccruesWhileClaimPausedAndPaidAfterUnpause` | 停奖期间照常累积，恢复后一次补齐 |
| `test_PauseClaimTwiceReverts` | 重复暂停复用 `EnforcedPause` |
| `test_UnpauseClaimWhenActiveReverts` | 未暂停时恢复报 `ExpectedPause` |
| `test_PauseClaimEmitsEvent` | 停奖/恢复各自发事件 |
| `test_BothSwitchesAreIndependent` | 恢复存入不会顺手恢复发奖 |

### 3.7 `test/StakingRewards/Rewards.t.sol` — 15 条

| 用例 | 守什么 |
|---|---|
| `test_SetupSanity` | 基座摆置正确：rate / periodFinish / 初始空池 |
| `test_SingleStakerAccruesLinearly` | 单人不进出时严格线性；质押当秒无收益 |
| `test_TwoStakersSplitEvenly` | 等额两人对半，且之和等于产出 |
| `test_JoinLateGetsNoBackpay` | 后入场者拿不到入场前的产出 |
| `test_EmptyPoolAccrualFrozen_RewardsStranded` | 空池期不累积，那段奖励滞留合约、不补发 |
| `test_RewardPerTokenFrozenAfterPoolEmptied` | **区分「按公式不累积」与「短路返回常量」**：池子清空后累计值不再变化 |
| `test_EarnedStopsAtPeriodFinish` | 周期结束后 `earned` 与 `rewardPerToken` 都冻结 |
| `test_NotifyMidPeriodMergesLeftover` | 周期中续投：周期重置，新周期产出 = leftover + 新注入 |
| `test_NotifyAfterPeriodFinishStartsFreshCycle` | 周期已过走「从头开始」分支，rate 回到干净值 |
| `test_NotifyRevertsIfNotFunded` | 余额撑不住整期时拒绝（只断言错误类型，不抄公式） |
| `test_NotifyCannotCountOwedRewardsAsBudget` | **已结算未领取的奖励不能当新额度**（先 stake 1 wei 造出挂账前提） |
| `test_NotifyCannotCountAccruedRewardsAsBudget` | **全程无结算时，未结算应计也算负债**；后半段补足欠款后同一调用必须通过 |
| `test_GetRewardTransfersAndClears` | 领取转账、清账、同一时刻二次领取不重复付 |
| `test_GetRewardClearsLiability` | **领取必须销减负债**：先断言 `totalOwed > 0`（防退化），领取后精确归零，再领一次仍为 0 |
| `testFuzz_Conservation` | 任意质押比例与时长下，两人收益之和 = `RATE × t`（相对误差 1e-8） |

### 3.8 `test/StakingRewards/RoleHandover.t.sol` — 7 条

| 用例 | 守什么 |
|---|---|
| `test_HandoverGrantsThenRenounces` | 正确顺序移交：新人拿到、旧人失去，且新人能刹车、旧人不能 |
| `test_NewGuardianStillCannotFreezeExits` | **换守卫也不许冻结退出**（用带冷却基座，必须真调 `withdraw`） |
| `test_MultisigInheritsRecoveryPower` | 多签接管后可回收误转代币 |
| `test_GuardianHandoverIsReversibleWhileAdminHeld` | 只拆守卫是「软拆分」：握着 ADMIN 随时能拿回 |
| `test_AdminHandoverIsIrreversible` | ADMIN 移交后部署者真的出局，多签继续治理 |
| `test_RenouncingAdminWithoutSuccessorLocksGovernanceForever` | 无继承人放弃 ADMIN → 治理永久锁死，**但资金面不受影响** |
| `test_RenounceRequiresSelfConfirmation` | 不能替别人放弃角色（`AccessControlBadConfirmation`） |

### 3.9 `test/StakingRewards/Staking.t.sol` — 12 条

| 用例 | 守什么 |
|---|---|
| `test_StakeUpdatesAccounting` | 质押后四处数字同步：`totalSupply` / `balanceOf` / 钱包 / 合约余额 |
| `test_DonationDoesNotInflateAccounting` | 直转 stakingToken 不改变记账（不能用 `balanceOf` 当 `totalSupply`） |
| `test_ZeroCooldownTransfersImmediately` | 零冷却时提取退化为单笔，不产生挂起请求 |
| `test_ZeroCooldownWithdrawReverts` | 本金已到账后再调 `withdraw` 报 `NothingToWithdraw` |
| `test_StakeZeroReverts` | 存 0 被拒 |
| `test_RequestUnstakeZeroReverts` | 解押 0 被拒 |
| `test_RequestUnstakeMoreThanBalanceReverts` | 超额解押报 `InsufficientBalance(200e18, 100e18)` |
| `test_WithdrawWithoutRequestReverts` | 从未发起解押直接提取被拒 |
| `test_MinStakeEnforced` | 低于下限被拒、等于下限通过 |
| `test_MinStakeDoesNotRetroact` | 调高下限不影响已有仓位；单次追加仍受限；提取不受限 |
| `test_ExitClearsEverything` | 零冷却下 `exit` 一笔完成：份额清零、本金与奖励都到账 |
| `test_ExitWithZeroRewardDoesNotRevert` | `rewards` 为 0 时 `exit` 不 revert（调用者仍有仓位） |

### 3.10 `test/StakingRewards/Upgrade.t.sol` — 14 条

| 用例 | 守什么 |
|---|---|
| `test_ProxyPointsToImplementation` | 代理存的实现地址正确，业务状态读的是代理自己的存储 |
| `test_ImplementationCannotBeInitializedDirectly` | 实现合约不能直接被初始化（`_disableInitializers`） |
| `test_ProxyCannotBeInitializedTwice` | 代理不能二次初始化 |
| `test_UpgradeOnImplementationReverts` | 直接对实现调升级被拒（`onlyProxy`） |
| `test_ProxiableUUIDRevertsThroughProxy` | 代理上下文里读 `proxiableUUID` 必须拒 |
| `test_NonUpgraderCannotUpgrade` | 外人不能升级 |
| `test_ManagerAndGuardianCannotUpgrade` | manager 与 guardian 都不能升级（升级权独立） |
| `test_UpgraderCanUpgrade` | UPGRADER 能升级并发 `Upgraded` 事件 |
| `test_RenouncedUpgraderCannotUpgrade` | 放弃升级权后真的升不了，新 upgrader 接管 |
| `test_UpgradePreservesAllState` | 升级后仓位 / 总量 / `earned` / rate / `periodFinish` / `totalOwed` / 角色全不变 |
| `test_UpgradePreservesPauseState` | 暂停标记跨升级保留（否则一次升级会悄悄恢复闸门） |
| `test_UpgradeKeepsBusinessLogicWorking` | 升级后旧逻辑照常：本金该退还是退 |
| `test_V2NewFunctionWorks` | 新实现的新函数能读到旧状态 |
| `test_UpgradeToNonContractReverts` | 指向无代码地址时失败，代理不变砖、状态不变。**用裸 `expectRevert()`**，注释已写明「只验失败、不验原因」——这条路径上编译器的 extcodesize 检查无 selector 可断言，可追溯性靠后面两条状态断言 |

### 3.11 `test/StakingRewardsETH/Access.t.sol` — 9 条

| 用例 | 守什么 |
|---|---|
| `test_DeployerHoldsAllRoles` | 部署者持有三个角色 |
| `test_OutsidersHaveNoRoles` | 普通用户无角色 |
| `test_AllGovernanceFunctionsRejectOutsider` | 表驱动 **10 个**入口拒绝外人，断言到 `AccessControlUnauthorizedAccount` selector（含 `unpause`，本轮补入） |
| `test_RecoverETHRejectsOutsider` | `recoverETH` 单独再验一次（它是能掏空池子的函数） |
| `test_UnpauseRejectsOutsider` | **先 `pause()` 再让外人恢复**：断言失败原因是权限而不是 `ExpectedPause`，并断言闸门仍关着 |
| `test_ManagerCannotTouchAdminOnlyFunctions` | manager 能改最小质押额，动不了冷却与 ETH 余量 |
| `test_GuardianCannotChangeRewardParams` | guardian 能拉闸，改不了参数、动不了钱 |
| `test_GrantAndRevokeRoundTrip` | 授权 → 可用 → 撤销 → 不可用 |
| `test_ManagerCannotGrantRoles` | manager 不能自我复制 ADMIN |

### 3.12 `test/StakingRewardsETH/Cooldown.t.sol` — 11 条

| 用例 | 守什么 |
|---|---|
| `test_WithdrawOneSecondBeforeUnlockReverts` | 解锁前 1 秒拒绝，且 `totalPending` 未动 |
| `test_WithdrawAtUnlockSucceeds` | 解锁时刻通过，请求清空 |
| `test_SecondRequestExtendsUnlock` | 金额与 `totalPending` 同步累加，解锁时间取较晚 |
| `test_LoweringCooldownDoesNotUnlockOldAmountEarly` | 调低冷却不能给老额度「打折」 |
| `test_RequestSettlesRewardUpToThatMoment` | 发起时结清奖励，冷却期不再累积 |
| `test_CooldownChangeDoesNotAffectPending` | 改冷却不动已排队请求 |
| `test_SetCooldownAboveCapReverts` | 超上限拒绝，等于上限通过 |
| `test_ConstructorRejectsCooldownAboveCap` | 部署时就不能乱填冷却 |
| `test_ConstructorRejectsZeroDuration` | 部署时 `duration == 0` 被拒 |
| `test_ConstructorRejectsZeroRewardToken` | 部署时奖励币为零地址被拒。ETH 池没有升级通路，部署错就永久错 |
| `testFuzz_UnlockBoundary` | 任意金额与等待时长下边界无缝隙 |

### 3.13 `test/StakingRewardsETH/Pause.t.sol` — 16 条

| 用例 | 守什么 |
|---|---|
| `test_PauseBlocksStake` | 暂停后 `stake{value}` 报 `EnforcedPause` |
| `test_UnpauseRestoresStake` | 恢复后可存 |
| `test_PauseTwiceReverts` | 重复暂停被拒 |
| `test_PauseAllowsRequestUnstake` | 暂停期间可发起解押，`totalPending` 正确 |
| `test_PauseAllowsWithdraw` | **暂停的手伸不到本金** |
| `test_PauseAllowsGetReward` | 暂停存入不影响领奖 |
| `test_PauseAllowsExit` | `exit` 不受暂停影响 |
| `test_PauseDoesNotStopAccrual` | 暂停期间照常计息 |
| `test_PauseClaimBlocksGetReward` | 停奖后 `getReward` 报 `ClaimIsPaused` |
| `test_PauseClaimDoesNotBlockWithdraw` | **停奖的手伸不到本金** |
| `test_PauseClaimDoesNotBlockRequestUnstake` | 停奖不影响发起解押 |
| `test_ExitSkipsRewardWhenClaimPaused` | 停奖期间 `exit` 跳过领奖、奖励留账 |
| `test_RewardAccruesWhileClaimPausedAndPaidAfterUnpause` | 停奖期间累积，恢复后补齐 |
| `test_PauseClaimTwiceReverts` | 重复停奖被拒 |
| `test_UnpauseClaimWhenActiveReverts` | 未停奖时恢复被拒 |
| `test_BothSwitchesAreIndependent` | 两个开关互不牵连 |

### 3.14 `test/StakingRewardsETH/Recover.t.sol` — 9 条

| 用例 | 守什么 |
|---|---|
| `test_RecoverETHTakesOnlySurplus` | 误转的 ETH 可取，用户本金不动 |
| `test_RecoverETHCannotTouchCoolingPrincipal` | **冷却中的本金一分不能取**（靠 `totalPending` 记账，不是靠禁令） |
| `test_RecoverETHRevertsWhenBalanceEqualsOwed` | 恰好打平时拒绝，而不是「成功转 0」 |
| `test_RecoverETHSeparatesAllThreePots` | 计息本金 + 冷却本金 + 误转三者分开，只有误转可动 |
| `test_RecoverETHIsNotRepeatable` | 取过一次后第二次必须因「没余量」失败 |
| `test_RecoverERC20RefusesRewardToken` | 奖励币不可回收（ETH 池还没有 V2 的「只取盈余」策略） |
| `test_RecoverERC20ReturnsForeignTokenToCaller` | 外来代币可救回 |
| `test_ReceiveRecordsDonationAsSurplus` | **真发一笔带 value、空 calldata 的转账**，走的是 `receive()` 而不是 `vm.deal`。断言 `held` 涨、`owed` 不动、`surplus` 等于捐款额，且 `recoverETH` 只能取走这部分 |
| `test_DonationDuringCooldownStaysOutOfPrincipal` | 冷却中的本金 + 误转并存时，误转不被算进本金、本金一分不能动 |

### 3.15 `test/StakingRewardsETH/Reentrancy.t.sol` — 5 条

| 用例 | 守什么 |
|---|---|
| `test_ReentrantWithdrawCannotDrainPool` | 重入拿到的钱不超过自己本金，别人的本金不动（前提齐备：池里有别人的钱 + 攻击合约吞掉失败） |
| `test_SameReceiverWithdrawsNormallyWhenNotAttacking` | **对照实验**：同一合约不攻击时能正常取钱，证明上一条的失败是重入造成的 |
| `test_ContractWalletCanReceive` | 正常合约钱包（`receive` 不重入）能收款 |
| `test_RejectingReceiverBlocksWithdraw` | 拒收方让转账失败（push 模式的固有代价，错误为 `ETHTransferFailed`） |
| `test_RejectingReceiverDoesNotAffectOthers` | 拒收只影响自己，本金留在 pending，别人照常退出 |

### 3.16 `test/StakingRewardsETH/Rewards.t.sol` — 15 条

| 用例 | 守什么 |
|---|---|
| `test_SetupSanity` | 基座摆置正确（注意 rate 是整除后的值） |
| `test_SingleStakerAccruesLinearly` | 单人线性累积 |
| `test_TwoStakersSplitEvenly` | 等额对半，和等于产出 |
| `test_JoinLateGetsNoBackpay` | 后入场者无补发 |
| `test_EmptyPoolAccrualFrozen_RewardsStranded` | 空池不累积，一天奖励滞留 |
| `test_EarnedStopsAtPeriodFinish` | 周期结束即冻结 |
| `test_NotifyMidPeriodMergesLeftover` | 续投合并 leftover，周期重置 |
| `test_NotifyRevertsIfNotFunded` | 余额撑不住两期时拒绝 |
| `test_NotifyCannotCountOwedRewardsAsBudget` | **已结算未领取的奖励不能当新额度**（本轮补入） |
| `test_NotifyCannotCountAccruedRewardsAsBudget` | **全程无结算时未结算应计也算负债**；后半段补足欠款后同一调用必须通过（本轮补入） |
| `test_GetRewardTransfersAndClears` | 领取转账、清账、不重复付 |
| `test_GetRewardClearsLiability` | **领取必须销减负债**：先断言 `totalOwed > 0`，领取后归零，再领一次仍为 0（本轮补入） |
| `test_SetRewardsDurationRejectedWhileActive` | 周期未结束不能改 duration |
| `test_SetRewardsDurationAfterFinish` | 周期结束后可改，`0` 被拒 |
| `testFuzz_Conservation` | 两人收益之和 = `rate × t`（相对误差 1e-8） |

### 3.17 `test/StakingRewardsETH/Staking.t.sol` — 17 条

| 用例 | 守什么 |
|---|---|
| `test_StakeMovesETHIntoContract` | 仓位、总量、合约余额、钱包四者同步 |
| `test_StakeZeroReverts` | `msg.value == 0` 被拒 |
| `test_StakeBelowMinimumReverts` | 低于最小质押额被拒 |
| `test_StakeAtMinimumAccepted` | 边界 `>=` 通过 |
| `test_DonationDoesNotInflateAccounting` | 直转 ETH 不污染记账，`ethAccounting()` 分成 held / owed / surplus |
| `test_RequestUnstakeMovesToPending` | 份额扣除、`totalPending` 记上、ETH 仍在合约里 |
| `test_PartialRequestKeepsRestStaked` | 部分解押时剩余仓位继续计息 |
| `test_RequestUnstakeMoreThanBalanceReverts` | 超额解押被拒 |
| `test_WithdrawAfterUnlockReturnsExactETH` | 解锁后金额到 wei 不差，`totalPending` 归零 |
| `test_WithdrawTwiceReverts` | 第二次报 `NothingToWithdraw` |
| `test_ZeroCooldownReturnsPrincipalImmediately` | 零冷却当场退还，不产生 pending |
| `test_ZeroCooldownWithdrawReverts` | 零冷却下 `withdraw` 无东西可取 |
| `test_ExitLeavesPrincipalPending` | 冷却模式下 `exit` 只完成一半 |
| `test_ExitClearsEverythingWhenNoCooldown` | 零冷却下 `exit` 一笔完成 |
| `test_ExitWithZeroRewardDoesNotRevert` | `rewards` 为 0 时 `exit` 不 revert（调用者仍有仓位） |
| `testFuzz_ContractSolvent` | 任意金额下 `held ≥ owed`，且 `owed == 质押额` |
| `testFuzz_WithdrawLeavesNothingBehind` | 提取后 `held == owed == 0` |

### 3.18 `test/StakingRewardsV2/Behaviour.t.sol` — 21 条

| 用例 | 守什么 |
|---|---|
| `test_VersionIsTwo` | `version()` 返回 2，代理已指向 V2 |
| `test_SolvencyRatioIsMaxWhenNoDebt` | 负债为 0 时返回 `type(uint256).max`，不是 0（前端必须分开处理） |
| `test_SolvencyRatioDropsToOneAtPeriodEnd` | 注资恰好覆盖整期时，偿付率到期末降到 1.0 |
| `test_TotalOwedLiveIncludesUnsettledAccrual` | 实时负债要把「未入账的应计」算进去，补 V1 惰性量的缺口 |
| `test_RecoverRewardTokenTakesOnlyTheExtra` | 额外注资可回收；回收后再取 1 wei 被拒 |
| `test_RecoverRewardTokenRejectsOneWeiOverAvailable` | 多取 1 wei 即拒，报错里的 `available` 精确等于额外注资额 |
| `test_MidPeriodBudgetIsLocked` | **本合约最关键一条**：周期跑到第 2 天时，剩下 5 天的预算已许诺，取不走 |
| `test_StrandedRewardsRecoverableAfterEmptyPeriod` | 整期空池的滞留奖励现在有出口了（V1 里永远取不出） |
| `test_RecoverRewardTokenWhenInsolventRevertsCleanly` | 余额 < 负债时报可读错误，而不是减法下溢成 Panic |
| `test_RecoverStillRefusesStakingToken` | `stakingToken` 依旧完全禁止 |
| `test_EmergencyWithdrawIgnoresCooldown` | 冷却期内本金全额退回，奖励主动放弃且负债同步销账 |
| `test_EmergencyWithdrawFromActivePosition` | 活跃仓位也能直接紧急退出，不必先 `requestUnstake` |
| `test_ForfeitedRewardBecomesRecoverableSurplus` | 放弃的奖励转为可回收盈余（不销账的话会长期显示偿付不足） |
| `test_EmergencyWithdrawWorksWhenBothGatesClosed` | 两个闸门都拉下时本金仍退得出（退的是本金，不是奖励） |
| `test_EmergencyWithdrawRevertsWhenNothingToTake` | 无可退内容时报 `NothingToEmergencyWithdraw` |
| `test_EmergencyWithdrawCannotBeRepeated` | 清空后再来一次报错，而不是「成功转 0」 |
| `test_EmergencyWithdrawDoesNotDisturbOthers` | 一人紧急退出不影响他人应计，之后该人独享全速 |
| `test_StakeAndWithdrawStillWork` | V1 的存取路径在 V2 上不变 |
| `test_RewardAccrualStillLinear` | 累积曲线不因升级改变 |
| `test_NotifyStillRefusesUnfundedReward` | V2 上预算保护仍在 |
| `test_RolesSurviveUpgrade` | 三个角色跨升级保留 |

### 3.19 `test/StakingRewardsV2/Upgrade.t.sol` — 6 条

| 用例 | 守什么 |
|---|---|
| `test_UpgradeKeepsEveryItem` | **20 项状态快照逐项比对**（奖励曲线 4 / 本金负债 3 / 参数 3 / 地址 2 / 闸门 2 / 角色 4 / 冷却本金 2） |
| `test_V1HasNoVersionBeforeUpgrade` | 升级前读 `version()` 失败且返回空数据——「还没升」的机器可判定形式 |
| `test_PendingPrincipalSurvivesUpgrade` | 冷却中的本金跨升级后仍取得出（比只读 `pendingUnstake` 更强） |
| `test_UnclaimedRewardSurvivesUpgrade` | 已计提未领取的奖励跨升级金额一分不差 |
| `test_AccrualContinuesAfterUpgrade` | 升级后按原速率继续累积，不重算曲线 |
| `test_OnlyUpgraderCanUpgrade` | manager 与 guardian 升级不了，代理仍指向 V1 |

### 3.20 `test/StakingRewardsETH/RoleHandover.t.sol` — 6 条（本轮新增文件）

| 用例 | 守什么 |
|---|---|
| `test_HandoverGrantsThenRenounces` | 先 grant 再 renounce 的完整移交：新人拿到、旧人失去，新人能刹车、旧人不能 |
| `test_NewGuardianStillCannotFreezeExits` | 新守卫换上来也不许冻结退出（暂停期间仍能 `withdraw`） |
| `test_AdminHandoverIsIrreversible` | ADMIN 移交后部署者真的出局，多签继续治理 |
| `test_MultisigInheritsRecoveryPower` | 多签接管后可回收误转的 ERC20 |
| `test_RenouncingAdminWithoutSuccessorLocksGovernanceForever` | **无继承人放弃 ADMIN → 治理永久锁死，但用户本金与奖励仍取得到**（这是整个文件存在的理由） |
| `test_RenounceRequiresSelfConfirmation` | 不能替别人放弃角色（`AccessControlBadConfirmation`） |

### 3.21 `test/StakingRewards/Invariants.t.sol` — 5 条（新增文件）

含一个 handler（`ERC20PoolHandler`，`stake` / `requestUnstake` / `withdraw` / `getReward` / `exit` /
`warp` / `notify` / **`setCooldown`**，全部 try/catch 吞掉合法失败），外加一本**影子账本**
`_expectedUnlock`：每次发起解押时按「当时的冷却」记下解锁时间下限，供不变量比对。

| 用例 | 守什么 |
|---|---|
| `invariant_PrincipalFullyBacked` | **等式**：`stakingToken.balanceOf(staking) == totalSupply + Σ pendingUnstake(actor)`。handler 从不直转，所以必须是等号 |
| `invariant_RewardLiabilityWithinBalance` | 双向夹逼：`Σ rewards[actor] ≤ totalOwed + 1e6` 且 `totalOwed ≤ rewardToken.balanceOf(staking)`。左侧留 1e6 是因为 `totalOwed` 在结算边界 floor、逐户 `rewards` 各自 floor，两次 floor 之和可能比一次少 1 wei |
| `invariant_UnlockTimeNeverShortened` | 挂起的解锁时间**永不早于影子账本记下的下限**。这是第一条覆盖「治理动作 × 用户操作」交叉的不变量：冷却可以在序列中途被改短，已挂起的额度按请求发生时的冷却算 |
| `test_HandlerReachesContract` | **夹具自检**：handler 的调用真的落到合约上。没有这一条，一次「全部调用都失败」的 handler 会让不变量在空状态上平凡成立 |
| `test_CooldownChangeReachesContractAndShadowTracks` | **夹具自检（影子账本专用）**：先按 30 天发起、再把冷却改到 0，解锁时间必须停在原处。没有这一条，`setCooldown` 一次都没生效时上面那条不变量会平凡成立 |

### 3.22 `test/StakingRewardsETH/Invariants.t.sol` — 5 条（新增文件）

含一个 handler（`ETHPoolHandler`，同构，但不给 `staking` 直接 `vm.deal`——否则等式会被 handler 自己打破）。

| 用例 | 守什么 |
|---|---|
| `invariant_ETHFullyBacked` | **等式**：`address(staking).balance == totalSupply + totalPending`。这条同时给 `recoverETH` 的上限提供了序列级证据 |
| `invariant_RewardLiabilityWithinBalance` | 双向夹逼，与 ERC20 池同口径：`Σ rewards[actor] ≤ totalOwed + 1e6` 且 `totalOwed ≤ rewardToken.balanceOf(staking)`。下界防「负债少记」，上界防「欠的奖励比手上的币还多」 |
| `invariant_UnlockTimeNeverShortened` | 与 ERC20 池同一条口径：解锁时间永不早于影子账本的下限。ETH 池的冷却上限也是 30 天，改短冷却同样不能把老额度提前放出来 |
| `test_HandlerReachesContract` | 夹具自检：stake 真的进了 ETH、requestUnstake 真的记了 pending |
| `test_CooldownChangeReachesContractAndShadowTracks` | 影子账本自检，同上 |

### 3.23 `test/StakingRewards/Reentrancy.t.sol` — 5 条（新增文件，2026-11-17）

ERC20 池的重入证据。ETH 池靠恶意接收方的 `receive()` 触发，这里靠**会回调的代币**：
`stake` 走 `transferFrom`、`withdraw` / `getReward` 走 `safeTransfer`，两处都把控制权交给代币合约。

每条攻击用例断言两件事——**重入失败，且失败原因是 `ReentrancyGuardReentrantCall`**。
只断言「没成功」是不够的：同样「没成功」，可能是被守卫挡住，也可能只是额度不足，后者说明防线压根没被触发。

| 用例 | 守什么 |
|---|---|
| `test_ReentrantStakeIsBlockedAndCreditedOnce` | `transferFrom` 回调里重入 `stake`：被守卫挡住，仓位只记一次（不出双份） |
| `test_ReentrantGetRewardCannotDoublePay` | `safeTransfer` 回调里重入 `getReward`：只付一次，金额等于调用前的 `earned` |
| `test_ReentrantUnstakeCannotDrainOtherPrincipal` | 池里有 alice 的 100e18，bob 提取时重入 `withdraw()`：bob 只拿到自己的 10e18，alice 本金一分未动 |
| `test_ReentrantExitIsBlocked` | `exit()` 自身没有 `nonReentrant`，但它内部调用的 `requestUnstake` 有——复合入口同样挡住 |
| `test_SameTokensWorkNormallyWhenNotAttacking` | 对照实验：同一个会回调的代币、关掉攻击开关，存取与领奖全部正常 |

对照用例不是凑数：没有它，前四条都可能「因为这个代币本身就转不动」而假绿。

---

## 4. 验证方式

每个注入点走同一套流程：改 `src/` → 跑指定套件 → 还原 → 哈希比对 → 全量 `0 failed`。

判据只有一条：**定向**。目标用例必须红，相邻用例必须绿。整片红说明打到的是「函数坏了」
而不是目标口径，等于空验证。

工具：`D:\workbuddy\tools\mutate.py`（`snapshot` / `inject` / `restore` / `check`）。
`inject` 会断言目标文本恰好出现一次，防止误伤同名的第二处。

---

## 5. 变异结果：28 个注入，全部被抓

判据只有一条：**定向**。目标用例必须红，相邻用例必须绿。整片红说明打到的是「函数坏了」
而不是目标口径，等于空验证。

| # | 注入的错误 | 216 基线 | 242 现在 | 由谁抓 |
|---|---|---|---|---|
| 1 | ETH `available` 去掉 `- totalOwed` | 全绿 | 红 2 ✓ | `ETHRewards::test_NotifyCannotCountOwed…` / `…Accrued…` |
| 2 | ETH 去掉 `unpause` 的 `onlyRole` | 全绿 | 红 2 ✓ | `ETHAccess::test_AllGovernanceFunctions…` / `test_UnpauseRejectsOutsider` |
| 3 | V1 去掉 `getReward` 的 `totalOwed -= reward` | 全绿 | 红 1 ✓ | `Rewards::test_GetRewardClearsLiability` |
| 4 | ETH 去掉同一行 | 全绿 | 红 1 ✓ | `ETHRewards::test_GetRewardClearsLiability` |
| 5 | ETH 去掉 `totalPending += amount` | 红 25 | 红 25 ✓ | ETH 全组交叉守（`Staking` / `Cooldown` / `Pause` / `Recover` / `Reentrancy`） |
| 6 | ETH `recoverETH` 的 `owed` 漏 `totalPending` | 红 2 | 红 2 ✓ | `test_RecoverETHCannotTouchCoolingPrincipal`、`test_RecoverETHSeparatesAllThreePots` |
| 7 | V2 `locked` 去掉 `committed` | 红 4 | 红 4 ✓ | `test_MidPeriodBudgetIsLocked`、`test_RecoverRewardTokenTakesOnlyTheExtra`、`test_RecoverRewardTokenRejectsOneWeiOverAvailable`、`test_ForfeitedRewardBecomesRecoverableSurplus` |
| 8 | V2 `emergencyWithdraw` 不删 `rewards` | 红 1 | 红 1 ✓ | `test_EmergencyWithdrawIgnoresCooldown` |
| 9 | V2 `emergencyWithdraw` 不清 `pendingUnstake` | 红 1 | 红 1 ✓ | 同上 |
| 10 | V1 `stake` 去掉 `whenNotPaused` | 红 1 | 红 1 ✓ | `test_PauseBlocksStake` |
| 11 | V1 `withdraw` 挂 `whenNotPaused` | 红 2 | 红 2 ✓ | `test_PauseAllowsWithdraw`、`test_NewGuardianStillCannotFreezeExits` |
| 12 | V1 删掉解锁时间取最晚 | 红 1 | 红 1 ✓ | `test_LoweringCooldownDoesNotUnlockOldAmountEarly`（差 29 天） |
| 13 | V1 结算不入账负债 | 红 3 | 红 3 ✓ | `Rewards` 三处交叉 |
| 14 | V2 `PRECISION_V2` 1e18 → 1e17 | 红 1 | 红 1 ✓ | `test_TotalOwedLiveIncludesUnsettledAccrual` |
| 15 | ETH `getReward` 误挂 `onlyRole` | 红 9 | 红 9 ✓ | 含 `ETHRoleHandover::test_RenouncingAdminWithoutSuccessor…` |
| 16 | V1 `requestUnstake` 删掉 `totalSupply -= amount` | 未做 | 红 1 ✓ | **仅靠** `invariant_PrincipalFullyBacked`（余额比记账少 3 wei） |
| 17 | V1 `_updateReward` 的 `totalOwed` 计算除以 2 | 未做 | 红 1 ✓ | **仅靠** `invariant_RewardLiabilityWithinBalance`（挂账 9.49e21 > 负债 5.99e21） |
| 18 | ETH `requestUnstake` 删掉 `totalPending += amount` | 未做 | 红 2 ✓ | `invariant_ETHFullyBacked` + `test_HandlerReachesContract` |
| 19 | ETH `totalOwed +=` 除以 2（负债少记） | 未做 | 红 1 ✓ | **仅靠** `invariant_RewardLiabilityWithinBalance`（挂账 2.86e22 > 负债 1.43e22，正好两倍） |
| 20 | ETH `totalOwed += (totalSupply * rpt)`（累加全量而非增量） | 未做 | 红 1 ✓ | 同上那条的**上界**（负债 3.5e33 > 余额 6.0e23） |
| 21 | ETH 删掉 `receive()` | 未做 | 红 2 ✓ | `test_ReceiveRecordsDonationAsSurplus`、`test_DonationDuringCooldownStaysOutOfPrincipal`；同文件另 7 条走 `vm.deal` 的仍绿 |
| 22 | V1 删掉「解锁时间取最晚」 | 红 1（仅单点） | 红 2 ✓ | **新增** `invariant_UnlockTimeNeverShortened`（`1700419125 < 1701870685`）+ 影子自检；另两条不变量仍绿 |
| 23 | ETH 删掉同一行 | 红 1（仅单点） | 红 2 ✓ | 同上的 ETH 版（`1701994840 < 1702056069`）+ 影子自检；另两条仍绿 |
| 24 | 删掉 `initialize` 里的同币拦截 | **无此判断** | 红 1 ✓ | `EdgeCases::test_InitializeRejectsSameToken`，同文件另 11 条全绿 |
| 25 | 删掉 `initialize` 里的零地址拦截 | 全绿 | 红 1 ✓ | `EdgeCases::test_InitializeRejectsZeroToken`，相邻全绿 |
| 26 | 删掉 ETH 构造函数的零地址检查 | 全绿 | 红 1 ✓ | `ETHCooldown::test_ConstructorRejectsZeroRewardToken`，相邻全绿 |
| 27 | V1 去掉 `stake` 的 `nonReentrant` | 无此用例 | 红 1 ✓ | `ERC20Reentrancy::test_ReentrantStakeIsBlockedAndCreditedOnce`；重入**没被守卫挡住**，而是被额度不足挡住（revert 选择器 `0xfb8f41b2` ≠ 守卫的 `0x3ee5aeb5`），说明这条用例区分得开「挡住了」和「碰巧失败」 |
| 28 | V1 去掉 `getReward` 的 `nonReentrant` | 无此用例 | 红 1 ✓ | `ERC20Reentrancy::test_ReentrantGetRewardCannotDoublePay`（`re-entry must fail`）；同文件对照用例保持绿，说明红的不是「代币转不动」 |

**27~28 是 §6.3 那条缺口的验收**：两条都只红目标用例、对照用例保持绿。
这两次注入也顺手证明了「守卫是唯一挡住重入的东西」——去掉它之后重入能进去，只是被别的条件拦住，
所以用例断言的失败原因必须是 `ReentrancyGuardReentrantCall`，不能只断言「失败」。

**24~26 是那次中途修动的验收**。在 2026-11-17 补入 27/28 之前的那 26 个注入里，只有这三条是打在**刚写下的新代码**上，
所以额外看了一件事：每条注入只红 1 条、同文件其余用例全绿（12 条里红 1、11 条里红 1），
说明用例是逐条对准各自那行判断的，不是靠「初始化整个坏掉」一起红。

**21~23 是本轮前 6 条新用例的验收**：21 打的是「误转是否真的走 `receive()`」，
22/23 打的是「改短冷却不能把已挂起的额度提前放出来」。22/23 值得单独说——同一次注入，
上轮的记录是「只靠单点用例抓」（红 1），现在多了不变量这一路，且**两条旧不变量保持绿**，
说明新不变量是定向的，不是碰巧跟着红。

**16~20 是状态型不变量的证据链**：它们只跑 `Invariants.t.sol`，不依赖任何单点用例。
19 与 20 分别打的是同一条夹逼不变量的下界与上界——只验一边的话，另一半永远可能是恒真的摆设。

19 的注入有个连带的观察，如实记下来：两条领取用例（`test_GetRewardTransfersAndClears`、
`test_GetRewardClearsLiability`）也红了，但红因是 `panic: arithmetic underflow`——
`totalOwed` 少记之后 `totalOwed -= reward` 直接下溢。这是**同一缺陷的第二表现**，不是另一条缺陷，
所以不算「打歪」；但它说明这条注入不是纯粹的静默口径错误，真正能「早于任何人领取就发现」的
只有那条不变量。20 就没有这个连带（负债虚高不会下溢），是更干净的一次。

19 与 5 的注入相同，但观察口径不同：5 看的是「单点用例能不能抓到」，18 看的是「只靠 invariant 够不够」。
后者更重要——单点用例只能测到作者想到的那条路径，invariant 是 fuzzer 自己拼序列。

还原方式：注入前对源文件做 sha256 快照，每次先恢复再注入，全部跑完后逐文件比对。
本轮结束时三个源文件哈希与快照一致（`c01e0ff191ea` / `c992fc74b543` / `fb720e04b404`），
`.mutbak` 已清理，全量 `242 passed, 0 failed`。

## 6. 待办（只列未完成的）

> 建议 **A ~ I 已全部闭合**：A~D 见 §5 的 1~4，E 见 16~18，G 见 19~20，H 见 21，I 见 22/23，
> F 是文案与断言收敛。上轮那条上线阻断（同币部署）已在本轮修掉并验收，不再列在这里。
> 本节剩三件，**没有一件是缺陷**，都是缺口或待拍板。
>
> **2026-11-17 更新**：§6.1 与 §6.3 均已闭合（见各自小节），§6.2 是代码风格、不影响正确性。
> 也就是说本节现在没有阻塞项。

### 6.1 已闭合（2026-11-17）：ETH 池补上了 `emergencyWithdraw`

user 拍板「要一致性」，实现落在 `src/StakingRewardsETH.sol:275`：
退 `balanceOf + pendingUnstake[user].amount`，同步 `totalSupply` / `totalPending`，奖励主动放弃并同步销账
（`totalOwed` 减去放弃的部分，于是那笔钱从「名花有主」变成可用盈余，可由 `recoverETH` 的盈余口径取回）。
无视冷却、不受 `paused` / `claimPaused` 影响。单测 7 条 + 取整差额用例 1 条。

**仍未做的**：这条路径**没在真实链上执行过**。截至 2026-11-17，ETH 池
（`0x2F8663eD…33D6`）的真实交互跑到 `requestUnstake` 为止，冷却中的 0.004 ETH 还在等解锁；
`emergencyWithdraw` 只有本地与 fork 级证据。要补的话：等解锁后 `withdraw()` 取回，再用一笔小额新仓位
（冷却期内）走一次 `emergencyWithdraw`，比现在放弃已累计的奖励划算。

> 原文记的「ETH 池缺 `emergencyWithdraw`，等 user 拍板」已过期——那段决策当时没落地，
> 后来在这份文档之外实现了。留着会误导测试窗口。

### 6.2 提示级：`forge lint` 两处 `unwrapped-modifier-logic`

`whenNotClaimPaused` 在两处被直接调用。不影响正确性，属代码风格，归编写侧。

### 6.3 已闭合（2026-11-17）：ERC20 池有重入用例了

`test/StakingRewards/Reentrancy.t.sol` 新增 5 条（清单见 §3.23），配套 mock 是
`test/StakingRewards/mocks/ReentrantERC20.sol`——一个在 `transfer` / `transferFrom` 里回调池子的代币。

验收方式（§5 的 27、28）：去掉 `stake` 或 `getReward` 的 `nonReentrant`，目标用例必须红、对照用例必须绿。
实测两处都只红 1 条。其中 27 号还暴露了一个值得记的细节：守卫被去掉后，重入**进去了**，
但被额度不足挡住（选择器 `0xfb8f41b2`），所以用例断言的是 `ReentrancyGuardReentrantCall` 这个具体原因，
而不是「调用失败」——否则这条用例会永远绿。

## 7. 覆盖盲区

> 原来那条「ETH `receive()` 未被真实触发」已经闭合（§3.14 的两条新用例 + §5 的 21 号注入），
> 「参数变更不进 invariant」也已闭合（§3.21/3.22 的 handler 现在会改冷却）。
> 剩下的都是结构性取舍。

### 7.1 没有 fork 测试

`createFork` 0 处。真实代币的 fee-on-transfer / 负向 rebase 行为未覆盖——但 README 已声明
「rewardToken 必须是标准 ERC20」，测试与声明一致，属**有意的取舍**。
要补的话最小代价是 fork 一次主网 USDC 跑一遍 stake/withdraw，验证 `safeTransfer` 的返回值处理。

### 7.2 测试方法自身的局限

- **invariant 有失败缓存，重跑前必须清**：`cache/invariant/failures/<合约>/<不变量名>` 会留下上一轮的反例。
  命中缓存时输出是 `[FAIL: invariant_XXX replay failure]`——**不是断言失败**，看不到违反的是哪条、
  差多少。本轮第一次跑 `I1` 就撞上了这个：报 `replay failure`，清掉 `cache/invariant` 之后才拿到
  `unlock time never moved earlier: 1700419125 < 1701870685`。做变异验证（以及判断一条不变量到底有没有抓到东西）
  之前一律先 `rm -rf cache/invariant`，否则结论可能是缓存噪音。Foundry 在测试合约字节码变化时会忽略旧文件，
  但同一次会话里改 `src/` 不一定触发这条判断
- **invariant 深度靠配置，不靠版本**：`foundry.toml` 第 15–17 行有 `[invariant] runs = 256` / `depth = 32`，
  实测输出 `runs: 256, calls: 8192`（8192 = 256 × 32），配置确实生效、结论可复现。
  但 `calls` 是 `runs × depth` 的乘积，**只改 `depth` 才会改变单次运行的路径长度**；
  想加深覆盖动 `depth`，想减少噪声动 `runs`，别把两者当同一个旋钮
- **时间只有单块**：`vm.warp` 能跳，但没有真实出块间隔，同一秒内多次操作靠单点用例覆盖
- **fuzz 只跑默认 256 runs**：CI 未配长跑；金额分布靠 `bound()` 收在 1 wei ~ 1e24
- **相对容差 1e-8**（两处 `assertApproxEqRel(…, 1e10)`）：可挡实现级偏差，挡不住 1e-9 的精度退化
- **无 gas 基准**（2026-11-12 补实测，对应 `AUDIT-2026-11-12` 的 F-2）：
  主网价（200 gas/字节）下 `forge test --gas-report` 的 Deployment Cost 是
  V1 `2,119,214` / V2 `2,319,814` / ETH `1,831,372`；
  Sepolia 因 EIP-8037 已把存代码改成 1,530 gas/字节，V1 约 `14,787,000`、V2 约 `16,322,000`。
  **两条链不是同一套计价，别拿一个数当全局约束**：主网的真实上限是 EIP-170 的 24,576 B（V2 还剩 14.2 KB），
  只有 Sepolia / 8037 落地后才是 10,629 B（V2 余约 297 B）。

## 8. 怎么跑

```bash
forge test                                           # 全量，末行应为 0 failed
forge test --match-contract ETHRecoverTest           # 单个套件（按合约名，基座不参与）
forge test --match-path "test/StakingRewardsETH/*"   # 整个合约目录
forge test --match-path "test/StakingRewards/Invariants.t.sol"   # 只跑状态型不变量
forge test --match-test test_MidPeriodBudgetIsLocked
forge test --fuzz-runs 5000                          # 长跑 fuzz（CI 用）
```

变异验证：

```bash
python D:/workbuddy/tools/mutate.py snapshot src/X.sol      # 建基线
python D:/workbuddy/tools/mutate.py inject src/X.sol M1 "<原文>" "<改后>"
rm -rf cache/invariant                                      # 打不变量之前必须清，见 §7.2
forge test --match-path ...
python D:/workbuddy/tools/mutate.py restore src/X.sol
python D:/workbuddy/tools/mutate.py check   src/X.sol       # 比对哈希
```

`inject` 会断言目标文本恰好出现一次，避免误伤同名的第二处。
**收尾必须删掉 `src/*.mutbak`**，否则给用户留一个脏目录。

判断一条不变量到底抓到没有，看失败信息里有没有**断言原文 + 两个具体数值**
（`unlock time never moved earlier: 1700419125 < 1701870685`）。
只有 `replay failure` 的那种，是缓存噪音，不算数，要清缓存重跑。

---

## 9. 三方开场话术

共同前提：**写的人不验，验的人不写，审的人不动手。**

### 9.1 编写对话（拥有 `src/` 和 `test/`）

> 你负责 `src/` 与 `test/`——实现和测试都由你写。**但你不能声称「测试已验证」**：
> 写测试的人和验证测试的人必须是两方，验证结论只由测试窗口出。
>
> 先读 `audit/FINDINGS.md` 的 §6（待办）和 §7（盲区）。本轮只剩三件：
> 现在没有已知缺陷，按价值排序：§6.3 给 ERC20 池平移一份重入用例
> （验收：把 `getReward` 的两行顺序对调，用例必须红）；§6.1 是等 user 拍板的产品决策，拍板前别动代码；
> §6.2 是 lint，顺手。
> 每条都写了验收标准，照那个做，别自己另定。
>
> 写用例时只对行为负责，不要在自己的注释里写「这条能抓住 XX 缺陷」——那句判断归测试窗口。
> 写完跑 `forge test` 全绿，然后把改了哪些文件告诉我。
>
> 两条硬约束：一、`StakingRewards` 的存储布局不能动（V2 只能在 `claimPaused` 与 `__gap` 之间追加，
> 并同步缩小 `__gap`）；二、`StakingRewardsETH` 的 `recoverETH` 上限
> `balance − totalSupply − totalPending` 是它唯一的安全来源，动这一行必须同时说明
> 三种钱（计息本金 / 冷却本金 / 误转）分别怎么算。

### 9.2 测试对话（只验证，不写测试、不改合约）

> 你**不写测试、不改 `src/`**，唯一能写的文件是 `audit/FINDINGS.md`。理由是制衡：
> 自己写的测试自己验，等于没验。
>
> 每轮固定四步：
> 1. 跑 `forge test` 取基线，记下套件数与条数；
> 2. 读 §1 与 §6，看上一轮的待办有没有被处理、这一轮新增了哪些用例；
> 3. 对每个新增用例做**定向变异**：注入对应错误 → 目标用例必须红、相邻用例必须绿 →
>    还原 → 哈希比对 → 再全量跑一次；
> 4. 把结果写回 §1 / §3 / §5，把已完成的从 §6 移走。
> 5. **报一次全局进度**：按 §1.1 的口径算，写进 §1 的「全局进度」行，同时在回复里报给 user。
>    数字只能因为命题状态变化而变，不能因为「这轮写得顺手」而涨。
>
> 判据只有一条：**定向**。整片红的注入说明打歪了（打到「函数坏了」而不是目标口径），要重新设计。
> 发现假绿不要自己补，写进 §6；发现实现缺陷不要自己改，也写进 §6，单列一条并在 §1 点出来。
> 连带红的要区分「同一缺陷的第二表现」和「另一条缺陷」——前者如实注明，别当成打歪。
>
> 报告里只写三样：守着什么、怎么验的、哪里没守。不写「谁改没改」，也不替任何一方美化结论。

### 9.3 审计对话（只读，最后把关）

> 你只读，不改任何文件。`src/`、`test/`、`audit/` 都别动，结论写在你的输出里，由 user 转交。
>
> 先读 `audit/FINDINGS.md`：§3 是逐条用例清单（每个行为由哪条用例守），§5 是 28 个注入的验证结果，
> §6 是仍未处理的待办，§7 是盲区。**不要重复验证 §5 已经覆盖的内容**，省下的力气放在三处：
>
> 一、**把关覆盖的完整性，而不是重复验证**：两个池现在各有「本金等式」+「奖励负债夹逼」两条不变量，
> 上下界都注入打红过，冷却变更也进了序列。要看的是**还没进不变量的那部分**——
> 回收上限（`recover*` 全套）仍然只有单点用例，没有任何不变量在序列里跑过它们；
> 以及**部署期参数校验**这一类：初始化把同币/零地址挡住了，但 `setRewardsDuration`、
> `setMinStakeAmount` 这些运行期参数在序列里的组合仍然只有单点用例。
> 二、§7 的盲区里有没有你认为应当升级为高危的。
> 三、需要人读、测试覆盖不了的语义边界：两级闸门的取舍、单槽 `pendingUnstake` 对用户的惩罚、
> `exit()` 静默跳过领奖是否会让用户误解、ETH 池 30 天锁定是否可接受。
>
> 输出格式固定三列：**位置 → 风险 → 凭什么说这是风险**。没有第三条的就不要写；
> 「建议补测试」不算风险，那是编写窗口的活。
