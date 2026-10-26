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
 * Profiled in test/foundry/PultBridgeGas.t.sol against the real endpoint + ULN:
 *   first-ever message on a pathway, mint to fresh recipient   ~79k
 *   first-ever message with compose, fresh recipient           ~100k  (+ endpoint.sendCompose)
 *   adapter unlock to fresh recipient                          ~58k
 * Values below keep >= 25% headroom. Over-provisioning is cheap; under-provisioning strands messages
 * until someone re-executes them manually with more gas.
 */
const EVM_ENFORCED_OPTIONS: OAppEnforcedOption[] = [
    {
        msgType: 1, // SEND
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 120_000,
        value: 0,
    },
    {
        msgType: 2, // SEND_AND_CALL (compose)
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 150_000,
        value: 0,
    },
]

// Pathways are bidirectional: declaring [A, B] also wires B -> A.
// Each entry: [ A, B, DVN config, [ confirmations A -> B, confirmations B -> A ], [ enforced on B, enforced on A ] ]
// IMPORTANT: the on-chain *default* DVN of both Robinhood pathways is `LZDeadDVN`, i.e. LayerZero ships no default
// security stack for them. Explicit DVNs are mandatory or messages never verify.
// Confirmations mirror the on-chain LayerZero defaults (SendUln302.getUlnConfig(address(0), dstEid), read 2026-10-26):
// BSC and Arbitrum send with 20, Robinhood sends with 5. Re-check: `npx hardhat lz:oapp:config:get:default`.
const pathways: TwoWayConfig[] = [
    [bscContract, robinhoodContract, DVNS, [20, 5], [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS]],
    [bscContract, arbitrumContract, DVNS, [20, 20], [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS]],
    [robinhoodContract, arbitrumContract, DVNS, [5, 20], [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS]],
]

export default async function () {
    const connections = await generateConnectionsConfig(pathways)
    return {
        contracts: [{ contract: bscContract }, { contract: robinhoodContract }, { contract: arbitrumContract }],
        connections,
    }
}
