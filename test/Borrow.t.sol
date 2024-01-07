// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {BorrowLend} from "../src/Borrow.sol";
import {MyToken} from "../src/Token.sol";
import {MockDapiProxy} from "../src/Mocks/MockDapi.sol";
import {MockETHDapiProxy} from "../src/Mocks/MockETHDapi.sol";

contract BorrowTest is Test {
    BorrowLend public borrowLend;
    MyToken public myToken;
    MockDapiProxy public mockDapiProxy;
    MockETHDapiProxy public mockETHDapiProxy;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        borrowLend = new BorrowLend();
        myToken = new MyToken();
        mockDapiProxy = new MockDapiProxy();
        mockETHDapiProxy = new MockETHDapiProxy();

        // Set token to 1 dollar
        mockDapiProxy.setDapiValues(1000000000000000000, 1000);
        // Set ETH to 2000 dollars
        mockETHDapiProxy.setDapiValues(2000000000000000000000, 1000);

        borrowLend.setNativeTokenProxyAddress(address(mockETHDapiProxy));
        borrowLend.setTokensAvailable(address(myToken), address(mockDapiProxy));

        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.startPrank(alice);
        myToken.mint();
        vm.stopPrank();
        vm.startPrank(bob);
        myToken.mint();
        vm.stopPrank();
    }

    function test_Deposit() public {
        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000);
        // address tokenadd = borrowLend.allowedTokens(0);
        // console2.log("Approved Tokens", tokenadd);
        borrowLend.depositToken(address(myToken), 1000);
        assertEq(borrowLend.deposits(alice, address(myToken)), 1000);
        borrowLend.depositNative{value: 1}();
        assertEq(borrowLend.nativeDeposits(alice), 1);
        vm.stopPrank();
        // console2.log("deposits: ", borrowLend.getTotalContractBalance());
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.depositToken(address(myToken), 0);
        vm.expectRevert();
        borrowLend.depositNative{value: 0}();
        vm.stopPrank();
        // (uint256 borrowedAmount, uint256 depositedAmount) = borrowLend.userInformation(alice);
        // console2.log("depositedAmount: ", depositedAmount);
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
        myToken.approve(address(borrowLend), 1000);
        borrowLend.depositToken(address(myToken), 1000);

        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000);
        borrowLend.depositToken(address(myToken), 1000);
        assertEq(borrowLend.deposits(alice, address(myToken)), 1000);

        borrowLend.borrow(address(myToken), 313);
        assertEq(borrowLend.borrows(alice, address(myToken)), 313);
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        borrowLend.borrow(address(myToken), 387);
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        assertEq(borrowLend.borrows(alice, address(myToken)), 700);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 1);
        borrowLend.depositNative{value: 1}();
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        borrowLend.borrow(address(myToken), 1300);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 1);
        vm.stopPrank();
        // Try to borrow with no deposit
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 500);
        vm.stopPrank();
        // console2.log("deposits: ", borrowLend.getTotalContractBalance());
        // console2.log("deposits: ", borrowLend.deposits(alice));
        // console2.log("borrows: ", borrowLend.borrows(alice));
    }

    function test_Repay() public {
        //fund the contract with asset
        myToken.approve(address(borrowLend), 1000);
        borrowLend.depositToken(address(myToken), 1000);

        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000);
        borrowLend.depositToken(address(myToken), 1000);
        borrowLend.borrow(address(myToken), 700);
        myToken.approve(address(borrowLend), 500);
        borrowLend.repay(address(myToken), 500);
        assertEq(borrowLend.borrows(alice, address(myToken)), 200);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 501);
        borrowLend.borrow(address(myToken), 500);
        assertEq(borrowLend.borrows(alice, address(myToken)), 700);

        borrowLend.depositNative{value: 1}();
        borrowLend.borrow(address(myToken), 1300);
        myToken.approve(address(borrowLend), 2000);
        borrowLend.repay(address(myToken), 2000);

        vm.expectRevert();
        borrowLend.repay(address(myToken), 5);
        // console2.log("Allice Borrow Balance: ", borrowLend.borrows(alice, address(myToken)));
        borrowLend.borrow(address(myToken), 100);
        vm.stopPrank();
        // Try to repay with no borrow
        vm.startPrank(bob);
        myToken.approve(address(borrowLend), 500);
        vm.expectRevert();
        borrowLend.borrow(address(myToken), 500);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        //fund the contract with asset
        myToken.approve(address(borrowLend), 1000);
        borrowLend.depositToken(address(myToken), 1000);

        vm.startPrank(alice);
        myToken.approve(address(borrowLend), 1000);
        borrowLend.depositToken(address(myToken), 1000);
        borrowLend.borrow(address(myToken), 700);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 1);
        myToken.approve(address(borrowLend), 500);
        borrowLend.repay(address(myToken), 500);
        borrowLend.withdraw(address(myToken), 500);
        // console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        borrowLend.depositNative{value: 1}();
        borrowLend.withdraw(address(myToken), 500);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 1);
        myToken.approve(address(borrowLend), 200);
        borrowLend.repay(address(myToken), 200);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 200);
        borrowLend.withdrawNative(1);
        vm.expectRevert();
        borrowLend.withdrawNative(1);
        vm.stopPrank();
        // Try to repay with no borrow
        vm.startPrank(bob);
        vm.expectRevert();
        borrowLend.withdraw(address(myToken), 500);
        vm.expectRevert();
        borrowLend.withdrawNative(1);
        vm.stopPrank();
    }

    function test_Liquidate() public {
        //fund the contract with asset
        myToken.approve(address(borrowLend), 10000);
        borrowLend.depositToken(address(myToken), 10000);

        vm.startPrank(alice);
        borrowLend.depositNative{value: 2}();
        borrowLend.borrow(address(myToken), 2800);
        vm.stopPrank();
        console2.log("Alice Health Factor: ", borrowLend.healthFactor(alice));
        // Update Oracle Feed 
        mockETHDapiProxy.setDapiValues(1900000000000000000000, 1001);
        console2.log("Health Factor", borrowLend.healthFactor(alice));
        // Liquidate
        vm.startPrank(bob);
        myToken.approve(address(borrowLend), 10000);
        borrowLend.liquidateForNative(alice, address(myToken));
        vm.stopPrank();
    }
}
