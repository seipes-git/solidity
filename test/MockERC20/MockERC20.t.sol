// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20} from "../../src/MockERC20.sol";

/// @title MockERC20 的测试
/// @notice 它不是产品合约，但它是所有测试与演练的燃料，出错会污染上层结论：
///         铸不出来 → 用例红；谁都能铸 → 演练里的「余额」没有意义。
///         所以这里只钉两件事：**铸币权限**和**基本转账语义**。
///
/// @dev 这个币依然绝不是真实资产：owner 私钥泄露就等于无限铸币。
///      链上那些在加权限之前部署的旧实例（`0x354C959d…` / `0x416a8c97…`）
///      仍然谁都能铸，代码改不回去，只能弃用。
contract MockERC20Test is Test {
    MockERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        // 测试合约就是部署者，也就是 owner
        token = new MockERC20("Stake", "STK");
    }

    /*//////////////////////////////////////////////////////////////
                          一、元数据与部署者
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(token.name(), "Stake", "name");
        assertEq(token.symbol(), "STK", "symbol");
        assertEq(token.decimals(), 18, "decimals");
        assertEq(token.totalSupply(), 0, "starts empty");
    }

    function test_DeployerIsOwner() public view {
        assertEq(token.owner(), address(this), "deployer owns the token");
    }

    /*//////////////////////////////////////////////////////////////
                            二、铸币权限
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanMint() public {
        token.mint(alice, 100e18);

        assertEq(token.balanceOf(alice), 100e18, "balance");
        assertEq(token.totalSupply(), 100e18, "supply");
    }

    /// 这条是加权限控制的全部意义：非 owner 铸不出来。
    /// 只断言 revert 不够，必须断言错误类型，否则会因为任何别的原因通过
    function test_NonOwnerCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.mint(alice, 1e18);
    }

    /// 铸给零地址会被 ERC20 内部拦下：那不是「丢币」，是一个明确的错误
    function test_MintToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1e18);
    }

    /// owner 转走之后，原来的人就铸不出来了。这条模拟「部署者身份被移交」
    function test_OwnershipTransferMovesMintRight() public {
        token.transferOwnership(bob);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.mint(alice, 1e18);

        vm.prank(bob);
        token.mint(alice, 5e18);
        assertEq(token.balanceOf(alice), 5e18, "new owner mints");
    }

    /*//////////////////////////////////////////////////////////////
                          三、基本转账语义
    //////////////////////////////////////////////////////////////*/

    /// approve + transferFrom 是质押合约取钱的前提。这里验一遍，
    /// 免得上层用例红了却在怀疑质押逻辑
    function test_ApproveAndTransferFrom() public {
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.approve(bob, 40e18);

        assertEq(token.allowance(alice, bob), 40e18, "allowance");

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 40e18), "transferFrom returns true");

        assertEq(token.balanceOf(alice), 60e18, "payer debited");
        assertEq(token.balanceOf(bob), 40e18, "payee credited");
        assertEq(token.allowance(alice, bob), 0, "allowance consumed");
    }

    function test_TransferFromWithoutAllowanceReverts() public {
        token.mint(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        // 这条调用就是要它 revert，返回值没有意义，断言反而会把 expectRevert 吃掉
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(alice, bob, 1);
    }

    function test_TransferMoreThanBalanceReverts() public {
        token.mint(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        // 同上：期望 revert 的调用不包断言
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 11e18);
    }

    /*//////////////////////////////////////////////////////////////
                              四、fuzz
    //////////////////////////////////////////////////////////////*/

    /// 总量守恒：任意两次铸造之后，totalSupply 恒等于两人余额之和
    function testFuzz_MintKeepsSupplyConsistent(uint96 a, uint96 b) public {
        token.mint(alice, a);
        token.mint(bob, b);

        assertEq(token.totalSupply(), uint256(a) + uint256(b), "supply = sum of balances");
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), token.totalSupply(), "no phantom supply");
    }
}
