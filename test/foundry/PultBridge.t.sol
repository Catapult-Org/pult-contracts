// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Contracts under test
import { CatapultTrade } from "../../contracts/CatapultTrade.sol";
import { PultOFTAdapterMock } from "../mocks/PultOFTAdapterMock.sol";
import { PultOFTMock } from "../mocks/PultOFTMock.sol";
import { OFTComposerMock } from "../mocks/OFTComposerMock.sol";

// OApp imports
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

// OFT imports
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

// OZ imports
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// DevTools imports
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

/**
 * Simulates the production mesh locally:
 *   eid 1 ("BSC")       -> CatapultTrade (PULT) + PultOFTAdapter
 *   eid 2 ("Robinhood") -> PultOFT
 */
contract PultBridgeTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private constant BSC_EID = 1;
    uint32 private constant ROBINHOOD_EID = 2;
    uint32 private constant UNKNOWN_EID = 3;

    uint256 private constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 private constant CONVERSION_RATE = 1e12; // 18 local decimals - 6 shared decimals

    CatapultTrade private pult;
    PultOFTAdapterMock private adapter;
    PultOFTMock private oft;

    address private userA = makeAddr("userA");
    address private userB = makeAddr("userB");
    uint256 private initialBalance = 100 ether;

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Exact copy of the BSC token: full supply to `this`, owner `this`
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

    /// @dev BSC -> Robinhood: userA locks `amount` PULT in the adapter, `to` receives PultOFT.
    function _bridgeToRobinhood(address from, address to, uint256 amount) internal returns (OFTReceipt memory receipt) {
        SendParam memory sendParam = _sendParam(ROBINHOOD_EID, to, amount, adapter.removeDust(amount));
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);

        vm.startPrank(from);
        pult.approve(address(adapter), amount);
        (, receipt) = adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(from));
        vm.stopPrank();

        verifyPackets(ROBINHOOD_EID, addressToBytes32(address(oft)));
    }

    // ------------------------------------------------------------------ token copy

    function test_token_metadata_matches_bsc_deployment() public view {
        assertEq(pult.name(), "Catapult Trade");
        assertEq(pult.symbol(), "PULT");
        assertEq(pult.decimals(), 18);
        assertEq(pult.totalSupply(), TOTAL_SUPPLY);
        assertEq(pult.owner(), address(this));
        assertEq(pult.balanceOf(address(this)), TOTAL_SUPPLY - initialBalance);
        assertEq(pult.balanceOf(userA), initialBalance);
    }

    function test_token_claimERC20_only_owner() public {
        pult.transfer(address(pult), 5 ether);
        assertEq(pult.balanceOf(address(pult)), 5 ether);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        pult.claimERC20(pult);

        uint256 before = pult.balanceOf(address(this));
        pult.claimERC20(pult);
        assertEq(pult.balanceOf(address(pult)), 0);
        assertEq(pult.balanceOf(address(this)), before + 5 ether);
    }

    // ------------------------------------------------------------------ constructor / wiring

    function test_constructor() public view {
        assertEq(adapter.owner(), address(this));
        assertEq(oft.owner(), address(this));

        // Adapter wraps the external token; OFT is its own token
        assertEq(adapter.token(), address(pult));
        assertEq(oft.token(), address(oft));
        assertTrue(adapter.approvalRequired());
        assertFalse(oft.approvalRequired());

        // Default OFT decimals: 6 shared, 18 local
        assertEq(adapter.sharedDecimals(), 6);
        assertEq(oft.sharedDecimals(), 6);
        assertEq(adapter.decimalConversionRate(), CONVERSION_RATE);
        assertEq(oft.decimalConversionRate(), CONVERSION_RATE);

        assertEq(oft.name(), "Catapult Trade");
        assertEq(oft.symbol(), "PULT");
        assertEq(oft.decimals(), 18);
        assertEq(oft.totalSupply(), 0);

        // peers set by wireOApps
        assertEq(adapter.peers(ROBINHOOD_EID), addressToBytes32(address(oft)));
        assertEq(oft.peers(BSC_EID), addressToBytes32(address(adapter)));
    }

    function test_setPeer_only_owner() public {
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        adapter.setPeer(ROBINHOOD_EID, addressToBytes32(userA));

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        oft.setPeer(BSC_EID, addressToBytes32(userA));
    }

    // ------------------------------------------------------------------ BSC -> Robinhood

    function test_send_bsc_to_robinhood() public {
        uint256 tokensToSend = 1 ether;
        SendParam memory sendParam = _sendParam(ROBINHOOD_EID, userB, tokensToSend, tokensToSend);
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);
        assertGt(fee.nativeFee, 0);
        assertEq(fee.lzTokenFee, 0);

        assertEq(pult.balanceOf(userA), initialBalance);
        assertEq(pult.balanceOf(address(adapter)), 0);
        assertEq(oft.balanceOf(userB), 0);

        vm.startPrank(userA);
        pult.approve(address(adapter), tokensToSend);
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) = adapter.send{ value: fee.nativeFee }(
            sendParam,
            fee,
            payable(userA)
        );
        vm.stopPrank();

        assertEq(oftReceipt.amountSentLD, tokensToSend);
        assertEq(oftReceipt.amountReceivedLD, tokensToSend);
        assertEq(msgReceipt.nonce, 1);

        // tokens are locked immediately on the source
        assertEq(pult.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(pult.balanceOf(address(adapter)), tokensToSend);
        assertEq(oft.balanceOf(userB), 0);

        // deliver the packet on the destination
        verifyPackets(ROBINHOOD_EID, addressToBytes32(address(oft)));

        assertEq(oft.balanceOf(userB), tokensToSend);
        assertEq(oft.totalSupply(), pult.balanceOf(address(adapter)));
    }

    function test_send_with_permit_no_separate_approve() public {
        (address alice, uint256 aliceKey) = makeAddrAndKey("alice");
        vm.deal(alice, 10 ether);
        pult.transfer(alice, 10 ether);

        uint256 tokensToSend = 2 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                address(adapter),
                tokensToSend,
                pult.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", pult.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        // anyone may submit the permit
        pult.permit(alice, address(adapter), tokensToSend, deadline, v, r, s);
        assertEq(pult.allowance(alice, address(adapter)), tokensToSend);

        SendParam memory sendParam = _sendParam(ROBINHOOD_EID, alice, tokensToSend, tokensToSend);
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);
        vm.prank(alice);
        adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(alice));
        verifyPackets(ROBINHOOD_EID, addressToBytes32(address(oft)));

        assertEq(pult.balanceOf(alice), 8 ether);
        assertEq(oft.balanceOf(alice), tokensToSend);
    }

    function test_send_removes_dust() public {
        // 1.5 PULT + 123456789 wei of dust below the 1e12 shared-decimal precision
        uint256 amountWithDust = 1.5 ether + 123456789;
        uint256 expected = 1.5 ether;
        assertEq(adapter.removeDust(amountWithDust), expected);
        assertEq(oft.removeDust(amountWithDust), expected);

        OFTReceipt memory receipt = _bridgeToRobinhood(userA, userB, amountWithDust);

        // LayerZero fee semantics: the full amount is debited, the dust remainder accrues to feeBalance
        assertEq(receipt.amountSentLD, amountWithDust);
        assertEq(receipt.amountReceivedLD, expected);
        assertEq(pult.balanceOf(userA), initialBalance - amountWithDust);
        assertEq(pult.balanceOf(address(adapter)), amountWithDust);
        assertEq(adapter.feeBalance(), amountWithDust - expected);
        assertEq(oft.balanceOf(userB), expected);
        assertEq(pult.balanceOf(address(adapter)), oft.totalSupply() + adapter.feeBalance());
    }

    function test_send_reverts_on_slippage() public {
        uint256 amountWithDust = 1 ether + 1;
        // minAmount above what survives dust removal
        SendParam memory sendParam = _sendParam(ROBINHOOD_EID, userB, amountWithDust, amountWithDust);

        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 1 ether, amountWithDust));
        adapter.quoteSend(sendParam, false);

        vm.startPrank(userA);
        pult.approve(address(adapter), amountWithDust);
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 1 ether, amountWithDust));
        adapter.send{ value: 1 ether }(sendParam, MessagingFee(1 ether, 0), payable(userA));
        vm.stopPrank();
    }

    function test_send_reverts_without_allowance() public {
        uint256 tokensToSend = 1 ether;
        SendParam memory sendParam = _sendParam(ROBINHOOD_EID, userB, tokensToSend, tokensToSend);
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);

        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), 0, tokensToSend)
        );
        adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(userA));
    }

    function test_send_reverts_for_unknown_peer() public {
        SendParam memory sendParam = _sendParam(UNKNOWN_EID, userB, 1 ether, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, UNKNOWN_EID));
        adapter.quoteSend(sendParam, false);
    }

    // ------------------------------------------------------------------ Robinhood -> BSC

    function test_send_robinhood_back_to_bsc() public {
        uint256 bridged = 10 ether;
        _bridgeToRobinhood(userA, userB, bridged);
        assertEq(oft.balanceOf(userB), bridged);
        assertEq(pult.balanceOf(address(adapter)), bridged);

        uint256 tokensBack = 4 ether;
        SendParam memory sendParam = _sendParam(BSC_EID, userA, tokensBack, tokensBack);
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        // OFT burns on send: no approval needed
        vm.prank(userB);
        (, OFTReceipt memory receipt) = oft.send{ value: fee.nativeFee }(sendParam, fee, payable(userB));
        assertEq(receipt.amountSentLD, tokensBack);

        assertEq(oft.balanceOf(userB), bridged - tokensBack);
        assertEq(oft.totalSupply(), bridged - tokensBack);
        // nothing unlocked until the packet is delivered
        assertEq(pult.balanceOf(address(adapter)), bridged);

        verifyPackets(BSC_EID, addressToBytes32(address(adapter)));

        assertEq(pult.balanceOf(address(adapter)), bridged - tokensBack);
        assertEq(pult.balanceOf(userA), initialBalance - bridged + tokensBack);
        // invariant: locked PULT == circulating PultOFT
        assertEq(oft.totalSupply(), pult.balanceOf(address(adapter)));
    }

    function test_round_trip_full_amount() public {
        uint256 amount = initialBalance;
        _bridgeToRobinhood(userA, userA, amount);
        assertEq(pult.balanceOf(userA), 0);
        assertEq(oft.balanceOf(userA), amount);

        SendParam memory sendParam = _sendParam(BSC_EID, userA, amount, amount);
        MessagingFee memory fee = oft.quoteSend(sendParam, false);
        vm.prank(userA);
        oft.send{ value: fee.nativeFee }(sendParam, fee, payable(userA));
        verifyPackets(BSC_EID, addressToBytes32(address(adapter)));

        assertEq(pult.balanceOf(userA), amount);
        assertEq(pult.balanceOf(address(adapter)), 0);
        assertEq(oft.balanceOf(userA), 0);
        assertEq(oft.totalSupply(), 0);
        assertEq(pult.totalSupply(), TOTAL_SUPPLY);
    }

    // ------------------------------------------------------------------ compose

    function test_send_bsc_to_robinhood_compose_msg() public {
        uint256 tokensToSend = 1 ether;
        OFTComposerMock composer = new OFTComposerMock();

        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200000, 0)
            .addExecutorLzComposeOption(0, 500000, 0);
        bytes memory composeMsg = hex"1234";
        SendParam memory sendParam = SendParam(
            ROBINHOOD_EID,
            addressToBytes32(address(composer)),
            tokensToSend,
            tokensToSend,
            options,
            composeMsg,
            ""
        );
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);

        vm.startPrank(userA);
        pult.approve(address(adapter), tokensToSend);
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) = adapter.send{ value: fee.nativeFee }(
            sendParam,
            fee,
            payable(userA)
        );
        vm.stopPrank();
        verifyPackets(ROBINHOOD_EID, addressToBytes32(address(oft)));

        bytes memory composerMsg_ = OFTComposeMsgCodec.encode(
            msgReceipt.nonce,
            BSC_EID,
            oftReceipt.amountReceivedLD,
            abi.encodePacked(addressToBytes32(userA), composeMsg)
        );
        this.lzCompose(ROBINHOOD_EID, address(oft), options, msgReceipt.guid, address(composer), composerMsg_);

        assertEq(pult.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(pult.balanceOf(address(adapter)), tokensToSend);
        assertEq(oft.balanceOf(address(composer)), tokensToSend);

        assertEq(composer.from(), address(oft));
        assertEq(composer.guid(), msgReceipt.guid);
        assertEq(composer.message(), composerMsg_);
        assertEq(composer.executor(), address(this));
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_bridge_preserves_supply_invariant(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), CONVERSION_RATE, initialBalance);
        uint256 expected = adapter.removeDust(amount);

        OFTReceipt memory receipt = _bridgeToRobinhood(userA, userB, amount);

        assertEq(receipt.amountSentLD, amount);
        assertEq(receipt.amountReceivedLD, expected);
        assertEq(oft.balanceOf(userB), expected);
        assertEq(adapter.feeBalance(), amount - expected);
        // locked PULT backs the remote supply plus the accrued dust/fee balance
        assertEq(pult.balanceOf(address(adapter)), oft.totalSupply() + adapter.feeBalance());
        assertEq(pult.balanceOf(userA) + pult.balanceOf(address(adapter)), initialBalance);
    }
}
