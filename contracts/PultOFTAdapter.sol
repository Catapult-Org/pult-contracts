// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { SendParam, OFTLimit, OFTFeeDetail, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { PultFee } from "./PultFee.sol";

/**
 * @title PultOFTAdapter
 * @notice LayerZero V2 OFTAdapter with an optional protocol fee for the already-deployed PULT (CatapultTrade)
 *         token on BSC.
 *
 * @dev Locks PULT on BSC and instructs the PultOFT peer on Robinhood Chain to mint the same amount
 *      (and unlocks PULT when the peer burns). PULT is a plain OpenZeppelin ERC20 (no transfer fee),
 *      so the lossless lock/unlock accounting is correct.
 * @dev Fee model mirrors LayerZero's `OFTAdapterFeeUpgradeable`, capped at 5 % (`PultFee.MAX_FEE_BPS`):
 *      - `defaultFeeBps` applies to every destination, `setFeeBps(dstEid, bps, enabled)` overrides per destination;
 *      - the fee (plus the de-dust remainder) is taken from the sender on the *source* chain and accumulated in
 *        `feeBalance`; `withdrawFees(to)` lets the owner pull only that balance, never the tokens backing the peer;
 *      - with all fees at 0 (the default) behaviour equals the default OFTAdapter except that the de-dust remainder
 *        (< 1e12 wei) accrues to `feeBalance` instead of staying with the sender (LayerZero fee-OFT semantics).
 * @dev Guards added on top of the LayerZero reference: recipient `bytes32(0)` or the destination OApp itself and
 *      sends that would deliver 0 revert (`InvalidRecipient`, `AmountTooSmall`); `withdrawFees` rejects address(0)
 *      and this contract; `quoteOFT` reports the fee in `oftFeeDetails`.
 * @dev Invariant: `token.balanceOf(adapter) == PultOFT.totalSupply() + feeBalance`.
 * @dev WARNING: exactly ONE OFTAdapter must exist for PULT across the whole LayerZero mesh.
 * @dev Token: 0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154 (BSC mainnet).
 */
contract PultOFTAdapter is OFTAdapter, PultFee {
    using SafeERC20 for IERC20;

    /// @notice Fees (in local decimals) accumulated in this contract and withdrawable by the owner.
    uint256 public feeBalance;

    event FeeWithdrawn(address indexed to, uint256 amountLD);

    error NoFeesToWithdraw();
    error InvalidRecipient();
    error AmountTooSmall(uint256 amountLD);

    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {}

    /**
     * @notice Withdraws accumulated fees to `_to`.
     * @dev Only `feeBalance` can be withdrawn; the locked assets backing the remote supply stay untouched.
     */
    function withdrawFees(address _to) external virtual onlyOwner {
        if (_to == address(0) || _to == address(this)) revert InvalidRecipient();
        uint256 balance = feeBalance;
        if (balance == 0) revert NoFeesToWithdraw();

        feeBalance = 0;
        innerToken.safeTransfer(_to, balance);
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
        oftLimit = OFTLimit(0, innerToken.totalSupply());

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
     * @dev Locks the full `amountSentLD`; the difference to `amountReceivedLD` (fee + dust) is credited
     *      to `feeBalance`.
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
                feeBalance += (amountSentLD - amountReceivedLD);
            }
        }

        // `_from` is always msg.sender: OFTCore._send is the only caller of _debit (same as LayerZero's OFTAdapter)
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        innerToken.safeTransferFrom(_from, address(this), amountSentLD);
    }
}
