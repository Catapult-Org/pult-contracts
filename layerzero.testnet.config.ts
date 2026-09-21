import { EndpointId } from '@layerzerolabs/lz-definitions'
import { ExecutorOptionType } from '@layerzerolabs/lz-v2-utilities'
import { TwoWayConfig, generateConnectionsConfig } from '@layerzerolabs/metadata-tools'
import { OAppEnforcedOption } from '@layerzerolabs/toolbox-hardhat'

import type { OmniPointHardhat } from '@layerzerolabs/toolbox-hardhat'

/**
 * TESTNET mesh: BSC testnet (adapter over a freshly deployed CatapultTrade) <-> Robinhood testnet (OFT)
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

const EVM_ENFORCED_OPTIONS: OAppEnforcedOption[] = [
    {
        msgType: 1,
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 120_000,
        value: 0,
    },
    {
        msgType: 2,
        optionType: ExecutorOptionType.LZ_RECEIVE,
        gas: 150_000,
        value: 0,
    },
]

const pathways: TwoWayConfig[] = [
    [
        bscTestnetContract,
        robinhoodTestnetContract,
        [['LayerZero Labs'], []],
        [1, 1],
        [EVM_ENFORCED_OPTIONS, EVM_ENFORCED_OPTIONS],
    ],
]

export default async function () {
    const connections = await generateConnectionsConfig(pathways)
    return {
        contracts: [{ contract: bscTestnetContract }, { contract: robinhoodTestnetContract }],
        connections,
    }
}
