// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { CatapultTrade } from "../../contracts/CatapultTrade.sol";
import { PultOFTAdapter } from "../../contracts/PultOFTAdapter.sol";
import { PultOFT } from "../../contracts/PultOFT.sol";
import { OFTComposerMock } from "../mocks/OFTComposerMock.sol";

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { ILayerZeroEndpointV2, Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { PacketV1Codec } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import { DoubleEndedQueue } from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

import "forge-std/console.sol";

/**
 * Profiles `EndpointV2.lzReceive` gas (what the LayerZero Executor forwards from the enforced LZ_RECEIVE
 * option: Executor.execute302 -> endpoint.lzReceive{ gas: gasLimit }) for every receive path of the PULT mesh,
 * using the production contracts and the real endpoint + ULN from TestHelperOz5.
 *
 * Worst cases are the FIRST message on a pathway (cold nonce / payload slots) delivered to a recipient with a
 * zero balance. Thresholds below must stay in sync with the enforced options in layerzero.config.ts.
 */
contract PultBridgeGasTest is TestHelperOz5 {
    using OptionsBuilder for bytes;
    using PacketV1Codec for bytes;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    uint32 private constant BSC_EID = 1;
    uint32 private constant ROBINHOOD_EID = 2;

    // keep in sync with layerzero.config.ts
    uint256 private constant ENFORCED_GAS_SEND = 120_000; // msgType 1
    uint256 private constant ENFORCED_GAS_SEND_AND_CALL = 150_000; // msgType 2
    uint256 private constant HEADROOM_BPS = 2_500; // require >= 25% spare gas

    CatapultTrade private pult;
    PultOFTAdapter private adapter;
    PultOFT private oft;

    address private userA = makeAddr("userA");
    address private fresh = makeAddr("fresh");

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(fresh, 1000 ether);
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        pult = new CatapultTrade(address(this), address(this));
        adapter = PultOFTAdapter(
            _deployOApp(
                type(PultOFTAdapter).creationCode,
                abi.encode(address(pult), address(endpoints[BSC_EID]), address(this))
            )
        );
        oft = PultOFT(
            _deployOApp(
                type(PultOFT).creationCode,
                abi.encode("Catapult Trade", "PULT", address(endpoints[ROBINHOOD_EID]), address(this))
            )
        );
        address[] memory oapps = new address[](2);
        oapps[0] = address(adapter);
        oapps[1] = address(oft);
        this.wireOApps(oapps);

        pult.transfer(userA, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev pops the next queued packet for `dst` and executes it via the real endpoint, returning gas used
    ///      by the `lzReceive` call as seen by the caller (includes CALL overhead: conservative).
    function _executeNext(uint32 dstEid, address dst) internal returns (uint256 gasUsed) {
        DoubleEndedQueue.Bytes32Deque storage queue = packetsQueue[dstEid][addressToBytes32(dst)];
        bytes32 guid = queue.popBack();
        bytes memory packetBytes = packets[guid];
        this.validatePacket(packetBytes, "");

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(endpoints[dstEid]);
        (Origin memory origin, address receiver, bytes memory message) = this.parsePacket(packetBytes);

        uint256 before = gasleft();
        endpoint.lzReceive(origin, receiver, guid, message, "");
        gasUsed = before - gasleft();
    }

    function parsePacket(
        bytes calldata packetBytes
    ) external pure returns (Origin memory origin, address receiver, bytes memory message) {
        origin = Origin(packetBytes.srcEid(), packetBytes.sender(), packetBytes.nonce());
        receiver = packetBytes.receiverB20();
        message = packetBytes.message();
    }

    function _send(address from, address to, uint32 dstEid, uint256 amount, bytes memory composeMsg) internal {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(500000, 0);
        if (composeMsg.length > 0) options = options.addExecutorLzComposeOption(0, 500000, 0);
        SendParam memory sp = SendParam(dstEid, addressToBytes32(to), amount, amount, options, composeMsg, "");
        if (dstEid == ROBINHOOD_EID) {
            MessagingFee memory fee = adapter.quoteSend(sp, false);
            vm.startPrank(from);
            pult.approve(address(adapter), amount);
            adapter.send{ value: fee.nativeFee }(sp, fee, payable(from));
            vm.stopPrank();
        } else {
            MessagingFee memory fee = oft.quoteSend(sp, false);
            vm.prank(from);
            oft.send{ value: fee.nativeFee }(sp, fee, payable(from));
        }
    }

    function _assertHeadroom(uint256 used, uint256 enforced, string memory label) internal pure {
        console.log("lzReceive gas | %s: %d (enforced %d)", label, used, enforced);
        assertLe(used + (used * HEADROOM_BPS) / 10_000, enforced, label);
    }

    // ------------------------------------------------------------------ msgType 1 (SEND)

    function test_gas_first_mint_to_fresh_recipient() public {
        _send(userA, fresh, ROBINHOOD_EID, 1 ether, "");
        uint256 g = _executeNext(ROBINHOOD_EID, address(oft));
        _assertHeadroom(g, ENFORCED_GAS_SEND, "Robinhood mint, first message, fresh recipient");
    }

    function test_gas_subsequent_mint_to_fresh_recipient() public {
        _send(userA, userA, ROBINHOOD_EID, 1 ether, "");
        _executeNext(ROBINHOOD_EID, address(oft));
        _send(userA, fresh, ROBINHOOD_EID, 1 ether, "");
        uint256 g = _executeNext(ROBINHOOD_EID, address(oft));
        _assertHeadroom(g, ENFORCED_GAS_SEND, "Robinhood mint, warm pathway, fresh recipient");
    }

    function test_gas_first_unlock_to_fresh_recipient() public {
        _send(userA, userA, ROBINHOOD_EID, 10 ether, "");
        _executeNext(ROBINHOOD_EID, address(oft));

        _send(userA, fresh, BSC_EID, 1 ether, "");
        uint256 g = _executeNext(BSC_EID, address(adapter));
        _assertHeadroom(g, ENFORCED_GAS_SEND, "BSC unlock, first message, fresh recipient");
    }

    // ------------------------------------------------------------------ msgType 2 (SEND_AND_CALL)

    function test_gas_first_mint_with_compose_to_fresh_recipient() public {
        OFTComposerMock composer = new OFTComposerMock();
        _send(userA, address(composer), ROBINHOOD_EID, 1 ether, hex"1234");
        uint256 g = _executeNext(ROBINHOOD_EID, address(oft));
        _assertHeadroom(g, ENFORCED_GAS_SEND_AND_CALL, "Robinhood mint + compose, first message, fresh recipient");
    }

    function test_gas_first_unlock_with_compose_to_fresh_recipient() public {
        _send(userA, userA, ROBINHOOD_EID, 10 ether, "");
        _executeNext(ROBINHOOD_EID, address(oft));

        OFTComposerMock composer = new OFTComposerMock();
        _send(userA, address(composer), BSC_EID, 1 ether, hex"1234");
        uint256 g = _executeNext(BSC_EID, address(adapter));
        _assertHeadroom(g, ENFORCED_GAS_SEND_AND_CALL, "BSC unlock + compose, first message, fresh recipient");
    }
}
