// Environment configuration is read from .env (see .env.example)
import 'dotenv/config'

import 'hardhat-deploy'
import 'hardhat-contract-sizer'
import '@nomiclabs/hardhat-ethers'
import '@nomicfoundation/hardhat-verify'
import '@layerzerolabs/toolbox-hardhat'
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from 'hardhat/types'

import { EndpointId } from '@layerzerolabs/lz-definitions'

import './type-extensions'

// Authentication: either MNEMONIC or PRIVATE_KEY.
// MAINNET_PRIVATE_KEY is accepted as a fallback so an existing .env (e.g. evm-contracts-v2) can be reused via
// DOTENV_CONFIG_PATH=/path/to/.env without copying secrets.
const MNEMONIC = process.env.MNEMONIC
const PRIVATE_KEY = process.env.PRIVATE_KEY || process.env.MAINNET_PRIVATE_KEY

const accounts: HttpNetworkAccountsUserConfig | undefined = MNEMONIC
    ? { mnemonic: MNEMONIC }
    : PRIVATE_KEY
      ? [PRIVATE_KEY]
      : undefined

if (accounts == null) {
    console.warn(
        'Could not find MNEMONIC or PRIVATE_KEY environment variables. It will not be possible to execute transactions.'
    )
}

/**
 * PULT (CatapultTrade) token already deployed on BSC mainnet.
 * The OFTAdapter on BSC wraps this token; every other chain gets a mint/burn PultOFT.
 */
export const PULT_TOKEN_BSC = '0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154'

const config: HardhatUserConfig = {
    paths: {
        cache: 'cache/hardhat',
    },
    solidity: {
        compilers: [
            {
                version: '0.8.30',
                settings: {
                    // OpenZeppelin 5.6 uses `mcopy`; Hardhat 2 would otherwise default to `paris`.
                    // BSC and Robinhood Chain (Arbitrum stack) both support Cancun.
                    evmVersion: 'cancun',
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                },
            },
        ],
        // Same compiler settings as the verified BSC deployment of the token
        // (solc 0.8.34, evmVersion osaka, optimizer disabled, OpenZeppelin 5.6.0) -> identical bytecode.
        overrides: {
            'contracts/CatapultTrade.sol': {
                version: '0.8.34',
                settings: {
                    evmVersion: 'osaka',
                    optimizer: {
                        enabled: false,
                        runs: 200,
                    },
                },
            },
        },
    },
    networks: {
        // ---------------------------------------------------------------- mainnet
        bsc: {
            eid: EndpointId.BSC_V2_MAINNET, // 30102
            url: process.env.RPC_URL_BSC || 'https://bsc-dataseed.bnbchain.org',
            chainId: 56,
            accounts,
            oftAdapter: {
                tokenAddress: PULT_TOKEN_BSC,
            },
        },
        robinhood: {
            eid: EndpointId.ROBINHOOD_V2_MAINNET, // 30416
            url: process.env.RPC_URL_ROBINHOOD || 'https://rpc.mainnet.chain.robinhood.com',
            chainId: 4663,
            accounts,
        },
        // ---------------------------------------------------------------- testnet
        'bsc-testnet': {
            eid: EndpointId.BSC_V2_TESTNET, // 40102
            url: process.env.RPC_URL_BSC_TESTNET || 'https://data-seed-prebsc-1-s1.bnbchain.org:8545',
            chainId: 97,
            accounts,
            // No PULT on testnet: leave tokenAddress unset and the adapter deploy script
            // falls back to the locally deployed `CatapultTrade` (tag CatapultTrade).
            oftAdapter: {
                tokenAddress: process.env.PULT_TOKEN_BSC_TESTNET || '',
            },
        },
        'robinhood-testnet': {
            eid: EndpointId.ROBINHOOD_V2_TESTNET, // 40451
            url: process.env.RPC_URL_ROBINHOOD_TESTNET || 'https://rpc.testnet.chain.robinhood.com',
            chainId: 46630,
            accounts,
        },
        hardhat: {
            // TestHelperOz5 / EndpointV2Mock exceed the contract size limit
            allowUnlimitedContractSize: true,
        },
    },
    namedAccounts: {
        deployer: {
            default: 0,
        },
    },
    etherscan: {
        apiKey: {
            bsc: process.env.BSCSCAN_API_KEY || '',
            bscTestnet: process.env.BSCSCAN_API_KEY || '',
            robinhood: 'blockscout',
            'robinhood-testnet': 'blockscout',
        },
        customChains: [
            {
                network: 'robinhood',
                chainId: 4663,
                urls: {
                    apiURL: 'https://robinhoodchain.blockscout.com/api',
                    browserURL: 'https://robinhoodchain.blockscout.com',
                },
            },
            {
                network: 'robinhood-testnet',
                chainId: 46630,
                urls: {
                    apiURL: 'https://explorer.testnet.chain.robinhood.com/api',
                    browserURL: 'https://explorer.testnet.chain.robinhood.com',
                },
            },
        ],
    },
}

export default config
