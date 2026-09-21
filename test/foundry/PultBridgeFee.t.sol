// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { CatapultTrade } from "../../contracts/CatapultTrade.sol";
import { PultOFTAdapterMock } from "../mocks/PultOFTAdapterMock.sol";
import { PultOFTMock } from "../mocks/PultOFTMock.sol";
import { PultOFTAdapter } from "../../contracts/PultOFTAdapter.sol";
import { PultOFT } from "../../contracts/PultOFT.sol";

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, OFTReceipt, OFTLimit, OFTFeeDetail } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IFee.sol";
import { MessagingFee } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

/**
 * Fee behaviour of PultOFTAdapter (eid 1, "BSC") and PultOFT (eid 2, "Robinhood").
 * Fee semantics follow LayerZero's OFTAdapterFeeUpgradeable / OFTFeeUpgradeable:
 *   amountSentLD = amount; amountReceivedLD = removeDust(amount - amount * bps / 10_000); fee + dust -> feeBalance.
 */
contract PultBridgeFeeTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private constant BSC_EID = 1;
    uint32 private constant ROBINHOOD_EID = 2;
    uint16 private constant BPS = 10_000;
    uint256 private constant CONVERSION_RATE = 1e12;

    CatapultTrade private pult;
    PultOFTAdapterMock private adapter;
    PultOFTMock private oft;

    address private userA = makeAddr("userA");
    address private userB = makeAddr("userB");
    address private treasury = makeAddr("treasury");
    uint256 private initialBalance = 100 ether;

    event FeeWithdrawn(address indexed to, uint256 amountLD);

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);
        vm.deal(treasury, 1000 ether);
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        pult = new CatapultTrade(address(this), address(this));
        adapter = PultOFTAdapterMock(
            _deployOApp(
                type(PultOFTAdapterMock).creationCode,
                abi.encode(address(pult), address(endpoints[BSC_EID]), address(this))
            )
        );
        oft = PultOFTMock(
            _deployOApp(
                type(PultOFTMock).creationCode,
                abi.encode("Catapult Trade", "PULT", address(endpoints[ROBINHOOD_EID]), address(this))
            )
        );
        address[] memory oapps = new address[](2);
        oapps[0] = address(adapter);
        oapps[1] = address(oft);
        this.wireOApps(oapps);

        pult.transfer(userA, initialBalance);
    }

    // ------------------------------------------------------------------ helpers

    function _sendParam(
        uint32 dstEid,
        address to,
        uint256 amount,
        uint256 minAmount
    ) internal pure returns (SendParam memory) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        return SendParam(dstEid, addressToBytes32(to), amount, minAmount, options, "", "");
    }

    function _expectedReceived(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return ((amount - (amount * bps) / BPS) / CONVERSION_RATE) * CONVERSION_RATE;
    }

    function _bridgeToRobinhood(address from, address to, uint256 amount) internal returns (OFTReceipt memory receipt) {
        SendParam memory sp = _sendParam(ROBINHOOD_EID, to, amount, 0);
        MessagingFee memory fee = adapter.quoteSend(sp, false);
        vm.startPrank(from);
        pult.approve(address(adapter), amount);
        (, receipt) = adapter.send{ value: fee.nativeFee }(sp, fee, payable(from));
        vm.stopPrank();
        verifyPackets(ROBINHOOD_EID, addressToBytes32(address(oft)));
    }

    function _bridgeToBsc(address from, address to, uint256 amount) internal returns (OFTReceipt memory receipt) {
        SendParam memory sp = _sendParam(BSC_EID, to, amount, 0);
        MessagingFee memory fee = oft.quoteSend(sp, false);
        vm.prank(from);
        (, receipt) = oft.send{ value: fee.nativeFee }(sp, fee, payable(from));
        verifyPackets(BSC_EID, addressToBytes32(address(adapter)));
    }

    /// @dev PULT locked in the adapter backs both the remote supply and the adapter's own fee balance.
    function _assertInvariant() internal view {
        assertEq(pult.balanceOf(address(adapter)), oft.totalSupply() + adapter.feeBalance(), "backing invariant");
        assertEq(oft.balanceOf(address(oft)), oft.feeBalance(), "oft fee balance == self balance");
    }

    // ------------------------------------------------------------------ configuration

    function test_fee_defaults_to_zero() public view {
        assertEq(adapter.defaultFeeBps(), 0);
        assertEq(oft.defaultFeeBps(), 0);
        assertEq(adapter.getFee(ROBINHOOD_EID, 1 ether), 0);
        assertEq(oft.getFee(BSC_EID, 1 ether), 0);
        (uint16 bps, bool enabled) = adapter.feeBps(ROBINHOOD_EID);
        assertEq(bps, 0);
        assertFalse(enabled);
        assertEq(adapter.feeBalance(), 0);
        assertEq(oft.feeBalance(), 0);
    }

    function test_setDefaultFeeBps() public {
        vm.expectEmit(true, true, true, true);
        emit IFee.DefaultFeeBpsSet(150);
        adapter.setDefaultFeeBps(150);
        assertEq(adapter.defaultFeeBps(), 150);
        assertEq(adapter.getFee(ROBINHOOD_EID, 1 ether), 0.015 ether);

        // upper bound is 100%
        adapter.setDefaultFeeBps(BPS);
        vm.expectRevert(IFee.InvalidBps.selector);
        adapter.setDefaultFeeBps(BPS + 1);
    }

    function test_setFeeBps_per_destination_overrides_default() public {
        adapter.setDefaultFeeBps(100);
        vm.expectEmit(true, true, true, true);
        emit IFee.FeeBpsSet(ROBINHOOD_EID, 30, true);
        adapter.setFeeBps(ROBINHOOD_EID, 30, true);
        assertEq(adapter.getFee(ROBINHOOD_EID, 1 ether), 0.003 ether);
        assertEq(adapter.getFee(99, 1 ether), 0.01 ether); // other destinations keep the default

        // disabled override falls back to the default (even with a non-zero stored bps)
        adapter.setFeeBps(ROBINHOOD_EID, 30, false);
        assertEq(adapter.getFee(ROBINHOOD_EID, 1 ether), 0.01 ether);

        // explicit zero-fee override for one destination
        adapter.setFeeBps(ROBINHOOD_EID, 0, true);
        assertEq(adapter.getFee(ROBINHOOD_EID, 1 ether), 0);

        vm.expectRevert(IFee.InvalidBps.selector);
        adapter.setFeeBps(ROBINHOOD_EID, BPS + 1, true);
    }

    function test_fee_setters_only_owner() public {
        vm.startPrank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        adapter.setDefaultFeeBps(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        adapter.setFeeBps(ROBINHOOD_EID, 1, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        oft.setDefaultFeeBps(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        oft.setFeeBps(BSC_EID, 1, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        adapter.withdrawFees(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        oft.withdrawFees(userA);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ BSC -> Robinhood with fee

    function test_send_bsc_to_robinhood_with_fee() public {
        adapter.setDefaultFeeBps(100); // 1%
        uint256 amount = 10 ether + 123456789; // includes dust
        uint256 expected = _expectedReceived(amount, 100); // 9.9 ether

        OFTReceipt memory receipt = _bridgeToRobinhood(userA, userB, amount);

        assertEq(receipt.amountSentLD, amount, "full amount debited");
        assertEq(receipt.amountReceivedLD, expected, "fee and dust removed");
        assertEq(pult.balanceOf(userA), initialBalance - amount);
        assertEq(pult.balanceOf(address(adapter)), amount);
        assertEq(adapter.feeBalance(), amount - expected, "fee + dust accrued");
        assertEq(oft.balanceOf(userB), expected);
        assertEq(oft.totalSupply(), expected);
        _assertInvariant();
    }

    function test_quoteOFT_and_quoteSend_reflect_fee() public {
        adapter.setDefaultFeeBps(250); // 2.5%
        uint256 amount = 4 ether;
        SendParam memory sp = _sendParam(ROBINHOOD_EID, userB, amount, 0);

        (OFTLimit memory limit, OFTFeeDetail[] memory details, OFTReceipt memory receipt) = adapter.quoteOFT(sp);
        assertEq(receipt.amountSentLD, amount);
        assertEq(receipt.amountReceivedLD, 3.9 ether);
        assertEq(details.length, 0);
        assertEq(limit.maxAmountLD, pult.totalSupply());

        // quoteSend uses the same view path and must not revert with minAmount below the net amount
        sp.minAmountLD = 3.9 ether;
        MessagingFee memory fee = adapter.quoteSend(sp, false);
        assertGt(fee.nativeFee, 0);
    }

    function test_send_reverts_when_fee_breaks_min_amount() public {
        adapter.setDefaultFeeBps(100);
        uint256 amount = 1 ether;
        SendParam memory sp = _sendParam(ROBINHOOD_EID, userB, amount, amount); // user did not account for the fee

        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 0.99 ether, amount));
        adapter.quoteSend(sp, false);

        vm.startPrank(userA);
        pult.approve(address(adapter), amount);
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 0.99 ether, amount));
        adapter.send{ value: 1 ether }(sp, MessagingFee(1 ether, 0), payable(userA));
        vm.stopPrank();
    }

    function test_zero_fee_matches_default_oft_behaviour() public {
        uint256 amount = 5 ether + 1; // dust only
        OFTReceipt memory receipt = _bridgeToRobinhood(userA, userB, amount);
        assertEq(receipt.amountSentLD, amount);
        assertEq(receipt.amountReceivedLD, 5 ether);
        // without a fee the dust remainder still accrues to feeBalance (LayerZero reference semantics)
        assertEq(adapter.feeBalance(), 1);
        assertEq(oft.balanceOf(userB), 5 ether);
        _assertInvariant();
    }

    // ------------------------------------------------------------------ Robinhood -> BSC with fee

    function test_send_robinhood_to_bsc_with_fee() public {
        _bridgeToRobinhood(userA, userB, 10 ether);
        oft.setDefaultFeeBps(200); // 2%

        uint256 amount = 4 ether + 5; // includes dust
        uint256 expected = _expectedReceived(amount, 200); // 3.92 ether
        uint256 feeTaken = amount - expected;

        OFTReceipt memory receipt = _bridgeToBsc(userB, userA, amount);

        assertEq(receipt.amountSentLD, amount);
        assertEq(receipt.amountReceivedLD, expected);
        assertEq(oft.balanceOf(userB), 10 ether - amount, "sender pays the full amount");
        assertEq(oft.balanceOf(address(oft)), feeTaken, "fee tokens held by the OFT");
        assertEq(oft.feeBalance(), feeTaken);
        assertEq(oft.totalSupply(), 10 ether - expected, "only the net amount is burned");
        assertEq(pult.balanceOf(userA), initialBalance - 10 ether + expected, "net amount unlocked on BSC");
        assertEq(pult.balanceOf(address(adapter)), 10 ether - expected);
        _assertInvariant();
    }

    // ------------------------------------------------------------------ withdrawals

    function test_withdrawFees_adapter() public {
        vm.expectRevert(PultOFTAdapter.NoFeesToWithdraw.selector);
        adapter.withdrawFees(treasury);

        adapter.setDefaultFeeBps(100);
        _bridgeToRobinhood(userA, userB, 10 ether);
        uint256 accrued = adapter.feeBalance();
        assertEq(accrued, 0.1 ether);

        vm.expectEmit(true, true, true, true);
        emit FeeWithdrawn(treasury, accrued);
        adapter.withdrawFees(treasury);

        assertEq(pult.balanceOf(treasury), accrued);
        assertEq(adapter.feeBalance(), 0);
        // locked backing is untouched
        assertEq(pult.balanceOf(address(adapter)), oft.totalSupply());
        _assertInvariant();

        vm.expectRevert(PultOFTAdapter.NoFeesToWithdraw.selector);
        adapter.withdrawFees(treasury);
    }

    function test_withdrawFees_oft() public {
        _bridgeToRobinhood(userA, userB, 10 ether);
        oft.setDefaultFeeBps(500); // 5%

        vm.expectRevert(PultOFT.NoFeesToWithdraw.selector);
        oft.withdrawFees(treasury);

        _bridgeToBsc(userB, userA, 2 ether);
        uint256 accrued = oft.feeBalance();
        assertEq(accrued, 0.1 ether);

        vm.expectEmit(true, true, true, true);
        emit FeeWithdrawn(treasury, accrued);
        oft.withdrawFees(treasury);

        assertEq(oft.balanceOf(treasury), accrued);
        assertEq(oft.balanceOf(address(oft)), 0);
        assertEq(oft.feeBalance(), 0);
        // withdrawn fee tokens stay backed and can be bridged back to BSC
        _assertInvariant();
        _bridgeToBsc(treasury, treasury, accrued);
        assertEq(pult.balanceOf(treasury), _expectedReceived(accrued, 500));
        _assertInvariant();
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_fee_round_trip_keeps_backing_invariant(
        uint96 rawAmount,
        uint16 adapterBps,
        uint16 oftBps
    ) public {
        adapterBps = uint16(bound(adapterBps, 0, 5_000));
        oftBps = uint16(bound(oftBps, 0, 5_000));
        uint256 amount = bound(uint256(rawAmount), 2 * CONVERSION_RATE, initialBalance);
        adapter.setDefaultFeeBps(adapterBps);
        oft.setDefaultFeeBps(oftBps);

        OFTReceipt memory r1 = _bridgeToRobinhood(userA, userB, amount);
        assertEq(r1.amountReceivedLD, _expectedReceived(amount, adapterBps));
        assertEq(adapter.feeBalance(), amount - r1.amountReceivedLD);
        _assertInvariant();

        uint256 back = r1.amountReceivedLD;
        if (back >= CONVERSION_RATE) {
            OFTReceipt memory r2 = _bridgeToBsc(userB, userA, back);
            assertEq(r2.amountReceivedLD, _expectedReceived(back, oftBps));
            assertEq(oft.feeBalance(), back - r2.amountReceivedLD);
            _assertInvariant();
        }
    }
}
