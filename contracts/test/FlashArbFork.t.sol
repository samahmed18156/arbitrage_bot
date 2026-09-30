// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {FlashArb, IERC20, IUniswapV2Pair} from "../src/FlashArb.sol";

/// Runs against a real Base fork: real Balancer vault, real Uniswap V2 + SushiSwap V2 pools.
/// Skipped automatically unless BASE_RPC_URL is set.
///   BASE_RPC_URL=https://mainnet.base.org forge test --match-contract Fork -vv
contract FlashArbForkTest is Test {
    address constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant UNI_PAIR = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C;   // WETH/USDC
    address constant SUSHI_PAIR = 0x2F8818D1B0f3e3E295440c1C0cDDf40aAA21fA87; // WETH/USDC

    FlashArb arb;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        arb = new FlashArb(VAULT);
    }

    /// Real pools are (almost always) efficiently priced, so a real arb should revert cleanly.
    function test_fork_no_free_lunch_reverts_cleanly() public {
        vm.expectRevert();
        arb.executeArb(_route(0.02 ether, 1, SUSHI_PAIR, UNI_PAIR));
    }

    /// Create a price gap by dumping WETH into the Uniswap pool, then arb it with a real flash loan.
    function test_fork_profitable_after_price_gap() public {
        uint256 dump = 10 ether;
        deal(WETH, address(this), dump);
        IERC20(WETH).transfer(UNI_PAIR, dump);
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(UNI_PAIR).getReserves(); // token0 = WETH
        uint256 usdcOut = (dump * 997 * r1) / (r0 * 1000 + dump * 997);
        IUniswapV2Pair(UNI_PAIR).swap(0, usdcOut, address(this), "");

        // WETH is now cheaper on Uniswap -> sell WETH on Sushi, buy back on Uniswap.
        uint256 before = IERC20(WETH).balanceOf(address(this));
        arb.executeArb(_route(0.03 ether, 1, SUSHI_PAIR, UNI_PAIR));
        uint256 gained = IERC20(WETH).balanceOf(address(this)) - before;
        emit log_named_decimal_uint("profit (WETH)", gained, 18);
        assertGt(gained, 0);
    }

    function _route(uint256 amt, uint256 minProfit, address buy, address sell)
        internal
        pure
        returns (FlashArb.Route memory)
    {
        return FlashArb.Route(WETH, amt, buy, sell, 30, 30, minProfit);
    }
}
