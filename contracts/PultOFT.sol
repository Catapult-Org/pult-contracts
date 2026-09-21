// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { Fee } from "@layerzerolabs/oft-evm/contracts/Fee.sol";

/**
 * @title PultOFT
 * @notice LayerZero V2 OFT with an optional protocol fee, representing PULT on Robinhood Chain.
 *
 * @dev Mint/burn representation: total supply on this chain always equals the amount of PULT
 *      backing it in `PultOFTAdapter` on BSC (net of the adapter's own fee balance).
 *      No tokens are minted at deployment.
 * @dev Fee model mirrors LayerZero's `OFTFeeUpgradeable`:
 *      - `defaultFeeBps` applies to every destination, `setFeeBps(dstEid, bps, enabled)` overrides per destination;
 *      - on send, the fee (plus the de-dust remainder) is moved from the sender to this contract and tracked in
 *        `feeBalance`; only `amountReceivedLD` is burned. Fee tokens stay part of `totalSupply` and remain backed;
 *      - `withdrawFees(to)` transfers the accumulated fee tokens to `to`;
 *      - with all fees at 0 (the default) behaviour is identical to the default OFT.
 * @dev Shared decimals are the OFT default (6): cross-chain amounts are rounded to 1e12 wei. Local decimals are 18.
 */
contract PultOFT is OFT, Fee {
    /// @notice Fee tokens (in local decimals) held by this contract and withdrawable by the owner.
    uint256 public feeBalance;

    event FeeWithdrawn(address indexed to, uint256 amountLD);

    error NoFeesToWithdraw();

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {}

    /**
     * @notice Withdraws accumulated fee tokens to `_to`.
     */
    function withdrawFees(address _to) external virtual onlyOwner {
        uint256 balance = feeBalance;
        if (balance == 0) revert NoFeesToWithdraw();

        feeBalance = 0;
        _transfer(address(this), _to, balance);
        emit FeeWithdrawn(_to, balance);
    }

    /**
     * @dev Applies the fee, then removes dust, then checks slippage.
     *      The fee is computed on the full amount before de-dusting.
     */
    function _debitView(
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal view virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        amountSentLD = _amountLD;

        uint256 fee = getFee(_dstEid, _amountLD);
        unchecked {
            amountReceivedLD = _removeDust(_amountLD - fee);
        }

        if (amountReceivedLD < _minAmountLD) {
            revert SlippageExceeded(amountReceivedLD, _minAmountLD);
        }
    }

    /**
     * @dev Moves the fee (+ dust) from the sender to this contract and burns only `amountReceivedLD`.
     */
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        if (amountSentLD > amountReceivedLD) {
            unchecked {
                uint256 fee = amountSentLD - amountReceivedLD;
                feeBalance += fee;
                _transfer(_from, address(this), fee);
            }
        }
        _burn(_from, amountReceivedLD);
    }
}
