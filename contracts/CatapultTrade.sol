// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.6.0
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract CatapultTrade is ERC20, ERC20Permit, Ownable {
    using SafeERC20 for IERC20;

    constructor(
        address recipient,
        address initialOwner
    )
        ERC20("Catapult Trade", "PULT")
        ERC20Permit("Catapult Trade")
        Ownable(initialOwner)
    {
        _mint(recipient, 1_000_000_000 * 10 ** decimals());
    }

    function claimERC20(IERC20 token) external onlyOwner {
        address recipient = owner();
        uint256 amount = token.balanceOf(address(this));

        token.safeTransfer(recipient, amount);
    }
}
