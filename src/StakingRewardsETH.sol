// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakingRewardsETH —— 原生 ETH 单池质押
/// @notice 与 StakingRewards 的区别只有一件事：质押物是 ETH，不是 ERC20。
///         奖励数学、角色分层、两级闸门、解押冷却全部保持一致。
/// @dev 为什么不把 ETH 塞进原来的合约：
///      1. 原合约已上链运行、有真实仓位，改动它的资金路径等于让已部署的代码失效
///      2. 单资产池的语义更清楚：一个池只回答「这个资产怎么分奖励」
///      3. ETH 转账会触发接收者代码，重入面比 ERC20 大，独立出来才能针对性地守
///
///      与原合约的三处实质差异：
///      - `stake()` 无参数且 payable，金额就是 msg.value
///      - 转出用 `call{value}`，不是 `safeTransfer`
///      - 新增 `totalPending`：没有它，`recoverETH` 的分不清「误转的 ETH」和「用户锁在冷却里的本金」
contract StakingRewardsETH is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                常量
    //////////////////////////////////////////////////////////////*/

    uint256 private constant PRECISION = 1e18;

    /// @notice 解质押冷却的上限。防止管理员把它设成一年来变相锁死用户本金
    uint256 public constant MAX_UNSTAKE_COOLDOWN = 30 days;

    /// @notice 能改奖励参数（注入、周期、最小质押额）
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");

    /// @notice 只能暂停与恢复。权限刻意比 REWARDS_MANAGER_ROLE 小
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /*//////////////////////////////////////////////////////////////
                                 状态
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable rewardToken;

    uint256 public rewardsDuration;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalSupply;
    uint256 public minStakeAmount;
    uint256 public unstakeCooldown;

    /// @notice 已发起解押、等待冷却结束的本金总额
    /// @dev 存在的唯一理由：让 recoverETH 知道有多少 ETH 是欠用户的。
    ///      `totalSupply + totalPending` 才是合约应付的本金总额，
    ///      余额超出这部分才算「误转」，才可以被管理员取走
    uint256 public totalPending;

    mapping(address account => uint256) public balanceOf;
    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    /// @notice 已产生但尚未转出的奖励总额，含「已结算未领取」与「未结算应计」两部分
    /// @dev 惰性累计量，只在 _updateReward 里入账
    uint256 public totalOwed;

    struct UnstakeRequest {
        uint256 amount;
        uint256 unlockTime;
    }

    /// @notice 每个地址同时只有一笔挂起请求。多次发起累加金额，解锁时间取最晚
    mapping(address account => UnstakeRequest) public pendingUnstake;

    /// @notice 领取奖励的独立开关，与 paused() 是两回事
    bool public claimPaused;

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
    event ETHRecovered(address indexed to, uint256 amount);
    /// @dev 紧急退出：本金全额退回，奖励主动放弃。`forfeited` 是放弃掉的应计
    event EmergencyWithdrawn(address indexed user, uint256 principal, uint256 forfeited);

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
    error CannotRecoverRewardToken();
    error NothingToWithdraw();
    error StillLocked(uint256 unlockTime);
    error CooldownTooLong(uint256 cooldown);
    error ClaimIsPaused();
    error ETHTransferFailed();
    error NoSurplus();
    error InvalidToken();
    error NothingToEmergencyWithdraw();

    /*//////////////////////////////////////////////////////////////
                                修饰器
    //////////////////////////////////////////////////////////////*/

    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    modifier whenNotClaimPaused() {
        if (claimPaused) revert ClaimIsPaused();
        _;
    }

    /// @dev 返回值是本次为 account 结算出的应发奖励，给 `getReward` 直接用，省掉一次回读
    function _updateReward(address account) internal returns (uint256 accountReward) {
        // 一次读齐：原写法在 `rewardPerToken()` 与 `earned()` 里各算一遍曲线，
        // `rewardPerTokenStored` / `totalSupply` / `lastUpdateTime` / `periodFinish` 被多读一圈
        uint256 supply = totalSupply;
        uint256 lastTime = lastTimeRewardApplicable();
        uint256 stored = rewardPerTokenStored;

        uint256 rpt = stored;
        if (supply != 0) {
            rpt += ((lastTime - lastUpdateTime) * rewardRate * PRECISION) / supply;
        }

        uint256 delta = rpt - stored;
        if (delta > 0) {
            rewardPerTokenStored = rpt;
            // 每个边界各 floor 一次，逐用户 floor 之和可能超过这个累计值（最多 n-1 wei），
            // 由 `getReward` / `emergencyWithdraw` 的夹逼吸收
            totalOwed += (supply * delta) / PRECISION;
        }
        lastUpdateTime = lastTime;

        if (account != address(0)) {
            accountReward = _rewardOf(account, rpt);
            rewards[account] = accountReward;
            userRewardPerTokenPaid[account] = rpt;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                构造
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 rewardToken_, uint256 rewardsDuration_, uint256 unstakeCooldown_) {
        // 零地址的奖励币会让 getReward / notifyRewardAmount 打到 address(0)，
        // 故障要等到第一个用户领奖时才暴露，而那时代理不可用（本合约还没有升级通路）
        if (address(rewardToken_) == address(0)) revert InvalidToken();
        if (rewardsDuration_ == 0) revert InvalidDuration();
        if (unstakeCooldown_ > MAX_UNSTAKE_COOLDOWN) revert CooldownTooLong(unstakeCooldown_);

        rewardToken = rewardToken_;
        rewardsDuration = rewardsDuration_;
        unstakeCooldown = unstakeCooldown_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REWARDS_MANAGER_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              用户操作
    //////////////////////////////////////////////////////////////*/

    /// @notice 质押原生 ETH，金额就是 msg.value。暂停期间不可用
    /// @dev 与 ERC20 版不同：没有 approve 这一步，也没有 transferFrom 的回调面。
    ///      msg.value 为 0 时直接拒绝，避免产生一笔没有任何意义的仓位
    function stake() external payable nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();
        if (amount < minStakeAmount) revert BelowMinStake(amount, minStakeAmount);

        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        emit Staked(msg.sender, amount);
    }

    /// @notice 发起解质押。冷却为 0 时本金当场退还，否则进入 pendingUnstake
    /// @dev 暂停期间依然可用：紧急情况必须允许用户退出
    function requestUnstake(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = balanceOf[msg.sender];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;

        if (unstakeCooldown == 0) {
            emit Withdrawn(msg.sender, amount);
            _sendETH(msg.sender, amount);
            return;
        }

        UnstakeRequest storage request = pendingUnstake[msg.sender];
        uint256 unlockTime = block.timestamp + unstakeCooldown;
        if (request.unlockTime > unlockTime) unlockTime = request.unlockTime;

        request.amount += amount;
        request.unlockTime = unlockTime;
        totalPending += amount;

        emit UnstakeRequested(msg.sender, amount, unlockTime);
    }

    /// @notice 取回冷却已结束的解押本金。暂停期间依然可用
    /// @dev 先清状态再转账：ETH 转账会把控制权交给对方，必须遵守 CEI
    function withdraw() public nonReentrant updateReward(msg.sender) {
        UnstakeRequest storage request = pendingUnstake[msg.sender];

        uint256 amount = request.amount;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < request.unlockTime) revert StillLocked(request.unlockTime);

        delete pendingUnstake[msg.sender];
        totalPending -= amount;

        emit Withdrawn(msg.sender, amount);
        _sendETH(msg.sender, amount);
    }

    /// @notice 领取奖励。claimPaused 期间不可用，本金提取不受影响
    function getReward() public nonReentrant whenNotClaimPaused {
        uint256 reward = _updateReward(msg.sender);
        if (reward == 0) return;

        rewards[msg.sender] = 0;
        // 夹逼而不是直接减：`totalOwed` 每个结算边界各 floor 一次，用户应发跨边界一次性 floor，
        // 差额可达 n-1 wei。直接减会 panic 0x11 —— 本合约不可升级，这条路径一旦打死就没有补救
        uint256 owed = totalOwed;
        totalOwed = reward >= owed ? 0 : owed - reward;
        rewardToken.safeTransfer(msg.sender, reward);

        emit RewardPaid(msg.sender, reward);
    }

    /// @notice 紧急退出：本金立即全额退还（计息本金 + 冷却中的本金），代价是放弃全部未领奖励
    /// @dev 本合约**不可升级**，所以这个出口只能在部署前决定要不要；上线后再想加只能重新部署。
    ///      它与 V2 的 `emergencyWithdraw` 语义一致，差别是这里还要同步 `totalPending`——
    ///      `recoverETH` 的安全上限是 `balance − totalSupply − totalPending`，
    ///      少减一笔就会把那部分本金当成「余量」让管理员取走。
    ///
    ///      三个语义点：
    ///      - **不受 paused / claimPaused 影响**：退的是本金，不是奖励
    ///      - **无视 unlockTime**：这正是它和 `withdraw` 的唯一区别
    ///      - **奖励主动放弃且负债同步销账**：`totalOwed` 减掉放弃的部分，
    ///        这笔钱从「名花有主」变成「可用盈余」
    ///
    ///      先跑 `updateReward` 让此刻之前的应计如实入账，再清状态、最后转账（CEI）
    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        uint256 staked = balanceOf[msg.sender];
        uint256 pending = pendingUnstake[msg.sender].amount;

        if (staked == 0 && pending == 0) revert NothingToEmergencyWithdraw();

        uint256 forfeited = rewards[msg.sender];

        if (staked > 0) {
            totalSupply -= staked;
            delete balanceOf[msg.sender];
        }
        if (pending > 0) {
            totalPending -= pending;
            delete pendingUnstake[msg.sender];
        }
        if (forfeited > 0) {
            delete rewards[msg.sender];
            // 夹逼：取整差额可达 n-1 wei，直接减会 panic 0x11 把紧急出口打死
            uint256 owed = totalOwed;
            totalOwed = forfeited >= owed ? 0 : owed - forfeited;
        }

        uint256 principal = staked + pending;
        emit EmergencyWithdrawn(msg.sender, principal, forfeited);

        _sendETH(msg.sender, principal);
    }

    /// @notice 一次性发起解押 + 领奖。claimPaused 期间跳过领奖，不阻断退出
    function exit() external {
        // 先把已到期的待提本金落袋，避免下一句合并挂起请求时把它重新计时一个冷却周期
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

        uint256 required = rewardRate * rewardsDuration;
        uint256 available = rewardToken.balanceOf(address(this)) - totalOwed;
        if (required > available) revert InsufficientRewardBalance(required, available);

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(reward, rewardRate, periodFinish);
    }

    /// @notice 修改奖励周期长度。只允许在周期结束后改
    function setRewardsDuration(uint256 duration) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (block.timestamp < periodFinish) revert PeriodStillActive();
        if (duration == 0) revert InvalidDuration();

        rewardsDuration = duration;

        emit RewardsDurationUpdated(duration);
    }

    /// @notice 调整最小质押额。单位是 wei（1 ETH = 1e18）。只约束之后的 stake
    function setMinStakeAmount(uint256 newMinStakeAmount) external onlyRole(REWARDS_MANAGER_ROLE) {
        minStakeAmount = newMinStakeAmount;

        emit MinStakeAmountUpdated(newMinStakeAmount);
    }

    /// @notice 调整解质押冷却。只对之后发起的请求生效
    function setUnstakeCooldown(uint256 newCooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCooldown > MAX_UNSTAKE_COOLDOWN) revert CooldownTooLong(newCooldown);

        unstakeCooldown = newCooldown;

        emit UnstakeCooldownUpdated(newCooldown);
    }

    /// @notice 救回误转进来的 ERC20。rewardToken 不许动（那是用户应得的奖励）
    function recoverERC20(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(rewardToken)) revert CannotRecoverRewardToken();

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Recovered(token, amount);
    }

    /// @notice 取走「不属于任何人」的 ETH：误转进来的、或者 selfdestruct 强塞的
    /// @dev 上限 = 余额 - 用户本金 - 锁在冷却里的本金。
    ///      没有这道上限，管理员就能把用户还没取回的冷资本金直接拿走 ——
    ///      那是挪用，不是救援。这是本合约与 ERC20 版最关键的一处不对称：
    ///      ERC20 版可以「禁止取回 stakingToken」，ETH 版没有这个开关，只能靠算术守住
    function recoverETH() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 owed = totalSupply + totalPending;
        uint256 balance = address(this).balance;
        if (balance <= owed) revert NoSurplus();

        uint256 surplus = balance - owed;
        emit ETHRecovered(msg.sender, surplus);
        _sendETH(msg.sender, surplus);
    }

    /// @notice 暂停存入。解押、提取、领取奖励不受影响
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /// @notice 暂停发放奖励。本金提取路径完全不受影响
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
                                 视图
    //////////////////////////////////////////////////////////////*/

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return _rewardOf(account, rewardPerToken());
    }

    /// @dev `earned` 与 `_updateReward` 共用这一份算式，避免同一个乘除在字节码里出现两次
    function _rewardOf(address account, uint256 rpt) internal view returns (uint256) {
        return (balanceOf[account] * (rpt - userRewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    function withdrawable(address account) external view returns (uint256 amount, bool unlocked) {
        UnstakeRequest memory request = pendingUnstake[account];
        amount = request.amount;
        unlocked = amount > 0 && block.timestamp >= request.unlockTime;
    }

    /// @notice 合约实际持有的 ETH，与应付款项分开看
    /// @return held 余额，owed 欠用户的本金（含冷却中），surplus 可被管理员取走的余量
    function ethAccounting() external view returns (uint256 held, uint256 owed, uint256 surplus) {
        held = address(this).balance;
        owed = totalSupply + totalPending;
        surplus = held > owed ? held - owed : 0;
    }

    /*//////////////////////////////////////////////////////////////
                                内部
    //////////////////////////////////////////////////////////////*/

    /// @dev 用 call 而不是 transfer：2300 gas 的 stipend 在多签钱包、智能合约钱包下会失败。
    ///      代价是接收方能执行代码，所以所有调用点都必须 nonReentrant + 先清状态
    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
    }

    /// @notice 允许直接转账进来（误转）。这些 ETH 不属于任何人，管理员可用 recoverETH 处理
    /// @dev 不加这个函数也不会丢钱，但 selfdestruct 强塞的 ETH 将永远无法取出
    receive() external payable {}
}
