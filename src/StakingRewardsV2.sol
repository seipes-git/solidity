// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StakingRewards} from "./StakingRewards.sol";

/// @title StakingRewards V2 —— 修 V1 运营缺口的升级版本
/// @notice 加的全部是函数，**一个状态变量都没有新增**。V1 的 16 个槽原封不动，
///         `__gap` 也没动，所以这次升级不需要任何数据迁移。
///
/// @dev 为什么走继承而不是「复制 V1 源码再改」：
///      继承时新增变量会自动排在父类所有变量之后（包括 `__gap`），所以「只加函数」是最安全的形态。
///      一旦需要加变量，就必须复制 V1 的全文、把变量插在 `claimPaused` 与 `__gap` 之间、
///      同时把 `__gap` 长度减掉相应数量——那时 `upgradeToAndCall` 的第二个参数就要带上迁移逻辑。
///
///      V2 修的两件事：
///      ① `recoverERC20` 对 rewardToken 从「一律禁止」改成「只能取盈余」
///      ② 新增 `emergencyWithdraw`：放弃奖励、无视冷却、立即取回本金
///
///      三件事被刻意排除了，理由写在对应位置
contract StakingRewardsV2 is StakingRewards {
    using SafeERC20 for IERC20;

    /// @dev V1 的 PRECISION 是 private，子类读不到，这里重复一份。
    ///      值必须与 V1 一致（1e18），改错会让 totalOwedLive 差出天文数字
    uint256 private constant PRECISION_V2 = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 事件
    //////////////////////////////////////////////////////////////*/

    /// @param principal      退回的本金（仓位 + 冷却中的本金）
    /// @param forfeitedReward 主动放弃的奖励。它不会消失——从 totalOwed 销账后，
    ///                        留在合约里变成盈余，可由 recoverERC20 取回
    event EmergencyWithdrawn(address indexed user, uint256 principal, uint256 forfeitedReward);

    /*//////////////////////////////////////////////////////////////
                                 错误
    //////////////////////////////////////////////////////////////*/

    error NothingToEmergencyWithdraw();

    /*//////////////////////////////////////////////////////////////
                                 版本
    //////////////////////////////////////////////////////////////*/

    /// @notice 当前逻辑版本。升级后回读它，比对比 implementation() 更直观
    /// @dev V1 没有这个函数，所以升级前调用会 revert —— 这本身就是判断升级是否生效的一种方式
    function version() external pure virtual returns (uint256) {
        return 2;
    }

    /*//////////////////////////////////////////////////////////////
                             V2 修的第 ① 件事
    //////////////////////////////////////////////////////////////*/

    /// @notice 救回代币。stakingToken 依旧完全禁止；rewardToken 允许**只取真正多余的部分**
    /// @dev V1 里 rewardToken 是死禁令，后果是「注资过量就永远取不回来」——
    ///      按 7 天算好的 FUND_AMOUNT 只跑了 3 天、或者连续两期注入第二期没开始，
    ///      那笔钱锁在合约里，notifyRewardAmount 只能往后排期，recoverERC20 直接拒绝。
    ///
    ///      **判据必须扣掉「已许诺但还没释放」的部分**，否则会开一个很隐蔽的洞：
    ///      注资 604800 覆盖 7 天，跑到第 2 天时 `totalOwed` 只有 172800，
    ///      若按 `balance - totalOwed` 算，管理员能取走 432000——那是后面 5 天要发的钱。
    ///      取走之后周期不会停，到第 7 天用户 getReward 就是 safeTransfer 失败。
    ///
    ///          可动额度 = 余额 − 已欠 − 已许诺未释放
    ///                   = balance − totalOwed − rewardRate × (periodFinish − now)
    ///
    ///      这个判据和 `notifyRewardAmount` 里那个 `available` 不是一回事：
    ///      notify 时把剩余预算算作可用是对的（要拿它来合并新一期），
    ///      而 recover 是往外拿钱，必须把未来要发的锁住。
    ///
    ///      挂 `updateReward(address(0))`：`totalOwed` 是惰性的，不先结算会低估负债，
    ///      从而高估可动额度。代价是 recover 会顺带推进一次全局结算，这本身无害
    function recoverERC20(address token, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        updateReward(address(0))
    {
        if (token == address(stakingToken)) revert CannotRecoverStakingToken();

        if (token == address(rewardToken)) {
            uint256 balance = rewardToken.balanceOf(address(this));

            // 本期还没到 periodFinish 时，剩下这段的预算已经许诺出去了，不能算盈余
            uint256 committed = block.timestamp < periodFinish
                ? (periodFinish - block.timestamp) * rewardRate
                : 0;
            uint256 locked = totalOwed + committed;
            uint256 available = balance > locked ? balance - locked : 0;

            if (amount > available) revert InsufficientRewardBalance(amount, available);
        }

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Recovered(token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             V2 修的第 ② 件事
    //////////////////////////////////////////////////////////////*/

    /// @notice 紧急退出：本金立即全额退回，代价是放弃全部未领奖励
    /// @dev 存在的理由：V1 的 `unstakeCooldown` 自己给用户加了一道锁——发起解押后
    ///      24 小时内一分钱拿不回来，哪怕他愿意放弃奖励。这和「管理员的开关伸不到用户本金」
    ///      那条设计原则是有张力的：本金不该因为任何一方的设定被冻住。
    ///
    ///      三个语义点：
    ///      - **不受 paused / claimPaused 影响**。它退的是本金，不是奖励
    ///      - **无视 unlockTime**。这正是它和 withdraw 的唯一区别
    ///      - **奖励主动放弃，且负债同步销账**。`totalOwed` 减去放弃的部分，
    ///        于是这笔钱从「名花有主」变成「可用盈余」，可由 recoverERC20 取回。
    ///        如果不销账，合约会长期显示偿付不足，而实际钱就在里面
    ///
    ///      实现上先跑 `updateReward`：让这一刻之前的应计如实入账，
    ///      否则放弃的奖励会凭空少算，负债和余额之间出现无主的差额
    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        uint256 staked = balanceOf[msg.sender];
        uint256 pending = pendingUnstake[msg.sender].amount;

        if (staked == 0 && pending == 0) revert NothingToEmergencyWithdraw();

        // updateReward 刚把应计结算进 rewards；这里连本带利一起清，奖励部分主动放弃
        uint256 forfeited = rewards[msg.sender];

        if (staked > 0) {
            totalSupply -= staked;
            delete balanceOf[msg.sender];
        }
        if (pending > 0) {
            delete pendingUnstake[msg.sender];
        }
        if (forfeited > 0) {
            delete rewards[msg.sender];
            // 同 `getReward` 的夹逼：本函数存在的意义是「任何情况下都能拿回本金」，
            // 不能因为几 wei 的取整差额 panic 0x11 而整笔回滚
            uint256 owed = totalOwed;
            totalOwed = forfeited >= owed ? 0 : owed - forfeited;
        }

        uint256 principal = staked + pending;

        stakingToken.safeTransfer(msg.sender, principal);

        emit EmergencyWithdrawn(msg.sender, principal, forfeited);
    }

    /*//////////////////////////////////////////////////////////////
                             V2 加的观测接口
    //////////////////////////////////////////////////////////////*/

    /// @notice 实时负债：`totalOwed` 加上「从上次结算到现在」这段未入账的应计
    /// @dev V1 的 `totalOwed` 是惰性的，只在 `_updateReward` 里增长。合约内部用它做判断没问题
    ///      （`notifyRewardAmount` 有修饰器先结算），但**外部读它算偿付率会偏低**。
    ///      这个函数不改任何状态，只把同一套公式在 view 里重算一遍
    function totalOwedLive() public view returns (uint256) {
        uint256 delta = rewardPerToken() - rewardPerTokenStored;
        return totalOwed + (totalSupply * delta) / PRECISION_V2;
    }

    /// @notice 偿付率 = 余额 / 实时负债，1e18 精度。1e18 表示刚好打平，低于它说明余额不够
    /// @dev 负债为 0 时返回 `type(uint256).max`（不是 0）——「无负债」和「偿付率为零」是两件事，
    ///      前端必须分开处理，否则池子刚部署完会显示成「资不抵债」
    function solvencyRatio() external view returns (uint256) {
        uint256 owed = totalOwedLive();
        if (owed == 0) return type(uint256).max;

        return (rewardToken.balanceOf(address(this)) * 1e18) / owed;
    }

    /*//////////////////////////////////////////////////////////////
                            刻意没做的事
    //////////////////////////////////////////////////////////////*/

    // 1. totalPending()：需要一个全局计数器，意味着必须 override
    //    requestUnstake / withdraw / emergencyWithdraw 三个函数去维护它。
    //    override 已有函数是升级里最容易出逻辑分叉的动作，为一个展示字段不值得。
    //    要查单个地址的待提取本金，V1 的 `pendingUnstake(address)` getter 已经够用。
    //
    // 2. 把 pendingUnstake 从单槽改成数组：能根治 A-28（已到期额度被新请求推后），
    //    但要新增动态数组存储 + 升级时迁移。迁移写错的后果是用户本金丢失，
    //    这一步应当单独做一次升级，专门测迁移，不和本次混在一起。
    //
    // 3. 多奖励币：要把 rewardToken 单值改成数组，notifyRewardAmount / getReward /
    //    totalOwed 全部重写，存储布局大改。与「单池产品」的定位也矛盾。
}
