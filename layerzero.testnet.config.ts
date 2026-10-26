import { EndpointId } from '@layerzerolabs/lz-definitions'
import { ExecutorOptionType } from '@layerzerolabs/lz-v2-utilities'
import { TwoWayConfig, generateConnectionsConfig } from '@layerzerolabs/metadata-tools'
import { OAppEnforcedOption } from '@layerzerolabs/toolbox-hardhat'

import type { OmniPointHardhat } from '@layerzerolabs/toolbox-hardhat'

/**
 * TESTNET mesh (full mesh, mirrors mainnet):
 *   BSC testnet       -> PultOFTAdapter over a freshly deployed CatapultTrade
 *   Robinhood testnet -> PultOFT
 *   Arbitrum Sepolia  -> PultOFT
 *
 *   npx hardhat lz:oapp:wire --oapp-config layerzero.testnet.config.ts
 */
const bscTestnetContract: OmniPointHardhat = {
    eid: EndpointId.BSC_V2_TESTNET,
    contractName: 'PultOFTAdapter',
}

const robinhoodTestnetContract: OmniPointHardhat = {
    eid: EndpointId.ROBINHOOD_V2_TESTNET,
    contractName: 'PultOFT',
}

const arbitrumSepoliaContract: OmniPointHardhat = {
    eid: EndpointId.ARBSEP_V2_TESTNET,
    contractName: 'PultOFT',
}

const EVM_ENFORCED_OPTIONS: OAppEnforcedOption[] = [
    {
        msgType: 1,
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 200_000,
        value: 0,
    },
    {
        msgType: 2,
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 250_000,
        value: 0,
    },
]

// Testnets: LayerZero Labs DVN only, 1 confirmation for fast iteration.
const DVNS: [string[], []] = [['LayerZero Labs'], []]

const pathways: TwoWayConfig[] = [
    [bscTestnetContract, robinhoodTestnetContract, DVNS, [1, 1], [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS]],
    [bscTestnetContract, arbitrumSepoliaContract, DVNS, [1, 1], [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS]],
    [robinhoodTestnetContract, arbitrumSepoliaContract, DVNS, [1, 1], [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS]],
]

export default async function () {
    const connections = await generateConnectionsConfig(pathways)
    return {
        contracts: [
            { contract: bscTestnetContract },
            { contract: robinhoodTestnetContract },
            { contract: arbitrumSepoliaContract },
        ],
        connections,
    }
}
