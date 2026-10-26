// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { FeeConfig, IFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IFee.sol";

/**
 * @title PultFee
 * @notice Bridge fee configuration for PultOFT / PultOFTAdapter with a hard cap of 5 %.
 *
 * @dev Same storage layout, ABI, events and errors as LayerZero's `@layerzerolabs/oft-evm/contracts/Fee.sol`
 *      (`IFee`), except that every fee is capped at `MAX_FEE_BPS` instead of `BPS_DENOMINATOR` (100 %).
 *      LayerZero's setters are `external` and not `virtual`, so the cap cannot be added by overriding them.
 */
abstract contract PultFee is IFee, Ownable {
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Highest fee the owner can configure: 500 bps = 5 %.
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Fee in bps for every destination without an enabled per-destination override.
    uint16 public defaultFeeBps;

    /// @notice Per-destination fee override; `enabled = false` falls back to `defaultFeeBps`.
    mapping(uint32 dstEid => FeeConfig config) public feeBps;

    /**
     * @notice Sets the default fee for all destinations. Reverts with `InvalidBps` above `MAX_FEE_BPS`.
     */
    function setDefaultFeeBps(uint16 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert IFee.InvalidBps();
        defaultFeeBps = _feeBps;
        emit DefaultFeeBpsSet(_feeBps);
    }

    /**
     * @notice Sets the fee for one destination. Reverts with `InvalidBps` above `MAX_FEE_BPS`,
     *         also when `_enabled` is false, so a stored value can never exceed the cap.
     */
    function setFeeBps(uint32 _dstEid, uint16 _feeBps, bool _enabled) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert IFee.InvalidBps();
        feeBps[_dstEid] = FeeConfig(_feeBps, _enabled);
        emit FeeBpsSet(_dstEid, _feeBps, _enabled);
    }

    /**
     * @notice Fee charged for sending `_amount` (local decimals) to `_dstEid`, rounded down.
     */
    function getFee(uint32 _dstEid, uint256 _amount) public view virtual returns (uint256) {
        uint16 bps = _getFeeBps(_dstEid);
        return bps == 0 ? 0 : (_amount * bps) / BPS_DENOMINATOR;
    }

    function _getFeeBps(uint32 _dstEid) internal view returns (uint16) {
        FeeConfig memory config = feeBps[_dstEid];
        return config.enabled ? config.feeBps : defaultFeeBps;
    }
}
