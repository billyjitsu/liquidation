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

        vm.deal(alice, 10000);
        vm.deal(bob, 10000);
    }

    function test_Deposit() public {
       
        vm.startPrank(alice);
        myToken.mint();
        myToken.approve(address(borrowLend), 1000);
        // address tokenadd = borrowLend.allowedTokens(0);
        // console2.log("Approved Tokens", tokenadd);
        borrowLend.depositToken(address(myToken), 1000);
        borrowLend.depositNative{value: 1}();
        assertEq(borrowLend.deposits(alice, address(myToken)), 1000);

        vm.stopPrank();
        // console2.log("deposits: ", borrowLend.getTotalContractBalance());
        vm.startPrank(bob);
        myToken.mint();
        // vm.expectRevert();
        // borrowLend.borrow(500);
        vm.stopPrank();

        console2.log("alice collateral:", borrowLend.userCollateralValue(alice));
    }

    // function testFuzz_Deposit(uint8 x) public {
    //     vm.startPrank(msg.sender);
    //     // borrowLend.depositETH{value: x}();
    //     // assertEq(borrowLend.deposits(msg.sender), x);
    //     vm.stopPrank();
    // }

    function test_Borrow() public {
        vm.startPrank(alice);
        myToken.mint();
        // borrowLend.depositETH{value: 1000}();
        vm.stopPrank();
        // Try to borrow with no deposit
        vm.startPrank(bob);
        myToken.mint();
        // vm.expectRevert();
        // borrowLend.borrow(500);
        vm.stopPrank();
        // Try to borrow more than 70% of deposit
        vm.startPrank(alice);
        // vm.expectRevert();
        // borrowLend.borrow(800);
        // Try to borrow 70% of deposit
        // borrowLend.borrow(700);
        // Try to borrow just a little more
        // vm.expectRevert();
        // borrowLend.borrow(1);
        vm.stopPrank();
        // console2.log("deposits: ", borrowLend.getTotalContractBalance());
        // console2.log("deposits: ", borrowLend.deposits(alice));
        // console2.log("borrows: ", borrowLend.borrows(alice));
    }

    function test_Repay() public {
        vm.startPrank(alice);
        // borrowLend.deposit{value: 1000}();
        // Borrow 70% of deposit
        // borrowLend.borrow(700);

        // Try to repay more than borrowed
        // vm.expectRevert();
        // borrowLend.repay{value: 701}();
        // Repay less than borrowed
        // borrowLend.repay{value: 50}();
        // assertEq(borrowLend.borrows(alice), 650);

        // Try to borrow more than 70% of deposit
        // vm.expectRevert();
        // borrowLend.borrow(51);
        // Repay borrowed amount
        // borrowLend.repay{value: 650}();
        // console2.log("deposits: ", borrowLend.deposits(alice));
        // console2.log("borrows: ", borrowLend.borrows(alice));

        // Deposit more to borrow even more
        // borrowLend.deposit{value: 1000}();
        // borrowLend.borrow(1400);
        // try to borrow over
        // vm.expectRevert();
        // borrowLend.borrow(1);

        // Repay borrowed amount
        // borrowLend.repay{value: 1400}();

        vm.stopPrank();
        // console2.log("deposits: ", borrowLend.deposits(alice));
        // console2.log("borrows: ", borrowLend.borrows(alice));
    }

    function test_Withdraw() public {
        vm.startPrank(alice);
        // borrowLend.deposit{value: 1000}();
        vm.stopPrank();

        // Try to withdraw with no deposit
        vm.startPrank(bob);
        // vm.expectRevert();
        // borrowLend.withdraw(100);
        vm.stopPrank();

        vm.startPrank(alice);
        // Borrow 70% of deposit
        // borrowLend.borrow(500);
        // uint256 maxWithdraw = borrowLend.calculateMaxWithdrawalAmount(alice);
        // console2.log("maxWithdraw: ", maxWithdraw);

        // Try to withdraw more than 70% of deposit
        // vm.expectRevert();
        // borrowLend.withdraw(maxWithdraw + 1);
        // Withdraw 70% of deposit
        // borrowLend.withdraw(maxWithdraw);

        // Repay borrowed amount
        // borrowLend.repay{value: 500}();

        // maxWithdraw = borrowLend.calculateMaxWithdrawalAmount(alice);
        // console2.log("maxWithdraw: ", maxWithdraw);

        // console2.log("deposits: ", borrowLend.deposits(alice));
        // console2.log("borrows: ", borrowLend.borrows(alice));

        // Withdraw balance with no borrow
        // borrowLend.withdraw(maxWithdraw);
        vm.stopPrank();
    }
}
