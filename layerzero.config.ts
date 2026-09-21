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
const pathways: TwoWayConfig[] = [
    [
        bscContract, // Chain A
        robinhoodContract, // Chain B
        // DVN config: [ requiredDVNs[], [ optionalDVNs[], optionalThreshold ] ]
        // IMPORTANT: the on-chain *default* DVN for BSC<->Robinhood is `LZDeadDVN` on both sides, i.e. LayerZero
        // ships no default security stack for this pathway. Explicit DVNs are mandatory or messages never verify.
        // Both DVNs below are live on BSC mainnet and Robinhood mainnet (LayerZero metadata API).
        // An empty optional array pins "no optional DVNs" (does NOT inherit on-chain defaults).
        [['LayerZero Labs', 'Nethermind'], []],
        // Block confirmations: [ BSC -> Robinhood, Robinhood -> BSC ]
        // Mirrors the on-chain LayerZero defaults read from SendUln302/ReceiveUln302 on both chains
        // (BSC sends with 20, Robinhood sends with 5). Re-check: `npx hardhat lz:oapp:config:get:default`.
        [20, 5],
        // Enforced options: [ options enforced on B (sending to A), options enforced on A (sending to B) ]
        [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS],
    ],
]

export default async function () {
    const connections = await generateConnectionsConfig(pathways)
    return {
        contracts: [{ contract: bscContract }, { contract: robinhoodContract }],
        connections,
    }
}
