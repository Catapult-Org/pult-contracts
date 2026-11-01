import { EndpointId } from '@layerzerolabs/lz-definitions'
import { ExecutorOptionType } from '@layerzerolabs/lz-v2-utilities'
import { TwoWayConfig, generateConnectionsConfig } from '@layerzerolabs/metadata-tools'
import { OAppEnforcedOption } from '@layerzerolabs/toolbox-hardhat'

import type { OmniPointHardhat } from '@layerzerolabs/toolbox-hardhat'

/**
 * MAINNET mesh: PULT
 *
 *   BSC (home chain)        -> PultOFTAdapter locks/unlocks the existing PULT token
 *   Robinhood Chain         -> PultOFT mints/burns
 *   Arbitrum One            -> PultOFT mints/burns
 *
 * Full mesh: every pair is wired directly (Robinhood <-> Arbitrum burns on one side and mints on the other, without
 * touching BSC). Invariant: PULT locked in the adapter == sum of PultOFT supplies + adapter.feeBalance().
 *
 * WARNING: exactly ONE OFTAdapter may exist in the mesh. Never deploy a second adapter.
 */
const bscContract: OmniPointHardhat = {
    eid: EndpointId.BSC_V2_MAINNET,
    contractName: 'PultOFTAdapter',
}

const robinhoodContract: OmniPointHardhat = {
    eid: EndpointId.ROBINHOOD_V2_MAINNET,
    contractName: 'PultOFT',
}

const arbitrumContract: OmniPointHardhat = {
    eid: EndpointId.ARBITRUM_V2_MAINNET,
    contractName: 'PultOFT',
}

/**
 * Required DVNs on every pathway (both must attest), no optional DVNs.
 * Names are resolved per chain through the LayerZero metadata API, so each must exist as a (non-lzRead) DVN on all
 * three chains. `Nethermind` does not: on BSC and Arbitrum it is only listed as an lzRead DVN, so the metadata
 * lookup fails. `Horizen` is live on BSC, Arbitrum and Robinhood.
 * An empty optional array pins "no optional DVNs" (does NOT inherit on-chain defaults).
 */
const DVNS: [string[], []] = [['LayerZero Labs', 'Horizen'], []]

/**
 * Enforced options: minimum executor gas the *sender* must pay for `EndpointV2.lzReceive` on the destination
 * (the Executor forwards exactly this gas: Executor.execute302 -> lzReceive{ gas: gasLimit }).
 *
 * Profiled in test/foundry/PultBridgeGas.t.sol against the real endpoint + ULN (forge 1.8, 2026-10-27):
 *   first-ever message on a pathway, mint to fresh recipient   ~117k
 *   first-ever message with compose, fresh recipient           ~146k  (+ endpoint.sendCompose)
 *   adapter unlock to fresh recipient                          ~103k
 * The previous 120k / 150k left only ~3 % headroom on the first mint. Values below keep >= 25 % headroom (the gas
 * test asserts it). Over-provisioning is cheap; under-provisioning strands messages until someone re-executes them
 * manually with more gas.
 */
const EVM_ENFORCED_OPTIONS: OAppEnforcedOption[] = [
    {
        msgType: 1, // SEND
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 200_000,
        value: 0,
    },
    {
        msgType: 2, // SEND_AND_CALL (compose)
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 250_000,
        value: 0,
    },
]

// Pathways are bidirectional: declaring [A, B] also wires B -> A.
// Each entry: [ A, B, DVN config, [ confirmations A -> B, confirmations B -> A ], [ enforced on B, enforced on A ] ]
// IMPORTANT: the on-chain *default* DVN of both Robinhood pathways is `LZDeadDVN`, i.e. LayerZero ships no default
// security stack for them. Explicit DVNs are mandatory or messages never verify.
// Confirmations = blocks the source chain must reach before DVNs verify a transfer. They must exceed the depth to which
// the source can still reorganize (MixBytes interim audit, Deployment Requirement 4), not just a sequencer's soft
// confirmation: a reorg after verification credits the destination for a source debit that no longer exists.
//   BSC:       fast finality finalizes within ~2-3 blocks (0.45 s blocks); 20 blocks (~9 s) is beyond that.
//   Robinhood: Arbitrum Orbit L2 settling to Ethereum; blocks are final only once their batch's Ethereum block is
//              finalized. Measured 2026-11-01: `finalized` trails `latest` by ~9,300 blocks (~16 min at 0.104 s).
//              12,000 blocks ≈ 21 min (≈ 16 min even at an 81 ms block time).
//   Arbitrum:  same mechanism; `finalized` trails by ~3,400 blocks (~17 min at 0.30 s). 4,500 blocks ≈ 22 min.
// LayerZero's on-chain defaults (20 / 5 / 20) only cover the sequencer's soft confirmation.
// Re-measure with eth_getBlockByNumber("finalized") vs "latest" if block times change.
const BSC_CONFIRMATIONS = 20
const ROBINHOOD_CONFIRMATIONS = 12_000
const ARBITRUM_CONFIRMATIONS = 4_500
const pathways: TwoWayConfig[] = [
    [
        bscContract,
        robinhoodContract,
        DVNS,
        [BSC_CONFIRMATIONS, ROBINHOOD_CONFIRMATIONS],
        [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS],
    ],
    [
        bscContract,
        arbitrumContract,
        DVNS,
        [BSC_CONFIRMATIONS, ARBITRUM_CONFIRMATIONS],
        [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS],
    ],
    [
        robinhoodContract,
        arbitrumContract,
        DVNS,
        [ROBINHOOD_CONFIRMATIONS, ARBITRUM_CONFIRMATIONS],
        [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS],
    ],
]

export default async function () {
    const connections = await generateConnectionsConfig(pathways)
    return {
        contracts: [{ contract: bscContract }, { contract: robinhoodContract }, { contract: arbitrumContract }],
        connections,
    }
}
