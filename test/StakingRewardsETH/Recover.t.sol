// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StakingRewardsETHBase} from "./StakingRewardsETHBase.sol";
import {StakingRewardsETH} from "../../src/StakingRewardsETH.sol";
import {MockERC20} from "../../src/MockERC20.sol";

/// @title ETH 池的救援边界：只有「不属于任何人」的钱能动
/// @notice 这是 ETH 池最需要被证明的一件事。ERC20 池可以简单地「禁止取回 stakingToken」，
///         ETH 池没有这个开关——管理员手里有一个能把余额转走的函数，
///         唯一的安全来源就是算术：`余额 - totalSupply - totalPending`。
///
///         所以这里把三种钱分开摆：计息本金、冷却中本金、误转的余量。
///         任何一个用例只要让 `totalPending` 少记一笔，余量就会虚高，本金就会被当成余量取走。
contract ETHRecoverTest is StakingRewardsETHBase {
    /*//////////////////////////////////////////////////////////////
                            一、ETH 余量的上限
    //////////////////////////////////////////////////////////////*/

    /// 有人手滑直接转 ETH 进来，这部分不属于任何人，管理员可以取
    function test_RecoverETHTakesOnlySurplus() public {
        _stake(alice, 10 ether);

        vm.deal(address(staking), address(staking).balance + 3 ether);

        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, 13 ether, "13 in contract");
        assertEq(owed, 10 ether, "10 is user principal");
        assertEq(surplus, 3 ether, "3 is nobody's");

        uint256 before = admin.balance;
        staking.recoverETH();

        assertEq(admin.balance, before + 3 ether, "surplus recovered");
        assertEq(address(staking).balance, 10 ether, "user principal untouched");
    }

    /// 关键：用户锁在冷却里的钱不能被 recoverETH 拿走。
    /// 这条是本合约与 ERC20 版最关键的一处不对称——那边靠禁令，这边只能靠记账
    function test_RecoverETHCannotTouchCoolingPrincipal() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        // 合约里恰好只有用户的本金，没有任何余量
        vm.expectRevert(StakingRewardsETH.NoSurplus.selector);
        staking.recoverETH();

        assertEq(address(staking).balance, 10 ether, "principal still there");
    }

    /// 一分余量都没有时也必须拒绝，而不是「成功转 0」
    function test_RecoverETHRevertsWhenBalanceEqualsOwed() public {
        _stake(alice, 10 ether);

        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, owed, "exactly covered");
        assertEq(surplus, 0, "nothing to take");

        vm.expectRevert(StakingRewardsETH.NoSurplus.selector);
        staking.recoverETH();
    }

    /// 混合场景：计息本金 + 冷却本金 + 误转，只有误转那部分可动
    function test_RecoverETHSeparatesAllThreePots() public {
        _stake(alice, 10 ether);
        _stake(bob, 5 ether);

        _requestUnstake(bob, 5 ether);

        vm.deal(address(staking), address(staking).balance + 2 ether);

        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, 17 ether, "10 + 5 + 2");
        assertEq(owed, 15 ether, "10 staking + 5 cooling");
        assertEq(surplus, 2 ether, "only the donation");

        staking.recoverETH();
        assertEq(address(staking).balance, 15 ether, "both principal pots intact");
    }

    /// 取过一次之后，第二次必须是因为「没余量了」而失败，而不是把本金也带走
    function test_RecoverETHIsNotRepeatable() public {
        _stake(alice, 10 ether);
        vm.deal(address(staking), address(staking).balance + 1 ether);

        staking.recoverETH();
        assertEq(address(staking).balance, 10 ether, "surplus drained");

        vm.expectRevert(StakingRewardsETH.NoSurplus.selector);
        staking.recoverETH();
    }

    /*//////////////////////////////////////////////////////////////
                        二、ERC20 奖励币的救援
    //////////////////////////////////////////////////////////////*/

    /// 奖励币不许动：那是用户应得的，不是余量。
    /// 与 V2 的 rewardToken 策略不同，这个池还没有「只取盈余」的升级
    function test_RecoverERC20RefusesRewardToken() public {
        vm.expectRevert(StakingRewardsETH.CannotRecoverRewardToken.selector);
        staking.recoverERC20(address(rewardToken), 1);
    }

    /// 误转的其它代币可以救回，转给调用者
    function test_RecoverERC20ReturnsForeignTokenToCaller() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staking), 7e18);

        staking.recoverERC20(address(other), 7e18);

        assertEq(other.balanceOf(admin), 7e18, "sent to caller");
        assertEq(other.balanceOf(address(staking)), 0, "drained");
    }

    /*//////////////////////////////////////////////////////////////
                    三、误转真的走一次 receive()
    //////////////////////////////////////////////////////////////*/

    /// 上面那组「误转」都用 `vm.deal` 直接改余额，绕过了 `receive()`。
    /// 这里真发一笔带 value、空 calldata 的转账，走的就是 `receive()`
    function test_ReceiveRecordsDonationAsSurplus() public {
        _stake(alice, 10 ether);

        vm.prank(alice);
        (bool ok,) = address(staking).call{value: 3 ether}("");
        assertTrue(ok, "the contract accepts plain ETH");

        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, 13 ether, "13 in contract");
        assertEq(owed, 10 ether, "principal unchanged");
        assertEq(surplus, 3 ether, "donation is surplus");

        uint256 before = admin.balance;
        staking.recoverETH();

        assertEq(admin.balance, before + 3 ether, "surplus recovered");
        assertEq(address(staking).balance, 10 ether, "principal untouched");
    }

    /// 误转发生在别人的冷却期内：钱的归属不因为「合约里余额变多」而改变
    function test_DonationDuringCooldownStaysOutOfPrincipal() public {
        _stake(alice, 10 ether);
        _requestUnstake(alice, 10 ether);

        vm.prank(bob);
        (bool ok,) = address(staking).call{value: 2 ether}("");
        assertTrue(ok, "donation accepted");

        (uint256 held, uint256 owed, uint256 surplus) = staking.ethAccounting();
        assertEq(held, 12 ether, "10 + 2");
        assertEq(owed, 10 ether, "cooling principal only");
        assertEq(surplus, 2 ether, "donation only");

        staking.recoverETH();
        assertEq(address(staking).balance, 10 ether, "cooling principal stays");

        vm.warp(block.timestamp + COOLDOWN);
        uint256 before = alice.balance;
        _withdraw(alice);

        assertEq(alice.balance, before + 10 ether, "principal withdrawable in full");
        (,, uint256 surplusAfter) = staking.ethAccounting();
        assertEq(surplusAfter, 0, "nothing left over");
    }
}
