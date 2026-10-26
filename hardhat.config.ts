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

// Robinhood Chain is verified on Blockscout, every other network on Etherscan v2.
// The config is evaluated before Hardhat resolves the network, so read it from the CLI / HARDHAT_NETWORK.
const networkArgIndex = process.argv.indexOf('--network')
const SELECTED_NETWORK =
    process.env.HARDHAT_NETWORK ?? (networkArgIndex >= 0 ? process.argv[networkArgIndex + 1] : undefined)
const VERIFY_ON_BLOCKSCOUT = SELECTED_NETWORK === 'robinhood' || SELECTED_NETWORK === 'robinhood-testnet'

/**
 * DEPLOY_STAGE=staging: a separate, throwaway mesh on the real chains (own PultOFTAdapter over the real PULT on BSC,
 * own PultOFTs named "PULT Staging") for end-to-end tests before the production deploy. Its artifacts live in
 * deployments-staging/, so the production deployments/ are never touched. Unset = production.
 */
export const DEPLOY_STAGE = process.env.DEPLOY_STAGE || undefined

const config: HardhatUserConfig = {
    paths: {
        cache: 'cache/hardhat',
        deployments: DEPLOY_STAGE ? `deployments-${DEPLOY_STAGE}` : 'deployments',
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
        arbitrum: {
            eid: EndpointId.ARBITRUM_V2_MAINNET, // 30110
            url: process.env.RPC_URL_ARBITRUM || 'https://arb1.arbitrum.io/rpc',
            chainId: 42161,
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
        'arbitrum-sepolia': {
            eid: EndpointId.ARBSEP_V2_TESTNET, // 40231
            url: process.env.RPC_URL_ARBITRUM_SEPOLIA || 'https://sepolia-rollup.arbitrum.io/rpc',
            chainId: 421614,
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
    // BSC + Arbitrum (main/testnets): one Etherscan v2 key (a string key selects the v2 multichain API; the per-network
    // key object selects the v1 explorer APIs, which Etherscan shut down in 2025).
    // Robinhood Chain: Blockscout, no key. Exactly one verifier is enabled for the selected network.
    etherscan: {
        enabled: !VERIFY_ON_BLOCKSCOUT,
        apiKey: process.env.ETHERSCAN_API_KEY || process.env.BSCSCAN_API_KEY || '',
    },
    blockscout: {
        enabled: VERIFY_ON_BLOCKSCOUT,
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
