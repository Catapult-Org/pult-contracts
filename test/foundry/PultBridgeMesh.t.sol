// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { CatapultTrade } from "../../contracts/CatapultTrade.sol";
import { PultOFTAdapter } from "../../contracts/PultOFTAdapter.sol";
import { PultOFT } from "../../contracts/PultOFT.sol";

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

/**
 * Full production mesh with the production contracts and the real endpoint + ULN from TestHelperOz5:
 *   eid 1 ("BSC")       -> CatapultTrade (PULT) + PultOFTAdapter
 *   eid 2 ("Robinhood") -> PultOFT
 *   eid 3 ("Arbitrum")  -> PultOFT
 *
 * Invariants checked after every delivered message:
 *   I1 backing:      PULT locked in adapter == supply(Robinhood) + supply(Arbitrum) + adapter.feeBalance
 *   I2 fee custody:  every PultOFT holds exactly its feeBalance itself
 *   I3 conservation: users' PULT + users' PultOFT + all three feeBalances == PULT given to the users
 */
contract PultBridgeMeshTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private constant BSC_EID = 1;
    uint32 private constant ROBINHOOD_EID = 2;
    uint32 private constant ARBITRUM_EID = 3;

    uint16 private constant BPS = 10_000;
    uint16 private constant MAX_FEE_BPS = 500;
    uint256 private constant CONVERSION_RATE = 1e12;
    uint256 private constant USER_PULT = 1_000_000 ether;

    CatapultTrade private pult;
    PultOFTAdapter private adapter;
    PultOFT private oftRobinhood;
    PultOFT private oftArbitrum;

    address private userA = makeAddr("userA");
    address private userB = makeAddr("userB");
    address private treasury = makeAddr("treasury");

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);
        vm.deal(treasury, 1000 ether);

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

        // wireOApps connects every pair: 6 directions
        address[] memory oapps = new address[](3);
        oapps[0] = address(adapter);
        oapps[1] = address(oftRobinhood);
        oapps[2] = address(oftArbitrum);
        this.wireOApps(oapps);

        pult.transfer(userA, USER_PULT);
        pult.transfer(userB, USER_PULT);
    }

    // ------------------------------------------------------------------ helpers

    function _app(uint32 eid) internal view returns (IOFT) {
        if (eid == BSC_EID) return IOFT(address(adapter));
        if (eid == ROBINHOOD_EID) return IOFT(address(oftRobinhood));
        return IOFT(address(oftArbitrum));
    }

    function _balance(uint32 eid, address who) internal view returns (uint256) {
        if (eid == BSC_EID) return pult.balanceOf(who);
        if (eid == ROBINHOOD_EID) return oftRobinhood.balanceOf(who);
        return oftArbitrum.balanceOf(who);
    }

    function _expectedReceived(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return ((amount - (amount * bps) / BPS) / CONVERSION_RATE) * CONVERSION_RATE;
    }

    /// @dev Sends `amount` from `srcEid` to `dstEid`, pinning minAmountLD to the quote, and delivers the packet.
    function _bridge(
        uint32 srcEid,
        uint32 dstEid,
        address from,
        address to,
        uint256 amount
    ) internal returns (OFTReceipt memory receipt) {
        IOFT app = _app(srcEid);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory sp = SendParam(dstEid, addressToBytes32(to), amount, 0, options, "", "");
        (, , OFTReceipt memory quoted) = app.quoteOFT(sp);
        sp.minAmountLD = quoted.amountReceivedLD;
        MessagingFee memory fee = app.quoteSend(sp, false);

        vm.startPrank(from);
        if (srcEid == BSC_EID) pult.approve(address(adapter), amount);
        (, receipt) = app.send{ value: fee.nativeFee }(sp, fee, payable(from));
        vm.stopPrank();

        assertEq(receipt.amountReceivedLD, quoted.amountReceivedLD, "receipt == quote");
        verifyPackets(dstEid, addressToBytes32(address(_app(dstEid))));
    }

    function _feeBalances() internal view returns (uint256) {
        return adapter.feeBalance() + oftRobinhood.feeBalance() + oftArbitrum.feeBalance();
    }

    function _userHoldings(address who) internal view returns (uint256) {
        return pult.balanceOf(who) + oftRobinhood.balanceOf(who) + oftArbitrum.balanceOf(who);
    }

    function _assertInvariants() internal view {
        assertEq(
            pult.balanceOf(address(adapter)),
            oftRobinhood.totalSupply() + oftArbitrum.totalSupply() + adapter.feeBalance(),
            "I1 backing"
        );
        assertEq(oftRobinhood.balanceOf(address(oftRobinhood)), oftRobinhood.feeBalance(), "I2 Robinhood fees");
        assertEq(oftArbitrum.balanceOf(address(oftArbitrum)), oftArbitrum.feeBalance(), "I2 Arbitrum fees");
        assertEq(
            _userHoldings(userA) + _userHoldings(userB) + _userHoldings(treasury) + _feeBalances(),
            2 * USER_PULT,
            "I3 conservation"
        );
    }

    // ------------------------------------------------------------------ wiring

    function test_mesh_is_fully_wired() public view {
        assertEq(adapter.peers(ROBINHOOD_EID), addressToBytes32(address(oftRobinhood)));
        assertEq(adapter.peers(ARBITRUM_EID), addressToBytes32(address(oftArbitrum)));
        assertEq(oftRobinhood.peers(BSC_EID), addressToBytes32(address(adapter)));
        assertEq(oftRobinhood.peers(ARBITRUM_EID), addressToBytes32(address(oftArbitrum)));
        assertEq(oftArbitrum.peers(BSC_EID), addressToBytes32(address(adapter)));
        assertEq(oftArbitrum.peers(ROBINHOOD_EID), addressToBytes32(address(oftRobinhood)));
    }

    // ------------------------------------------------------------------ directions

    function test_all_six_directions_without_fee() public {
        _bridge(BSC_EID, ROBINHOOD_EID, userA, userA, 100 ether);
        _bridge(BSC_EID, ARBITRUM_EID, userA, userA, 100 ether);
        _assertInvariants();

        _bridge(ROBINHOOD_EID, ARBITRUM_EID, userA, userB, 30 ether);
        assertEq(oftArbitrum.balanceOf(userB), 30 ether);
        _bridge(ARBITRUM_EID, ROBINHOOD_EID, userB, userA, 10 ether);
        assertEq(oftRobinhood.balanceOf(userA), 80 ether);
        _assertInvariants();

        uint256 before = pult.balanceOf(userA);
        _bridge(ROBINHOOD_EID, BSC_EID, userA, userA, 80 ether);
        _bridge(ARBITRUM_EID, BSC_EID, userA, userA, 100 ether);
        _bridge(ARBITRUM_EID, BSC_EID, userB, userA, 20 ether);
        assertEq(pult.balanceOf(userA), before + 200 ether);
        assertEq(oftRobinhood.totalSupply() + oftArbitrum.totalSupply(), 0);
        assertEq(pult.balanceOf(address(adapter)), 0);
        _assertInvariants();
    }

    function test_oft_to_oft_does_not_touch_bsc() public {
        _bridge(BSC_EID, ROBINHOOD_EID, userA, userA, 50 ether);
        uint256 locked = pult.balanceOf(address(adapter));

        oftRobinhood.setDefaultFeeBps(MAX_FEE_BPS);
        OFTReceipt memory r = _bridge(ROBINHOOD_EID, ARBITRUM_EID, userA, userB, 40 ether);

        // fee charged on the source OFT and kept there; BSC side untouched
        assertEq(r.amountReceivedLD, 38 ether);
        assertEq(oftRobinhood.feeBalance(), 2 ether);
        assertEq(oftArbitrum.balanceOf(userB), 38 ether);
        assertEq(pult.balanceOf(address(adapter)), locked);
        assertEq(adapter.feeBalance(), 0);
        _assertInvariants();
    }

    // ------------------------------------------------------------------ fee + dust edge cases

    function test_amount_below_dust_goes_entirely_to_fee_balance() public {
        uint256 tiny = CONVERSION_RATE - 1; // < 1 shared-decimal unit
        OFTReceipt memory r = _bridge(BSC_EID, ARBITRUM_EID, userA, userB, tiny);

        assertEq(r.amountSentLD, tiny);
        assertEq(r.amountReceivedLD, 0);
        assertEq(oftArbitrum.balanceOf(userB), 0);
        assertEq(adapter.feeBalance(), tiny);
        assertEq(pult.balanceOf(address(adapter)), tiny);
        _assertInvariants();
    }

    function test_max_fee_with_dust_exact_accounting() public {
        adapter.setDefaultFeeBps(MAX_FEE_BPS);
        uint256 amount = 1_000 ether + 123_456_789; // dust in the last 12 decimals
        OFTReceipt memory r = _bridge(BSC_EID, ROBINHOOD_EID, userA, userB, amount);

        uint256 fee = (amount * MAX_FEE_BPS) / BPS;
        assertEq(r.amountReceivedLD, _expectedReceived(amount, MAX_FEE_BPS));
        assertEq(r.amountReceivedLD % CONVERSION_RATE, 0);
        assertGe(r.amountReceivedLD, amount - fee - CONVERSION_RATE); // never more than fee + 1 dust unit lost
        assertEq(adapter.feeBalance(), amount - r.amountReceivedLD); // fee + dust
        assertEq(oftRobinhood.balanceOf(userB), r.amountReceivedLD);
        _assertInvariants();
    }

    function test_withdrawFees_after_many_transfers_keeps_backing() public {
        adapter.setDefaultFeeBps(100);
        oftRobinhood.setDefaultFeeBps(250);
        oftArbitrum.setFeeBps(ROBINHOOD_EID, MAX_FEE_BPS, true);
        oftArbitrum.setDefaultFeeBps(30);

        for (uint256 i; i < 5; i++) {
            _bridge(BSC_EID, ROBINHOOD_EID, userA, userA, 101 ether + i);
            _bridge(BSC_EID, ARBITRUM_EID, userB, userB, 77 ether + i * 1e9);
            _bridge(ROBINHOOD_EID, ARBITRUM_EID, userA, userB, 20 ether);
            _bridge(ARBITRUM_EID, ROBINHOOD_EID, userB, userA, 10 ether);
            _bridge(ARBITRUM_EID, BSC_EID, userB, userA, 5 ether);
            _bridge(ROBINHOOD_EID, BSC_EID, userA, userB, 3 ether);
            _assertInvariants();
        }

        uint256 adapterFees = adapter.feeBalance();
        uint256 robinhoodFees = oftRobinhood.feeBalance();
        uint256 arbitrumFees = oftArbitrum.feeBalance();
        assertGt(adapterFees, 0);
        assertGt(robinhoodFees, 0);
        assertGt(arbitrumFees, 0);

        adapter.withdrawFees(treasury);
        oftRobinhood.withdrawFees(treasury);
        oftArbitrum.withdrawFees(treasury);

        assertEq(pult.balanceOf(treasury), adapterFees);
        assertEq(oftRobinhood.balanceOf(treasury), robinhoodFees);
        assertEq(oftArbitrum.balanceOf(treasury), arbitrumFees);
        assertEq(_feeBalances(), 0);
        // after withdrawal the adapter holds exactly the remote supply, nothing more, nothing less
        assertEq(pult.balanceOf(address(adapter)), oftRobinhood.totalSupply() + oftArbitrum.totalSupply());
        _assertInvariants();

        vm.expectRevert(PultOFTAdapter.NoFeesToWithdraw.selector);
        adapter.withdrawFees(treasury);
        vm.expectRevert(PultOFT.NoFeesToWithdraw.selector);
        oftArbitrum.withdrawFees(treasury);

        // withdrawn OFT fees are fully backed: the treasury can redeem them on BSC (no fee set on these routes)
        adapter.setDefaultFeeBps(0);
        oftRobinhood.setDefaultFeeBps(0);
        oftArbitrum.setDefaultFeeBps(0);
        oftArbitrum.setFeeBps(ROBINHOOD_EID, 0, false);
        uint256 redeemable = ((robinhoodFees / CONVERSION_RATE) + (arbitrumFees / CONVERSION_RATE)) * CONVERSION_RATE;
        _bridge(ROBINHOOD_EID, BSC_EID, treasury, treasury, robinhoodFees);
        _bridge(ARBITRUM_EID, BSC_EID, treasury, treasury, arbitrumFees);
        assertEq(pult.balanceOf(treasury), adapterFees + redeemable);
        _assertInvariants();
    }

    // ------------------------------------------------------------------ fuzz: random walk over the mesh

    /// @dev 12 random hops between random chains/users with random per-contract fees <= 5 %;
    ///      all invariants are checked after every hop.
    function testFuzz_random_mesh_walk_preserves_invariants(uint256 seed, uint16[3] memory rawBps) public {
        adapter.setDefaultFeeBps(uint16(bound(rawBps[0], 0, MAX_FEE_BPS)));
        oftRobinhood.setDefaultFeeBps(uint16(bound(rawBps[1], 0, MAX_FEE_BPS)));
        oftArbitrum.setDefaultFeeBps(uint16(bound(rawBps[2], 0, MAX_FEE_BPS)));

        address[2] memory users = [userA, userB];
        for (uint256 i; i < 12; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint32 src = uint32(1 + (r % 3));
            uint32 dst = uint32(1 + ((r >> 8) % 2));
            if (dst >= src) dst++; // dst in {1,2,3} \ {src}
            address from = users[(r >> 16) % 2];
            address to = users[(r >> 17) % 2];

            uint256 bal = _balance(src, from);
            if (bal == 0) continue;
            // amounts from 1 wei (pure dust) to the full balance
            uint256 amount = 1 + ((r >> 32) % bal);

            uint256 dstBefore = _balance(dst, to);
            uint256 locked = pult.balanceOf(address(adapter));
            OFTReceipt memory receipt = _bridge(src, dst, from, to, amount);

            uint16 bps = PultOFTFeeView(address(_app(src))).defaultFeeBps();
            assertEq(receipt.amountReceivedLD, _expectedReceived(amount, bps), "received == formula");
            if (dst != BSC_EID || to != address(adapter)) {
                assertEq(_balance(dst, to), dstBefore + receipt.amountReceivedLD, "recipient credited");
            }
            if (src != BSC_EID && dst != BSC_EID) {
                assertEq(pult.balanceOf(address(adapter)), locked, "OFT <-> OFT leaves BSC untouched");
            }
            _assertInvariants();
        }
    }
}

interface PultOFTFeeView {
    function defaultFeeBps() external view returns (uint16);
}
