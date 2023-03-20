// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

contract IntegrationTest is Test {

    function setUp() external {

    }

    function testSetup() external {
        console.log("Testing");
        assertTrue(true);
    }
}
