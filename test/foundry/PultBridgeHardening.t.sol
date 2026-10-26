// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Regression tests for the independent pre-audit review (F-01 .. F-05: proven, then fixed) plus properties checked
// and found correct. Production contracts, real endpoint + ULN via TestHelperOz5, same three-chain mesh as
// PultBridgeMesh.t.sol:
//   eid 1 ("BSC") -> CatapultTrade + PultOFTAdapter, eid 2 ("Robinhood") / eid 3 ("Arbitrum") -> PultOFT.

import { CatapultTrade } from "../../contracts/CatapultTrade.sol";
import { PultOFTAdapter } from "../../contracts/PultOFTAdapter.sol";
import { PultOFT } from "../../contracts/PultOFT.sol";

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { InboundPacket } from "@layerzerolabs/oapp-evm/contracts/precrime/libs/Packet.sol";
import { IOFT, SendParam, OFTReceipt, OFTLimit, OFTFeeDetail } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { ILayerZeroEndpointV2, Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { PacketV1Codec } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import { Errors } from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { DoubleEndedQueue } from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

/// @dev `delegates` is a public mapping on EndpointV2 that is not part of ILayerZeroEndpointV2.
interface IEndpointDelegates {
    function delegates(address oapp) external view returns (address);
}

contract PultBridgeHardeningTest is TestHelperOz5 {
    using OptionsBuilder for bytes;
    using PacketV1Codec for bytes;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    uint32 private constant BSC_EID = 1;
    uint32 private constant ROBINHOOD_EID = 2;
    uint32 private constant ARBITRUM_EID = 3;
    uint16 private constant MAX_FEE_BPS = 500;
    uint256 private constant CONVERSION_RATE = 1e12;

    CatapultTrade private pult;
    PultOFTAdapter private adapter;
    PultOFT private oftRobinhood;
    PultOFT private oftArbitrum;

    address private userA = makeAddr("userA");
    address private userB = makeAddr("userB");
    address private treasury = makeAddr("treasury");
    address private attacker = makeAddr("attacker");

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);
        vm.deal(treasury, 1000 ether);
        vm.deal(attacker, 1000 ether);

        super.setUp();
        setUpEndpoints(3, LibraryType.UltraLightNode);

        pult = new CatapultTrade(address(this), address(this));
        adapter = PultOFTAdapter(
            _deployOApp(
                type(PultOFTAdapter).creationCode,
                abi.encode(address(pult), address(endpoints[BSC_EID]), address(this))
            )
        );
        oftRobinhood = PultOFT(
            _deployOApp(
                type(PultOFT).creationCode,
                abi.encode("Catapult Trade", "PULT", address(endpoints[ROBINHOOD_EID]), address(this))
            )
        );
        oftArbitrum = PultOFT(
            _deployOApp(
                type(PultOFT).creationCode,
                abi.encode("Catapult Trade", "PULT", address(endpoints[ARBITRUM_EID]), address(this))
            )
        );

        address[] memory oapps = new address[](3);
        oapps[0] = address(adapter);
        oapps[1] = address(oftRobinhood);
        oapps[2] = address(oftArbitrum);
        this.wireOApps(oapps);

        pult.transfer(userA, 1_000 ether);
        pult.transfer(userB, 1_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _app(uint32 eid) internal view returns (IOFT) {
        if (eid == BSC_EID) return IOFT(address(adapter));
        if (eid == ROBINHOOD_EID) return IOFT(address(oftRobinhood));
        return IOFT(address(oftArbitrum));
    }

    function _sp(
        uint32 dstEid,
        bytes32 to,
        uint256 amount,
        uint256 minAmount
    ) internal pure returns (SendParam memory) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        return SendParam(dstEid, to, amount, minAmount, options, "", "");
    }

    /// @dev quote + send on the source only; the packet stays queued (not verified, not executed).
    function _send(
        uint32 srcEid,
        address from,
        SendParam memory sp
    ) internal returns (MessagingReceipt memory m, OFTReceipt memory r) {
        IOFT app = _app(srcEid);
        MessagingFee memory fee = app.quoteSend(sp, false);
        vm.startPrank(from);
        if (srcEid == BSC_EID) pult.approve(address(adapter), sp.amountLD);
        (m, r) = app.send{ value: fee.nativeFee }(sp, fee, payable(from));
        vm.stopPrank();
    }

    /// @dev send + verify + execute.
    function _bridge(
        uint32 srcEid,
        uint32 dstEid,
        address from,
        bytes32 to,
        uint256 amount
    ) internal returns (OFTReceipt memory r) {
        (, r) = _send(srcEid, from, _sp(dstEid, to, amount, 0));
        verifyPackets(dstEid, addressToBytes32(address(_app(dstEid))));
    }

    function _popPacket(uint32 dstEid, address dst) internal returns (bytes memory packetBytes) {
        DoubleEndedQueue.Bytes32Deque storage queue = packetsQueue[dstEid][addressToBytes32(dst)];
        bytes32 guid = queue.popBack();
        packetBytes = packets[guid];
    }

    function parsePacket(
        bytes calldata p
    ) external pure returns (Origin memory origin, address receiver, bytes32 guid, bytes memory message) {
        origin = Origin(p.srcEid(), p.sender(), p.nonce());
        receiver = p.receiverB20();
        guid = p.guid();
        message = p.message();
    }

    function _lockboxExcess() internal view returns (uint256) {
        return
            pult.balanceOf(address(adapter)) -
            oftRobinhood.totalSupply() -
            oftArbitrum.totalSupply() -
            adapter.feeBalance();
    }

    // ================================================================== F-01: withdrawFees(to) validation (fixed)

    function test_F01_withdrawFees_rejects_self_and_zero_on_oft() public {
        _bridge(BSC_EID, ROBINHOOD_EID, userA, addressToBytes32(userA), 10 ether);
        oftRobinhood.setDefaultFeeBps(MAX_FEE_BPS);
        _bridge(ROBINHOOD_EID, ARBITRUM_EID, userA, addressToBytes32(userA), 2 ether);
        assertEq(oftRobinhood.feeBalance(), 0.1 ether);

        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.withdrawFees(address(oftRobinhood));
        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.withdrawFees(address(0));
        assertEq(oftRobinhood.feeBalance(), 0.1 ether, "untouched by the rejected calls");

        oftRobinhood.withdrawFees(treasury);
        assertEq(oftRobinhood.balanceOf(treasury), 0.1 ether);
        assertEq(oftRobinhood.balanceOf(address(oftRobinhood)), oftRobinhood.feeBalance());
    }

    function test_F01_withdrawFees_rejects_self_and_zero_on_adapter() public {
        adapter.setDefaultFeeBps(100);
        _bridge(BSC_EID, ROBINHOOD_EID, userA, addressToBytes32(userA), 10 ether);
        assertEq(adapter.feeBalance(), 0.1 ether);

        vm.expectRevert(PultOFTAdapter.InvalidRecipient.selector);
        adapter.withdrawFees(address(adapter));
        vm.expectRevert(PultOFTAdapter.InvalidRecipient.selector);
        adapter.withdrawFees(address(0));
        assertEq(adapter.feeBalance(), 0.1 ether);

        adapter.withdrawFees(treasury);
        assertEq(pult.balanceOf(treasury), 0.1 ether);
        assertEq(_lockboxExcess(), 0);
    }

    // ================================================================== F-02: recipient == bridge contract (fixed)

    function test_F02_recipient_equal_to_destination_oft_is_rejected_at_quote_and_send() public {
        SendParam memory sp = _sp(ROBINHOOD_EID, addressToBytes32(address(oftRobinhood)), 3 ether, 0);

        vm.expectRevert(PultOFTAdapter.InvalidRecipient.selector);
        adapter.quoteOFT(sp);
        vm.expectRevert(PultOFTAdapter.InvalidRecipient.selector);
        adapter.quoteSend(sp, false);

        vm.startPrank(userA);
        pult.approve(address(adapter), 3 ether);
        vm.expectRevert(PultOFTAdapter.InvalidRecipient.selector);
        adapter.send{ value: 1 ether }(sp, MessagingFee(1 ether, 0), payable(userA));
        vm.stopPrank();

        assertEq(pult.balanceOf(address(adapter)), 0, "nothing locked");
        assertEq(oftRobinhood.totalSupply(), 0);
    }

    function test_F02_recipient_equal_to_adapter_is_rejected_on_the_oft() public {
        _bridge(BSC_EID, ROBINHOOD_EID, userA, addressToBytes32(userA), 10 ether);
        SendParam memory sp = _sp(BSC_EID, addressToBytes32(address(adapter)), 4 ether, 0);

        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.quoteOFT(sp);
        vm.prank(userA);
        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.send{ value: 1 ether }(sp, MessagingFee(1 ether, 0), payable(userA));

        assertEq(oftRobinhood.balanceOf(userA), 10 ether, "nothing burned");
        assertEq(_lockboxExcess(), 0);
    }

    function test_F02_oft_to_oft_peer_as_recipient_is_rejected() public {
        _bridge(BSC_EID, ROBINHOOD_EID, userA, addressToBytes32(userA), 10 ether);
        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.quoteSend(_sp(ARBITRUM_EID, addressToBytes32(address(oftArbitrum)), 1 ether, 0), false);
    }

    // ================================================================== F-03: recipient == bytes32(0) (fixed)

    function test_F03_recipient_zero_is_rejected_in_every_direction() public {
        _bridge(BSC_EID, ROBINHOOD_EID, userA, addressToBytes32(userA), 10 ether);

        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.quoteOFT(_sp(BSC_EID, bytes32(0), 4 ether, 0));
        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.quoteSend(_sp(ARBITRUM_EID, bytes32(0), 4 ether, 0), false);
        vm.prank(userA);
        vm.expectRevert(PultOFT.InvalidRecipient.selector);
        oftRobinhood.send{ value: 1 ether }(
            _sp(BSC_EID, bytes32(0), 4 ether, 0),
            MessagingFee(1 ether, 0),
            payable(userA)
        );

        vm.expectRevert(PultOFTAdapter.InvalidRecipient.selector);
        adapter.quoteSend(_sp(ROBINHOOD_EID, bytes32(0), 1 ether, 0), false);

        assertEq(oftRobinhood.balanceOf(userA), 10 ether, "nothing burned");
        assertEq(oftRobinhood.balanceOf(address(0xdead)), 0);
        assertEq(_lockboxExcess(), 0);
    }

    function test_F02_F03_composer_recipient_still_allowed() public {
        // a recipient that is a contract other than the peer (e.g. a composer) is fine
        address composer = makeAddr("composer");
        OFTReceipt memory r = _bridge(BSC_EID, ARBITRUM_EID, userA, addressToBytes32(composer), 1 ether);
        assertEq(r.amountReceivedLD, 1 ether);
        assertEq(oftArbitrum.balanceOf(composer), 1 ether);
    }

    // ================================================================== F-04: delegate can drop a verified transfer
    // Inherent to LayerZero (documented in AUDIT.md §3); mitigated by a multisig owner + delegate.

    function test_F04_delegate_can_clear_a_verified_inbound_transfer() public {
        _send(BSC_EID, userA, _sp(ROBINHOOD_EID, addressToBytes32(userA), 5 ether, 0));
        assertEq(pult.balanceOf(address(adapter)), 5 ether);

        bytes memory pk = _popPacket(ROBINHOOD_EID, address(oftRobinhood));
        this.validatePacket(pk, ""); // verified: anyone could execute it now
        (Origin memory o, address recv, bytes32 g, bytes memory m) = this.parsePacket(pk);
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoints[ROBINHOOD_EID]);
        assertEq(IEndpointDelegates(endpoints[ROBINHOOD_EID]).delegates(address(oftRobinhood)), address(this));

        vm.prank(attacker);
        vm.expectRevert(Errors.LZ_Unauthorized.selector);
        ep.clear(address(oftRobinhood), o, g, m);

        // the OApp delegate (== owner key) drops the verified packet without crediting anyone
        ep.clear(address(oftRobinhood), o, g, m);

        // the stored hash is now 0: the packet can never be executed again
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_PayloadHashNotFound.selector,
                bytes32(0),
                keccak256(abi.encodePacked(g, m))
            )
        );
        ep.lzReceive(o, recv, g, m, "");

        assertEq(oftRobinhood.balanceOf(userA), 0, "never credited");
        assertEq(pult.balanceOf(address(adapter)), 5 ether, "still locked");
        assertEq(_lockboxExcess(), 5 ether, "unbacked excess nobody can unlock");
    }

    // ================================================================== F-05: sends that net to zero (fixed)

    function test_F05_send_that_would_deliver_nothing_reverts() public {
        adapter.setDefaultFeeBps(MAX_FEE_BPS);

        // one shared unit at 5 %: 1e12 - 5e10 de-dusts to 0 -> rejected at quote and at send
        uint256 amount = CONVERSION_RATE;
        SendParam memory sp = _sp(ARBITRUM_EID, addressToBytes32(userB), amount, 0);
        vm.expectRevert(abi.encodeWithSelector(PultOFTAdapter.AmountTooSmall.selector, amount));
        adapter.quoteOFT(sp);

        uint256 before = pult.balanceOf(userA);
        vm.startPrank(userA);
        pult.approve(address(adapter), amount);
        vm.expectRevert(abi.encodeWithSelector(PultOFTAdapter.AmountTooSmall.selector, amount));
        adapter.send{ value: 1 ether }(sp, MessagingFee(1 ether, 0), payable(userA));
        vm.stopPrank();
        assertEq(pult.balanceOf(userA), before, "user keeps the tokens");
        assertEq(adapter.feeBalance(), 0);

        // sub-dust and zero amounts without any fee are rejected as well
        adapter.setDefaultFeeBps(0);
        vm.expectRevert(abi.encodeWithSelector(PultOFTAdapter.AmountTooSmall.selector, CONVERSION_RATE - 1));
        adapter.quoteOFT(_sp(ARBITRUM_EID, addressToBytes32(userB), CONVERSION_RATE - 1, 0));
        vm.expectRevert(abi.encodeWithSelector(PultOFTAdapter.AmountTooSmall.selector, 0));
        adapter.quoteSend(_sp(ARBITRUM_EID, addressToBytes32(userB), 0, 0), false);

        // the same guard on the OFT side
        _bridge(BSC_EID, ROBINHOOD_EID, userA, addressToBytes32(userA), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PultOFT.AmountTooSmall.selector, 1));
        oftRobinhood.quoteOFT(_sp(BSC_EID, addressToBytes32(userA), 1, 0));

        // smallest amount that delivers at 5 %: two units -> one unit arrives (documented effective rate)
        adapter.setDefaultFeeBps(MAX_FEE_BPS);
        (, , OFTReceipt memory q) = adapter.quoteOFT(
            _sp(ARBITRUM_EID, addressToBytes32(userB), 2 * CONVERSION_RATE, 0)
        );
        assertEq(q.amountReceivedLD, CONVERSION_RATE);
    }

    // ================================================================== checked and found correct

    function test_fee_raise_between_quote_and_send_is_bounded_by_cap() public {
        SendParam memory sp = _sp(ROBINHOOD_EID, addressToBytes32(userA), 100 ether, 0);
        (, , OFTReceipt memory quoted) = adapter.quoteOFT(sp);
        assertEq(quoted.amountReceivedLD, 100 ether);
        MessagingFee memory fee = adapter.quoteSend(sp, false);

        adapter.setDefaultFeeBps(MAX_FEE_BPS); // owner changes the fee after the user quoted

        vm.startPrank(userA);
        pult.approve(address(adapter), 100 ether);
        // minAmountLD pinned to the quote: protected
        sp.minAmountLD = quoted.amountReceivedLD;
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 95 ether, 100 ether));
        adapter.send{ value: fee.nativeFee }(sp, fee, payable(userA));
        // minAmountLD = 0: loses at most the cap
        sp.minAmountLD = 0;
        (, OFTReceipt memory r) = adapter.send{ value: fee.nativeFee }(sp, fee, payable(userA));
        vm.stopPrank();
        assertEq(r.amountReceivedLD, 95 ether);
    }

    function test_quoteOFT_reports_the_fee_in_oftFeeDetails() public {
        adapter.setDefaultFeeBps(MAX_FEE_BPS);
        (OFTLimit memory limit, OFTFeeDetail[] memory details, OFTReceipt memory r) = adapter.quoteOFT(
            _sp(ROBINHOOD_EID, addressToBytes32(userA), 100 ether + 7, 0)
        );
        assertEq(r.amountReceivedLD, 95 ether);
        assertEq(details.length, 1);
        assertEq(details[0].feeAmountLD, int256(r.amountSentLD - r.amountReceivedLD), "fee + dust");
        assertEq(details[0].description, "PULT bridge fee + dust");
        assertEq(limit.maxAmountLD, pult.totalSupply());

        // no fee and no dust -> no fee entry
        adapter.setDefaultFeeBps(0);
        (, details, ) = adapter.quoteOFT(_sp(ROBINHOOD_EID, addressToBytes32(userA), 100 ether, 0));
        assertEq(details.length, 0);

        _bridge(BSC_EID, ROBINHOOD_EID, userA, addressToBytes32(userA), 10 ether);
        oftRobinhood.setDefaultFeeBps(200);
        (limit, details, r) = oftRobinhood.quoteOFT(_sp(ARBITRUM_EID, addressToBytes32(userA), 10 ether, 0));
        assertEq(details[0].feeAmountLD, 0.2 ether);
        assertEq(limit.maxAmountLD, oftRobinhood.totalSupply());
    }

    function test_precrime_simulation_cannot_mint() public {
        // forged packet "from" the real peer, 1e12 SD = 1e24 LD to the attacker
        (bytes memory forged, ) = OFTMsgCodec.encode(addressToBytes32(attacker), uint64(1e12), "");
        InboundPacket[] memory pk = new InboundPacket[](1);
        pk[0] = InboundPacket({
            origin: Origin(BSC_EID, addressToBytes32(address(adapter)), 1),
            dstEid: ROBINHOOD_EID,
            receiver: address(oftRobinhood),
            guid: bytes32(uint256(1)),
            value: 0,
            executor: attacker,
            message: forged,
            extraData: ""
        });
        uint256 supply = oftRobinhood.totalSupply();

        vm.prank(attacker);
        vm.expectRevert();
        oftRobinhood.lzReceiveAndRevert(pk);

        assertEq(oftRobinhood.totalSupply(), supply);
        assertEq(oftRobinhood.balanceOf(attacker), 0);
    }

    function test_renounceOwnership_leaves_endpoint_delegate_in_place() public {
        IEndpointDelegates ep = IEndpointDelegates(endpoints[ROBINHOOD_EID]);
        assertEq(ep.delegates(address(oftRobinhood)), address(this));

        oftRobinhood.renounceOwnership();
        assertEq(oftRobinhood.owner(), address(0));
        assertEq(ep.delegates(address(oftRobinhood)), address(this), "delegate keeps full endpoint config power");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oftRobinhood.setDelegate(address(0));
    }

    function test_direct_transfer_to_adapter_is_not_backing_and_not_withdrawable() public {
        vm.prank(userA);
        pult.transfer(address(adapter), 7 ether);
        assertEq(_lockboxExcess(), 7 ether);
        vm.expectRevert(PultOFTAdapter.NoFeesToWithdraw.selector);
        adapter.withdrawFees(treasury);
        // and it does not let anyone mint against it: supply unchanged
        assertEq(oftRobinhood.totalSupply() + oftArbitrum.totalSupply(), 0);
    }
}
