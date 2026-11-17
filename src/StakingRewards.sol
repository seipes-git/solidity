// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title StakingRewards —— 单池质押挖矿（UUPS 可升级版本）
/// @notice 用户质押 stakingToken，按「每秒恒定释放」的方式线性瓜分 rewardToken。
///         奖励速率由 REWARDS_MANAGER_ROLE 用 notifyRewardAmount 注入，一个周期内 rewardRate 不变。
/// @dev 边界：单池、单奖励币、不支持 ETH 原生质押（ETH 走独立合约）。
///
///      升级权单独成一个角色：它能替换全部逻辑，包括「钱怎么算」，所以不能和改参数的
///      REWARDS_MANAGER_ROLE 合并。生产环境应交给时间锁或多签，给用户留出退出窗口。
///
///      暂停只冻入口不冻出口：pause 只挂 stake，解押 / 提取 / 领奖永远可用。
///
///      存储布局：下方变量顺序即 V1 布局。V2 只能在 claimPaused 之后、__gap 之前追加，
///      并相应缩短 __gap。删除、重排、改类型都会让已存数据错位，编译器不会替你检查
contract StakingRewards is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 常量
    //////////////////////////////////////////////////////////////*/

    /// @dev rewardPerToken 的定点精度。所有「每份质押累计奖励」以 1e18 为 1.0
    uint256 private constant PRECISION = 1e18;

    /// @notice 解质押冷却的上限。防止管理员把它设成一年来变相锁死用户本金
    uint256 public constant MAX_UNSTAKE_COOLDOWN = 30 days;

    /// @notice 能改奖励参数（注入、周期、最小质押额）
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");

    /// @notice 只能暂停与恢复。权限刻意比 REWARDS_MANAGER_ROLE 小：
    ///         紧急情况下的第一反应者不必同时握有改写奖励曲线的权力
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice 只能替换实现合约。这是全合约权限最大的一项：升级可以改掉任何逻辑，
    ///         包括把用户的本金转走。所以它不与上面任何角色合并
    /// @dev 注意 AccessControl 的固有性质：UPGRADER_ROLE 的管理员是 DEFAULT_ADMIN_ROLE，
    ///      所以持有 ADMIN 的人可以把任何人（包括自己）加成 UPGRADER。
    ///      要做到真正的分离，需要在 initialize 里再 `_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)`，
    ///      代价是 UPGRADER 一旦全部丢失就永久锁死升级能力
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /*//////////////////////////////////////////////////////////////
                                 状态
                          （顺序即存储布局，不可重排）
    //////////////////////////////////////////////////////////////*/

    IERC20 public stakingToken;
    IERC20 public rewardToken;

    /// @notice 单个奖励周期的长度（秒）。可在周期结束后修改
    uint256 public rewardsDuration;

    /// @notice 每秒释放多少 rewardToken（未缩放，单位与 rewardToken 的 decimals 一致）
    uint256 public rewardRate;

    /// @notice 当前周期的结束时间戳
    uint256 public periodFinish;

    /// @notice 上次结算的时间戳。与 periodFinish 一起界定「还有多久的奖励没结算」
    uint256 public lastUpdateTime;

    /// @notice 全局累计：每一份质押（1 wei）自池子诞生以来已经赚到的奖励，含 PRECISION 缩放
    uint256 public rewardPerTokenStored;

    /// @notice 池内质押总量。刻意用内部记账，不读 stakingToken.balanceOf(address(this))
    uint256 public totalSupply;

    /// @notice 单笔质押的最小金额。0 表示不限
    uint256 public minStakeAmount;

    /// @notice 发起解质押后需要等待多久才能取回本金（秒）。0 表示不冷却，单笔即可完成
    uint256 public unstakeCooldown;

    mapping(address account => uint256) public balanceOf;

    /// @notice 用户上次结算时快照的 rewardPerTokenStored
    mapping(address account => uint256) public userRewardPerTokenPaid;

    /// @notice 已结算但尚未领取的奖励
    mapping(address account => uint256) public rewards;

    /// @notice 已产生但尚未转出的奖励总额，含「已结算未领取」与「未结算应计」两部分。
    ///         rewardToken 余额里这部分已名花有主，notifyRewardAmount 必须扣掉，
    ///         否则同一笔钱会被许诺两次
    /// @dev 惰性累计量，只在 _updateReward 里入账：对外读取值停留于上次结算时点，
    ///      用户长时间不操作期间读到的负债偏低。需要实时值请逐户求和 earned()，
    ///      或先触发一次结算
    uint256 public totalOwed;

    /// @notice 解质押请求：本金已从 balanceOf 扣出，等 unlockTime 之后由 withdraw 取回
    struct UnstakeRequest {
        uint256 amount;
        uint256 unlockTime;
    }

    /// @notice 每个地址同时只有一笔挂起请求。多次发起会累加金额，解锁时间取其中最晚的
    /// @dev 单槽而非数组：数组要压缩、要遍历、要防 O(n²)，单槽把这部分复杂度换成了
    ///      「同期多次解锁按最晚时间统一放行」这一条可预期的约束
    mapping(address account => UnstakeRequest) public pendingUnstake;

    /// @notice 领取奖励的独立开关。与 Pausable 的 paused() 是两回事：
    ///         paused 挡的是「存入」，claimPaused 挡的是「发奖」。
    ///         本金提取路径（requestUnstake / withdraw）不受任何一个影响
    /// @dev 存在的理由：奖励币的流动性和用户本金是两回事。本金是协议代管、必须无条件归还；
    ///      奖励是项目方承诺，余额不足时需要有序发放而不是让先到的人把池子抢光
    bool public claimPaused;

    /// @dev V1 预留的存储槽。V2 新增变量必须插在这个 gap 之前，并同步缩小 gap。
    ///      当前已用 16 个槽（15 个变量 + bool 独占 1 个），故留 34 补足 50。
    ///      加了它不等于「可以随便加变量」——顺序仍然不能动
    uint256[34] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 事件
    //////////////////////////////////////////////////////////////*/

    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 unlockTime);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 rewardRate, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event MinStakeAmountUpdated(uint256 newMinStakeAmount);
    event UnstakeCooldownUpdated(uint256 newCooldown);
    event ClaimPaused(address indexed account);
    event ClaimUnpaused(address indexed account);
    event Recovered(address indexed token, uint256 amount);

    /// @notice 实现合约被替换。这个事件是链上唯一能事后审计「谁在什么时候换了逻辑」的凭据
    event Upgraded(address indexed implementation);

    /*//////////////////////////////////////////////////////////////
                                 错误
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error BelowMinStake(uint256 amount, uint256 minimum);
    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientRewardBalance(uint256 required, uint256 available);
    error RewardRateTooLow();
    error InvalidDuration();
    error PeriodStillActive();
    error CannotRecoverStakingToken();
    error CannotRecoverRewardToken();
    error NothingToWithdraw();
    error StillLocked(uint256 unlockTime);
    error CooldownTooLong(uint256 cooldown);
    error ClaimIsPaused();
    error InvalidToken();

    /*//////////////////////////////////////////////////////////////
                                修饰器
    //////////////////////////////////////////////////////////////*/

    /// @dev 把「从上次结算到现在」这段时间的奖励先落账，再执行函数体。
    ///      account == address(0) 时只更新全局量（用于 notifyRewardAmount / setRewardsDuration）
    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    /// @dev 只挡发奖，不挡本金（细节见 claimPaused 的注释）
    modifier whenNotClaimPaused() {
        if (claimPaused) revert ClaimIsPaused();
        _;
    }

    /// @dev 返回值是本次为 account 结算出的应发奖励，给 `getReward` 直接用，省掉一次回读
    function _updateReward(address account) internal returns (uint256 accountReward) {
        // 一次读齐，之后不再碰 storage：原写法调 `rewardPerToken()` 拿 rpt，
        // 又在 `earned()` 里第二次调它，`rewardPerTokenStored` / `totalSupply` /
        // `lastUpdateTime` / `periodFinish` 因此各被多读一遍
        uint256 supply = totalSupply;
        uint256 lastTime = lastTimeRewardApplicable();
        uint256 stored = rewardPerTokenStored;

        // 与 rewardPerToken() 逐字等价：空池期间不累积，lastUpdateTime 照样推进
        uint256 rpt = stored;
        if (supply != 0) {
            rpt += ((lastTime - lastUpdateTime) * rewardRate * PRECISION) / supply;
        }

        uint256 delta = rpt - stored;
        // delta == 0 时 rpt == stored，写回是空操作，跳过省一次 SSTORE
        if (delta > 0) {
            rewardPerTokenStored = rpt;
            // 按全局增量入账：本函数永远在余额变更之前跑，此处 totalSupply 是常量，
            // 所以它天然覆盖所有人的应计，包括从没调用过结算的人。
            // 逐边界 floor 会让「各户之和」略超这个累计值（≤ n-1 wei），
            // 领取时由 getReward 的夹逼吸收
            totalOwed += (supply * delta) / PRECISION;
        }
        lastUpdateTime = lastTime;

        if (account != address(0)) {
            // 等价于 earned(account)，但复用上面算好的 rpt，不再重算整条曲线
            accountReward = _rewardOf(account, rpt);
            rewards[account] = accountReward;
            userRewardPerTokenPaid[account] = rpt;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              构造与初始化
    //////////////////////////////////////////////////////////////*/

    /// @dev 代理模式下构造函数只在「部署实现合约」时跑一次，此时 address(this) 是实现合约，
    ///      不是用户交互的那个地址。所以这里不能写任何业务状态，只做一件事：
    ///      把实现合约自身的初始化器锁死，防止有人直接对实现合约调用 initialize 抢占 owner
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化。只能调用一次，且必须和代理部署在同一笔交易里完成
    /// @dev 分两步部署（先部署代理、再单独调 initialize）会留下抢跑窗口：
    ///      任何人看到这笔待打包的交易，都可以用更高的 gas 抢先初始化，把三个角色装到自己头上。
    ///      用 `ERC1967Proxy` 的构造函数 + initData 部署，代理创建与 initialize 天然在一笔交易内
    function initialize(
        IERC20 stakingToken_,
        IERC20 rewardToken_,
        uint256 rewardsDuration_,
        uint256 unstakeCooldown_
    ) external initializer {
        // 两个代币地址为空会让所有转账调用打到 address(0)，
        // 在部分代币实现里「成功但什么都没发生」，故障会延迟到用户取钱时才暴露
        if (address(stakingToken_) == address(0) || address(rewardToken_) == address(0)) {
            revert InvalidToken();
        }
        // 两个地址相同会让 available 的语义失效：`balanceOf - totalOwed` 里混进了用户本金，
        // manager 就能把本金当奖励预算许诺出去，到期时 getReward 抽走本金、withdraw 付不出来
        if (address(stakingToken_) == address(rewardToken_)) revert InvalidToken();
        // duration 为 0 会让 notifyRewardAmount 里的除法直接 panic
        if (rewardsDuration_ == 0) revert InvalidDuration();
        if (unstakeCooldown_ > MAX_UNSTAKE_COOLDOWN) revert CooldownTooLong(unstakeCooldown_);

        __AccessControl_init();
        __Pausable_init();

        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
        rewardsDuration = rewardsDuration_;
        unstakeCooldown = unstakeCooldown_;

        // 初始化者同时拿四个角色，方便起步；生产环境应在部署后立刻把
        // GUARDIAN_ROLE 交给独立的监控地址、UPGRADER_ROLE 交给时间锁，
        // 并考虑把 DEFAULT_ADMIN_ROLE 移交多签
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REWARDS_MANAGER_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        // 让 periodFinish / lastUpdateTime 处于「周期已结束」的初态，
        // 这样第一次 notifyRewardAmount 一定走「从头开始」分支
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              用户操作
    //////////////////////////////////////////////////////////////*/

    /// @notice 质押 stakingToken，必须先 approve 本合约。暂停期间不可用
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (amount < minStakeAmount) revert BelowMinStake(amount, minStakeAmount);

        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice 发起解质押，顺带结算奖励（但不转账奖励）。
    ///         unstakeCooldown == 0 时本金当场到账，一次交易完成；
    ///         否则本金进入 pendingUnstake，等冷却结束再调 withdraw 取回
    /// @dev 暂停期间依然可用：紧急情况必须允许用户退出
    function requestUnstake(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = balanceOf[msg.sender];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;

        // 零冷却：退化成单笔提取，不牺牲普通用户的体验
        if (unstakeCooldown == 0) {
            stakingToken.safeTransfer(msg.sender, amount);
            emit Withdrawn(msg.sender, amount);
            return;
        }

        UnstakeRequest storage request = pendingUnstake[msg.sender];
        // 已有未解锁的请求时取较晚的解锁时间：宁可让老额度多等，也不让新额度插队提前解锁
        uint256 unlockTime = block.timestamp + unstakeCooldown;
        if (request.unlockTime > unlockTime) unlockTime = request.unlockTime;

        request.amount += amount;
        request.unlockTime = unlockTime;

        emit UnstakeRequested(msg.sender, amount, unlockTime);
    }

    /// @notice 取回冷却已结束的解押本金。暂停期间依然可用
    function withdraw() public nonReentrant updateReward(msg.sender) {
        UnstakeRequest storage request = pendingUnstake[msg.sender];

        uint256 amount = request.amount;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < request.unlockTime) revert StillLocked(request.unlockTime);

        // 先清状态再转账：即使代币带回调也无法重复提取
        delete pendingUnstake[msg.sender];

        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice 领取奖励。claimPaused 期间不可用——奖励是项目方承诺，余额不足时应当有序发放；
    ///         但本金提取不受影响，用户可以先把本金拿回去
    /// @dev 不再挂 `updateReward` 修饰器：`_updateReward` 已经把本次应发金额算好了，
    ///      从这里再 `SLOAD rewards[msg.sender]` 一次纯属浪费
    function getReward() public nonReentrant whenNotClaimPaused {
        uint256 reward = _updateReward(msg.sender);
        if (reward == 0) return;

        rewards[msg.sender] = 0;
        // 夹逼而不是直接减：Σfloor ≤ floor(Σ)，差额可达 n-1 wei，直接减会 panic 0x11，
        // 连 `exit` 和 V2 的 `emergencyWithdraw`（本金最后的出口）一起打死。
        // 差额是 floor 吃掉的，余额并不缺这几 wei，清零比留残值更接近事实
        uint256 owed = totalOwed;
        totalOwed = reward >= owed ? 0 : owed - reward;
        rewardToken.safeTransfer(msg.sender, reward);

        emit RewardPaid(msg.sender, reward);
    }

    /// @notice 一次性把本金转成解押请求 + 领走奖励。
    /// @dev 冷却 > 0 时本金要再调一次 withdraw——这是冷却的必然代价，不是漏发。
    ///      claimPaused 期间跳过领奖而不是整笔失败：退出路径不能被发奖开关堵死
    function exit() external {
        // 不挂 nonReentrant：内部几次调用各自持守卫，本函数自己不转账。
        // 先把已到期的本金落袋，否则下一步 requestUnstake 合并请求时会取较晚的解锁时间，
        // 把等满冷却的那笔重新锁一整期
        UnstakeRequest memory request = pendingUnstake[msg.sender];
        if (request.amount > 0 && block.timestamp >= request.unlockTime) withdraw();

        uint256 balance = balanceOf[msg.sender];
        if (balance > 0) requestUnstake(balance);
        if (!claimPaused) getReward();
    }

    /*//////////////////////////////////////////////////////////////
                            治理操作
    //////////////////////////////////////////////////////////////*/

    /// @notice 注入奖励。调用前必须先把 rewardToken 转到本合约
    /// @dev 周期未结束时注入的奖励会与剩余未释放奖励合并，并重新拉长一整期
    function notifyRewardAmount(uint256 reward)
        external
        onlyRole(REWARDS_MANAGER_ROLE)
        updateReward(address(0))
    {
        if (reward == 0) revert ZeroAmount();

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        if (rewardRate == 0) revert RewardRateTooLow();

        // 余额里属于负债的部分不能算作可用额度，否则同一笔钱会被许诺两次。
        // 负债含未结算应计（进本函数时 updateReward 已把全局应计入账）
        uint256 required = rewardRate * rewardsDuration;
        uint256 available = rewardToken.balanceOf(address(this)) - totalOwed;
        if (required > available) revert InsufficientRewardBalance(required, available);

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(reward, rewardRate, periodFinish);
    }

    /// @notice 修改奖励周期长度。只允许在周期结束后改，避免中途改动正在进行的结算曲线
    function setRewardsDuration(uint256 duration) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (block.timestamp < periodFinish) revert PeriodStillActive();
        if (duration == 0) revert InvalidDuration();

        rewardsDuration = duration;

        emit RewardsDurationUpdated(duration);
    }

    /// @notice 调整最小质押额。只约束之后的 stake，不影响已有仓位
    function setMinStakeAmount(uint256 newMinStakeAmount) external onlyRole(REWARDS_MANAGER_ROLE) {
        minStakeAmount = newMinStakeAmount;

        emit MinStakeAmountUpdated(newMinStakeAmount);
    }

    /// @notice 调整解质押冷却。只对之后发起的请求生效，已挂起的 unlockTime 不变
    /// @dev 用 DEFAULT_ADMIN_ROLE 而不是 REWARDS_MANAGER_ROLE：这条直接改变用户的退出预期，
    ///      敏感度高于日常奖励参数
    function setUnstakeCooldown(uint256 newCooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCooldown > MAX_UNSTAKE_COOLDOWN) revert CooldownTooLong(newCooldown);

        unstakeCooldown = newCooldown;

        emit UnstakeCooldownUpdated(newCooldown);
    }

    /// @notice 救回误转进来的其它代币，转给调用者。stakingToken 和 rewardToken 都不许动
    /// @dev `virtual` 给 V2 留口：V2 把 rewardToken 从「一律禁止」放宽成「只能取盈余」，
    ///      与 ETH 池的 recoverETH 同构
    function recoverERC20(address token, uint256 amount) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(stakingToken)) revert CannotRecoverStakingToken();
        if (token == address(rewardToken)) revert CannotRecoverRewardToken();

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Recovered(token, amount);
    }

    /// @notice 暂停存入。解押、提取、领取奖励不受影响
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /// @notice 暂停发放奖励。本金提取路径完全不受影响
    /// @dev 适用的场景：rewardToken 余额覆盖不了 totalOwed，或者发现奖励计算有偏差需要先冻结发放。
    ///      暂停期间奖励照常累积（rewardRate 与时间决定，与发放动作无关），
    ///      恢复后一次性补齐，用户不损失。
    ///      重复暂停/恢复复用 Pausable 的两个 error，保持和 pause() 一样的语义
    function pauseClaim() external onlyRole(GUARDIAN_ROLE) {
        if (claimPaused) revert EnforcedPause();

        claimPaused = true;

        emit ClaimPaused(msg.sender);
    }

    function unpauseClaim() external onlyRole(GUARDIAN_ROLE) {
        if (!claimPaused) revert ExpectedPause();

        claimPaused = false;

        emit ClaimUnpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              升级
    //////////////////////////////////////////////////////////////*/

    /// @dev UUPS 的安全机制就靠这一行。OZ 把它声明成 abstract 且不给实现，
    ///      编译期强制你写访问控制——忘了写就编译不过，不会像透明代理那样
    ///      「部署成功但谁都能升级」
    ///      只检查权限，不检查新实现的接口：如果新实现去掉了 UUPSUpgradeable，
    ///      合约从此永久不可升级（仍然可用）。这是 OZ 文档里明确指出的风险
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice 当前实现合约地址。前端和监控用它判断实现有没有被换掉
    /// @dev 从 ERC1967 的固定 slot 读，比额外存一个变量更省 gas，也不会和业务状态抢槽位
    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /*//////////////////////////////////////////////////////////////
                                 视图
    //////////////////////////////////////////////////////////////*/

    /// @notice 结算区间的右端点：周期结束后就固定在 periodFinish，不再往后走
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice 当前「每一份质押」累计应得的奖励（含 PRECISION 缩放）
    function rewardPerToken() public view returns (uint256) {
        // 池子空的时候不累积：这段时间的产出没有任何人有资格领取，会滞留合约
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalSupply;
    }

    /// @notice 账户当前可领奖励，含已结算但尚未领取的部分
    function earned(address account) public view returns (uint256) {
        return _rewardOf(account, rewardPerToken());
    }

    /// @dev `earned` 与 `_updateReward` 共用这一份算式，避免同一个乘除在字节码里出现两次
    function _rewardOf(address account, uint256 rpt) internal view returns (uint256) {
        return (balanceOf[account] * (rpt - userRewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    /// @notice 当前是否可提取解押本金，以及可提金额。前端据此决定按钮状态
    function withdrawable(address account) external view returns (uint256 amount, bool unlocked) {
        UnstakeRequest memory request = pendingUnstake[account];
        amount = request.amount;
        unlocked = amount > 0 && block.timestamp >= request.unlockTime;
    }
}
