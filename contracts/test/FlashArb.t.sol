// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {FlashArb, IERC20} from "../src/FlashArb.sol";
import {MockERC20, MockPair, MockVault} from "./Mocks.sol";

contract FlashArbTest is Test {
    MockERC20 weth;
    MockERC20 usdc;
    MockPair cheap;   // WETH is cheap here  -> buy WETH... see below
    MockPair dear;
    MockVault vault;
    FlashArb arb;
    address owner = address(this);

    function setUp() public {
        weth = new MockERC20("WETH");
        usdc = new MockERC20("USDC");
        vault = new MockVault(0);
        weth.mint(address(vault), 1_000 ether);
        arb = new FlashArb(address(vault));

        // Pool A: 100 WETH / 200,000 USDC  (1 WETH = 2000 USDC)
        cheap = _pool(100 ether, 200_000 ether);
        // Pool B: 100 WETH / 220,000 USDC  (1 WETH = 2200 USDC)  -> WETH is pricier here
        dear = _pool(100 ether, 220_000 ether);
    }

    function _pool(uint256 w, uint256 u) internal returns (MockPair p) {
        p = new MockPair(address(weth), address(usdc));
        weth.mint(address(p), w);
        usdc.mint(address(p), u);
        p.sync();
    }

    function _route(uint256 amt, uint256 minProfit, address buy, address sell) internal view returns (FlashArb.Route memory) {
        return FlashArb.Route({
            token: address(weth), amount: amt, pairBuy: buy, pairSell: sell,
            feeBuyBps: 30, feeSellBps: 30, minProfit: minProfit
        });
    }

    // WETH -> USDC on the pool where WETH is expensive (dear), USDC -> WETH where WETH is cheap.
    function test_profitable_arb() public {
        uint256 before = weth.balanceOf(owner);
        arb.executeArb(_route(2 ether, 0.01 ether, address(dear), address(cheap)));
        uint256 gained = weth.balanceOf(owner) - before;
        assertGt(gained, 0.01 ether);
        assertEq(weth.balanceOf(address(vault)), 1_000 ether, "vault made whole");
        assertEq(weth.balanceOf(address(arb)), 0, "no dust left");
    }

    function test_reverts_when_wrong_direction() public {
        vm.expectRevert();
        arb.executeArb(_route(2 ether, 0, address(cheap), address(dear)));
    }

    function test_reverts_when_below_min_profit() public {
        vm.expectRevert();
        arb.executeArb(_route(2 ether, 100 ether, address(dear), address(cheap)));
    }

    function test_reverts_when_loan_fee_eats_profit() public {
        MockVault v2 = new MockVault(5000); // 50% fee
        weth.mint(address(v2), 100 ether);
        FlashArb a2 = new FlashArb(address(v2));
        vm.expectRevert();
        a2.executeArb(_route(2 ether, 0, address(dear), address(cheap)));
    }

    function test_only_owner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(FlashArb.NotOwner.selector);
        arb.executeArb(_route(1 ether, 0, address(dear), address(cheap)));
    }

    function test_callback_only_vault() public {
        IERC20[] memory t = new IERC20[](1);
        uint256[] memory a = new uint256[](1);
        vm.expectRevert(FlashArb.NotVault.selector);
        arb.receiveFlashLoan(t, a, a, "");
    }

    /// Attacker asks the vault to flash-loan *to our contract* with their own route.
    function test_foreign_flashloan_rejected() public {
        MockERC20[] memory t = new MockERC20[](1);
        t[0] = weth;
        uint256[] memory a = new uint256[](1);
        a[0] = 1 ether;
        bytes memory evil = abi.encode(_route(1 ether, 0, address(dear), address(cheap)));
        vm.prank(address(0xBAD));
        vm.expectRevert(FlashArb.UnexpectedCallback.selector);
        vault.flashLoan(address(arb), t, a, evil);
    }

    function test_rescue_and_setOwner() public {
        weth.mint(address(arb), 1 ether);
        arb.rescue(address(weth));
        assertEq(weth.balanceOf(owner), 1 ether);
        arb.setOwner(address(0xCAFE));
        assertEq(arb.owner(), address(0xCAFE));
    }

    /// Invariant-style fuzz: a call either reverts, or the owner gains >= minProfit.
    /// The vault is never left short.
    function testFuzz_never_loses(uint96 amt, uint96 minProfit, bool flip) public {
        amt = uint96(bound(amt, 1e12, 50 ether));
        (address b, address s) = flip ? (address(cheap), address(dear)) : (address(dear), address(cheap));
        uint256 before = weth.balanceOf(owner);
        try arb.executeArb(_route(amt, minProfit, b, s)) {
            assertGe(weth.balanceOf(owner) - before, minProfit);
        } catch {
            assertEq(weth.balanceOf(owner), before);
        }
        assertEq(weth.balanceOf(address(vault)), 1_000 ether);
    }
}
