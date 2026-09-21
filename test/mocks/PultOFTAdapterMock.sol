// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { PultOFTAdapter } from "../../contracts/PultOFTAdapter.sol";

// @dev WARNING: This is for testing purposes only
contract PultOFTAdapterMock is PultOFTAdapter {
    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) PultOFTAdapter(_token, _lzEndpoint, _delegate) {}

    function removeDust(uint256 _amountLD) public view returns (uint256 amountLD) {
        return _removeDust(_amountLD);
    }
}
