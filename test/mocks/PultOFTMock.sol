// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { PultOFT } from "../../contracts/PultOFT.sol";

// @dev WARNING: This is for testing purposes only
contract PultOFTMock is PultOFT {
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) PultOFT(_name, _symbol, _lzEndpoint, _delegate) {}

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }

    function removeDust(uint256 _amountLD) public view returns (uint256 amountLD) {
        return _removeDust(_amountLD);
    }
}
