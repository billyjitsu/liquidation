// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Reward is ERC20 {
    constructor() ERC20("Reward Token", "RWD") {
        _mint(msg.sender, 10000 * 10 ** decimals());
    }

    function mint() external {
        _mint(msg.sender, 10000 * 10 ** decimals());
    }
}
