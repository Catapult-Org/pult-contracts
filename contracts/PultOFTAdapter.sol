// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { Fee } from "@layerzerolabs/oft-evm/contracts/Fee.sol";

/**
 * @title PultOFTAdapter
 * @notice LayerZero V2 OFTAdapter with an optional protocol fee for the already-deployed PULT (CatapultTrade)
 *         token on BSC.
 *
 * @dev Locks PULT on BSC and instructs the PultOFT peer on Robinhood Chain to mint the same amount
 *      (and unlocks PULT when the peer burns). PULT is a plain OpenZeppelin ERC20 (no transfer fee),
 *      so the lossless lock/unlock accounting is correct.
 * @dev Fee model mirrors LayerZero's `OFTAdapterFeeUpgradeable`:
 *      - `defaultFeeBps` applies to every destination, `setFeeBps(dstEid, bps, enabled)` overrides per destination;
 *      - the fee (plus the de-dust remainder) is taken from the sender on the *source* chain and accumulated in
 *        `feeBalance`; `withdrawFees(to)` lets the owner pull only that balance, never the tokens backing the peer;
 *      - with all fees at 0 (the default) behaviour is identical to the default OFTAdapter.
 * @dev Invariant: `token.balanceOf(adapter) == PultOFT.totalSupply() + feeBalance`.
 * @dev WARNING: exactly ONE OFTAdapter must exist for PULT across the whole LayerZero mesh.
 * @dev Token: 0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154 (BSC mainnet).
 */
contract PultOFTAdapter is OFTAdapter, Fee {
    using SafeERC20 for IERC20;

    /// @notice Fees (in local decimals) accumulated in this contract and withdrawable by the owner.
    uint256 public feeBalance;

    event FeeWithdrawn(address indexed to, uint256 amountLD);

    error NoFeesToWithdraw();

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
        uint256 balance = feeBalance;
        if (balance == 0) revert NoFeesToWithdraw();

        feeBalance = 0;
        innerToken.safeTransfer(_to, balance);
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

        innerToken.safeTransferFrom(_from, address(this), amountSentLD);
    }
}
