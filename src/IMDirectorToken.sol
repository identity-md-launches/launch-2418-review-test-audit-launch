// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The launch factory receives the whole supply and performs the launch allocations.
contract IMDirectorToken is ERC20 {
    constructor() ERC20("IMDirector", "Director") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
