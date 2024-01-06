// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {BorrowLend} from "../src/Borrow.sol";

contract BorrowScript is Script {
    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        BorrowLend borrowLend = new BorrowLend();

        vm.stopBroadcast();
    }
}

/*

forge script script/Borrow.s.sol:BorrowScript --rpc-url $PROVIDER_URL --verify --etherscan-api-key $ETHERSCAN_API_KEY --legacy --broadcast

*/
