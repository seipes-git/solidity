// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StakingRewards} from "./StakingRewards.sol";

/// @title StakingRewards V2 —— 修 V1 运营缺口的升级版本
/// @notice 加的全部是函数，**一个状态变量都没有新增**。V1 的 16 个槽原封不动，
///         `__gap` 也没动，所以这次升级不需要任何数据迁移。
///
/// @dev 走继承而非复制 V1：继承时新增变量自动排在父类之后（含 __gap），
///      所以「只加函数」是最安全的形态。真要加变量，必须把变量插在 claimPaused 与
///      __gap 之间并缩短 __gap，那时 upgradeToAndCall 的第二参数就要带迁移逻辑。
///
///      本版只做两件事：① rewardToken 从「一律禁止取」放宽到「只能取盈余」；
///      ② 新增 emergencyWithdraw（放弃奖励、无视冷却、立即取本金）
contract StakingRewardsV2 is StakingRewards {
    using SafeERC20 for IERC20;

    /// @dev V1 的 PRECISION 是 private，子类读不到；值必须与它一致（1e18）
    uint256 private constant PRECISION_V2 = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 事件
    //////////////////////////////////////////////////////////////*/

    /// @param principal      退回的本金（仓位 + 冷却中的本金）
    /// @param forfeitedReward 主动放弃的奖励。不会消失：销账后变成盈余，可由 recoverERC20 取回
    event EmergencyWithdrawn(address indexed user, uint256 principal, uint256 forfeitedReward);

    /*//////////////////////////////////////////////////////////////
                                 错误
    //////////////////////////////////////////////////////////////*/

    error NothingToEmergencyWithdraw();

    /*//////////////////////////////////////////////////////////////
                                 版本
    //////////////////////////////////////////////////////////////*/

    /// @notice 当前逻辑版本。升级后回读它，比对比 implementation() 更直观
    /// @dev V1 没有这个函数，升级前调用会 revert——这本身就是判断升级是否生效的手段
    function version() external pure virtual returns (uint256) {
        return 2;
    }

    /*//////////////////////////////////////////////////////////////
                             V2 修的第 ① 件事
    //////////////////////////////////////////////////////////////*/

    /// @notice 救回代币。stakingToken 依旧完全禁止；rewardToken 允许**只取真正多余的部分**
    /// @dev V1 的 rewardToken 是死禁令，注资过量就永远取不回。这里放宽到「只能取盈余」：
    ///
    ///          可动额度 = 余额 − 已欠 − 已许诺未释放
    ///                   = balance − totalOwed − rewardRate × (periodFinish − now)
    ///
    ///      **必须扣掉「已许诺未释放」**：注资 604800 覆盖 7 天，跑到第 2 天 totalOwed 只有
    ///      172800，按 `balance - totalOwed` 会允许取走后面 5 天要发的钱，第 7 天用户就领不到了。
    ///      注意这和 notifyRewardAmount 里的 available 口径不同：notify 把剩余预算算作可用
    ///      是为了合并新一期，recover 是往外拿钱，必须锁住未来。
    ///
    ///      挂 updateReward(address(0))：totalOwed 惰性，不先结算会低估负债、高估可动额度
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
    /// @dev 补 V1 的洞：冷却期内本金原本一分拿不回，哪怕用户愿意放弃奖励。
    ///      三个语义点——不受 paused / claimPaused 影响、无视 unlockTime（与 withdraw 的唯一区别）、
    ///      奖励主动放弃且负债同步销账（否则合约长期显示偿付不足，而钱就在里面）。
    ///      先跑 updateReward，否则放弃的奖励会少算，负债与余额出现无主差额
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
    /// @dev totalOwed 惰性，外部直接读会低估负债（偿付率偏高）。
    ///      这里只把同一套算式在 view 里重算，不改状态
    function totalOwedLive() public view returns (uint256) {
        uint256 delta = rewardPerToken() - rewardPerTokenStored;
        return totalOwed + (totalSupply * delta) / PRECISION_V2;
    }

    /// @notice 偿付率 = 余额 / 实时负债，1e18 精度。1e18 表示刚好打平，低于它说明余额不够
    /// @dev 负债为 0 时返回 type(uint256).max 而非 0：「无负债」和「偿付率为零」是两件事，
    ///      否则刚部署的空池会显示成资不抵债
    function solvencyRatio() external view returns (uint256) {
        uint256 owed = totalOwedLive();
        if (owed == 0) return type(uint256).max;

        return (rewardToken.balanceOf(address(this)) * 1e18) / owed;
    }

    /*//////////////////////////////////////////////////////////////
                            刻意没做的事
    //////////////////////////////////////////////////////////////*/

    // 1. totalPending()：要一个全局计数器，得 override 三个函数去维护它。
    //    override 既有函数是升级里最容易出逻辑分叉的动作，不值得为展示字段做。
    // 2. pendingUnstake 改数组：能根治「已到期额度被新请求推后」，但要迁移存储。
    //    迁移写错等于用户本金丢失，应当单开一次升级专门测迁移。
    // 3. 多奖励币：rewardToken 改成数组，存储布局大改，与单池定位也矛盾。
}
