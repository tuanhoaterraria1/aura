// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title CortexToken
/// @notice Plain fixed-supply ERC-20. No owner, no mint after construction, no tax, no pause, no blacklist.
///         The whole supply is minted to the launcher, which seeds it as permanently locked single-sided liquidity.
contract CortexToken is ERC20, ERC20Burnable {
    error ZeroRecipient();
    error ZeroSupply();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient_)
        ERC20(name_, symbol_)
    {
        if (recipient_ == address(0)) revert ZeroRecipient();
        if (supply_ == 0) revert ZeroSupply();
        _mint(recipient_, supply_);
    }
}
