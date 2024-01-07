// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {BorrowLend} from "../src/Borrow.sol";
import {MyToken} from "../src/Token.sol";
import {WETH} from "../src/WETH.sol";
import {MockDapiProxy} from "../src/Mocks/MockDapi.sol";
import {MockETHDapiProxy} from "../src/Mocks/MockETHDapi.sol";
import {MockWETHDapiProxy} from "../src/Mocks/MockWETHDapi.sol";

contract BorrowTest is Test {
    BorrowLend public borrowLend;
    MyToken public myToken;
    WETH public weth;

    MockDapiProxy public mockDapiProxy;
    MockETHDapiProxy public mockETHDapiProxy;
    MockWETHDapiProxy public mockWETHDapiProxy;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        borrowLend = new BorrowLend();
        myToken = new MyToken();
        weth = new WETH();
        mockDapiProxy = new MockDapiProxy();
        mockETHDapiProxy = new MockETHDapiProxy();
        mockWETHDapiProxy = new MockWETHDapiProxy();

        // Set token to 1 dollar
        mockDapiProxy.setDapiValues(1000000000000000000, 1000);
        // Set ETH to 2000 dollars
        mockETHDapiProxy.setDapiValues(2000000000000000000000, 1000);
        // Set WETH to 2000 dollars
        mockWETHDapiProxy.setDapiValues(2000000000000000000000, 1000);

        borrowLend.setNativeTokenProxyAddress(address(mockETHDapiProxy));
        borrowLend.setTokensAvailable(address(myToken), address(mockDapiProxy));
        borrowLend.setTokensAvailable(address(weth), address(mockWETHDapiProxy));

        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.startPrank(alice);
        myToken.mint();
        weth.mint();
        vm.stopPrank();
        vm.startPrank(bob);
        myToken.mint();
        weth.mint();
        vm.stopPrank();
    }

    function test_Deposit() public {
        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000 ether);
        // address tokenadd = borrowLend.allowedTokens(0);
        // console2.log("Approved Tokens", tokenadd);
        borrowLend.depositToken(address(myToken), 1000 ether);
        assertEq(borrowLend.deposits(alice, address(myToken)), 1000 ether);
        borrowLend.depositNative{value: 1 ether}();
        assertEq(borrowLend.nativeDeposits(alice), 1 ether);
        vm.stopPrank();
        // console2.log("deposits: ", borrowLend.getTotalContractBalance());
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.depositToken(address(myToken), 0);
        vm.expectRevert();
        borrowLend.depositNative{value: 0}();
        vm.stopPrank();
        // (uint256 borrowedAmount, uint256 depositedAmount) = borrowLend.userInformation(alice);
        // console2.log("depositedAmount: ", depositedAmount / 1 ether);
        // console2.log("borrowedAmount: ", borrowedAmount);
        assertEq(borrowLend.healthFactor(alice), 100e8);
    }

    // function testFuzz_Deposit(uint8 x) public {
    //     vm.startPrank(msg.sender);
    //     // borrowLend.depositETH{value: x}();
    //     // assertEq(borrowLend.deposits(msg.sender), x);
    //     vm.stopPrank();
    // }

    function test_Borrow() public {
        //fund the contract with asset
        myToken.approve(address(borrowLend), 1000 ether);
        borrowLend.depositToken(address(myToken), 1000 ether);

        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000 ether);
        borrowLend.depositToken(address(myToken), 1000 ether);
        assertEq(borrowLend.deposits(alice, address(myToken)), 1000 ether);

        borrowLend.borrow(address(myToken), 313 ether);
        assertEq(borrowLend.borrows(alice, address(myToken)), 313 ether);
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        borrowLend.borrow(address(myToken), 387 ether);
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        assertEq(borrowLend.borrows(alice, address(myToken)), 700 ether);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 1 ether);
        borrowLend.depositNative{value: 1 ether}();
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        borrowLend.borrow(address(myToken), 1300 ether);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 1 ether);
        vm.stopPrank();
        // Try to borrow with no deposit
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 500 ether);
        vm.stopPrank();
        // console2.log("deposits: ", borrowLend.getTotalContractBalance());
        // console2.log("deposits: ", borrowLend.deposits(alice));
        // console2.log("borrows: ", borrowLend.borrows(alice));
    }

    function test_Repay() public {
        //fund the contract with asset
        myToken.approve(address(borrowLend), 1000 ether);
        borrowLend.depositToken(address(myToken), 1000 ether);

        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000 ether);
        borrowLend.depositToken(address(myToken), 1000 ether);
        borrowLend.borrow(address(myToken), 700 ether);
        myToken.approve(address(borrowLend), 500 ether);
        borrowLend.repay(address(myToken), 500 ether);
        assertEq(borrowLend.borrows(alice, address(myToken)), 200 ether);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 501 ether);
        borrowLend.borrow(address(myToken), 500 ether);
        assertEq(borrowLend.borrows(alice, address(myToken)), 700 ether);

        borrowLend.depositNative{value: 1 ether}();
        borrowLend.borrow(address(myToken), 1300 ether);
        myToken.approve(address(borrowLend), 2000 ether);
        borrowLend.repay(address(myToken), 2000 ether);

        vm.expectRevert();
        borrowLend.repay(address(myToken), 5 ether);
        // console2.log("Allice Borrow Balance: ", borrowLend.borrows(alice, address(myToken)));
        borrowLend.borrow(address(myToken), 100 ether);
        vm.stopPrank();
        // Try to repay with no borrow
        vm.startPrank(bob);
        myToken.approve(address(borrowLend), 500 ether);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 500 ether);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        //fund the contract with asset
        myToken.approve(address(borrowLend), 1000 ether);
        borrowLend.depositToken(address(myToken), 1000 ether);

        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000 ether);
        borrowLend.depositToken(address(myToken), 1000 ether);
        borrowLend.borrow(address(myToken), 700 ether);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 1 ether);
        myToken.approve(address(borrowLend), 500 ether);
        borrowLend.repay(address(myToken), 500 ether);
        borrowLend.withdraw(address(myToken), 500 ether);
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        borrowLend.depositNative{value: 1 ether}();
        borrowLend.withdraw(address(myToken), 500 ether);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 1 ether);
        myToken.approve(address(borrowLend), 200 ether);
        borrowLend.repay(address(myToken), 200 ether);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 200 ether);
        borrowLend.withdrawNative(1 ether);
        vm.expectRevert();
        borrowLend.withdrawNative(1 ether);
        vm.stopPrank();
        // Try to repay with no borrow
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 500 ether);
        vm.expectRevert();
        borrowLend.withdrawNative(1 ether);
        vm.stopPrank();
    }

    function test_Liquidate() public {
        //fund the contract with asset
        myToken.approve(address(borrowLend), 10000 ether);
        borrowLend.depositToken(address(myToken), 10000 ether);

        vm.startPrank(alice);
        borrowLend.depositNative{value: 2 ether}();
        borrowLend.borrow(address(myToken), 2800 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.liquidateForNative(alice, address(myToken));
        vm.stopPrank();
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        // Update Oracle Feed 
        mockETHDapiProxy.setDapiValues(1900000000000000000000, 1001);
        // console2.log("Health Factor", borrowLend.healthFactor(alice));
        // Liquidate
        vm.startPrank(bob);
        //Ethereum Balance of Bob
        // console2.log("Bob Balance: ", address(bob).balance);
        myToken.approve(address(borrowLend), 10000 ether);
        borrowLend.liquidateForNative(alice, address(myToken));
        // console2.log("Bob Balance: ", address(bob).balance);
        vm.stopPrank();
        // check balances of alic after liquidation
    }

    function test_LiquidateTokens() public {
        //fund the contract with asset
        weth.approve(address(borrowLend), 10000 ether);
        borrowLend.depositToken(address(weth), 10000 ether);

        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 4000 ether);
        borrowLend.depositToken(address(myToken), 4000 ether);
        borrowLend.borrow(address(weth), 2800 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.liquidateForNative(alice, address(myToken));
        vm.stopPrank();
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        // Update Oracle Feed 
        // mockETHDapiProxy.setDapiValues(1900000000000000000000, 1001);
        // console2.log("Health Factor", borrowLend.healthFactor(alice));
        // Liquidate
        // vm.startPrank(bob);
        // //Ethereum Balance of Bob
        // // console2.log("Bob Balance: ", address(bob).balance);
        // myToken.approve(address(borrowLend), 10000 ether);
        // borrowLend.liquidateForNative(alice, address(myToken));
        // // console2.log("Bob Balance: ", address(bob).balance);
        // vm.stopPrank();
        // // check balances of alic after liquidation
    }
}
