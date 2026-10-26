// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { SendParam, OFTLimit, OFTFeeDetail, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { PultFee } from "./PultFee.sol";

/**
 * @title PultOFT
 * @notice LayerZero V2 OFT with an optional protocol fee, representing PULT on Robinhood Chain.
 *
 * @dev Mint/burn representation: total supply on this chain always equals the amount of PULT
 *      backing it in `PultOFTAdapter` on BSC (net of the adapter's own fee balance).
 *      No tokens are minted at deployment.
 * @dev Fee model mirrors LayerZero's `OFTFeeUpgradeable`, capped at 5 % (`PultFee.MAX_FEE_BPS`):
 *      - `defaultFeeBps` applies to every destination, `setFeeBps(dstEid, bps, enabled)` overrides per destination;
 *      - on send, the fee (plus the de-dust remainder) is moved from the sender to this contract and tracked in
 *        `feeBalance`; only `amountReceivedLD` is burned. Fee tokens stay part of `totalSupply` and remain backed;
 *      - `withdrawFees(to)` transfers the accumulated fee tokens to `to`;
 *      - with all fees at 0 (the default) behaviour equals the default OFT except that the de-dust remainder
 *        (< 1e12 wei) accrues to `feeBalance` instead of staying with the sender (LayerZero fee-OFT semantics).
 * @dev Guards added on top of the LayerZero reference: recipient `bytes32(0)` or the destination OApp itself and
 *      sends that would deliver 0 revert (`InvalidRecipient`, `AmountTooSmall`); `withdrawFees` rejects address(0)
 *      and this contract; `quoteOFT` reports the fee in `oftFeeDetails`.
 * @dev Shared decimals are the OFT default (6): cross-chain amounts are rounded to 1e12 wei. Local decimals are 18.
 */
contract PultOFT is OFT, PultFee {
    /// @notice Fee tokens (in local decimals) held by this contract and withdrawable by the owner.
    uint256 public feeBalance;

    event FeeWithdrawn(address indexed to, uint256 amountLD);

    error NoFeesToWithdraw();
    error InvalidRecipient();
    error AmountTooSmall(uint256 amountLD);

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
        if (_to == address(0) || _to == address(this)) revert InvalidRecipient();
        uint256 balance = feeBalance;
        if (balance == 0) revert NoFeesToWithdraw();

        feeBalance = 0;
        _transfer(address(this), _to, balance);
        emit FeeWithdrawn(_to, balance);
    }

    /**
     * @notice Same as `OFTCore.quoteOFT`, plus: rejects invalid recipients and reports the bridge fee (fee + dust) in
     *         `oftFeeDetails` instead of leaving it empty.
     */
    function quoteOFT(
        SendParam calldata _sendParam
    )
        external
        view
        virtual
        override
        returns (OFTLimit memory oftLimit, OFTFeeDetail[] memory oftFeeDetails, OFTReceipt memory oftReceipt)
    {
        _checkRecipient(_sendParam.dstEid, _sendParam.to);
        oftLimit = OFTLimit(0, totalSupply());

        (uint256 amountSentLD, uint256 amountReceivedLD) = _debitView(
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        if (amountSentLD > amountReceivedLD) {
            oftFeeDetails = new OFTFeeDetail[](1);
            oftFeeDetails[0] = OFTFeeDetail(
                SafeCast.toInt256(amountSentLD - amountReceivedLD),
                "PULT bridge fee + dust"
            );
        } else {
            oftFeeDetails = new OFTFeeDetail[](0);
        }
    }

    /**
     * @dev Rejects recipient `bytes32(0)` and the destination OApp itself: tokens credited to either can never be
     *      recovered (the adapter cannot `safeTransfer` to address(0), so such a message could never execute on BSC).
     *      Runs in `quoteOFT`, `quoteSend` and `send` (via `_buildMsgAndOptions`), so wallets fail at quote time.
     */
    function _checkRecipient(uint32 _dstEid, bytes32 _to) internal view {
        if (_to == bytes32(0) || _to == peers[_dstEid]) revert InvalidRecipient();
    }

    function _buildMsgAndOptions(
        SendParam calldata _sendParam,
        uint256 _amountLD
    ) internal view virtual override returns (bytes memory message, bytes memory options) {
        _checkRecipient(_sendParam.dstEid, _sendParam.to);
        return super._buildMsgAndOptions(_sendParam, _amountLD);
    }

    /**
     * @dev Applies the fee, then removes dust, rejects sends that would deliver nothing, then checks slippage.
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

        // Nothing would arrive (amount below one shared-decimal unit after fee + dust): refuse instead of moving the
        // whole amount into feeBalance.
        if (amountReceivedLD == 0) revert AmountTooSmall(_amountLD);

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
