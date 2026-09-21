import 'hardhat/types/config'

interface OftAdapterConfig {
    /** Address of the ERC20 the OFTAdapter locks on this network (home chain only). */
    tokenAddress: string
}

declare module 'hardhat/types/config' {
    interface HardhatNetworkUserConfig {
        oftAdapter?: never
    }

    interface HardhatNetworkConfig {
        oftAdapter?: never
    }

    interface HttpNetworkUserConfig {
        oftAdapter?: OftAdapterConfig
    }

    interface HttpNetworkConfig {
        oftAdapter?: OftAdapterConfig
    }
}
