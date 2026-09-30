// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {FlashArb} from "../src/FlashArb.sol";

contract Deploy is Script {
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    function run() external {
        vm.startBroadcast();
        FlashArb arb = new FlashArb(BALANCER_VAULT);
        vm.stopBroadcast();
        console.log("FlashArb deployed at", address(arb));
    }
}
