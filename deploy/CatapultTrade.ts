import assert from 'assert'

import { type DeployFunction } from 'hardhat-deploy/types'

/**
 * Deploys a fresh copy of the PULT token (CatapultTrade).
 *
 * Only meant for testnets / local networks. On BSC mainnet the token already exists at
 * 0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154 and this script is skipped.
 */
const contractName = 'CatapultTrade'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre

    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            deployer, // recipient of the 1_000_000_000 PULT initial supply
            deployer, // initialOwner
        ],
        log: true,
        skipIfAlreadyDeployed: true,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName]

// Skip when the network already points the adapter at an existing token (mainnet).
deploy.skip = async (hre) => {
    const tokenAddress = hre.network.config.oftAdapter?.tokenAddress
    if (tokenAddress) {
        console.log(`${contractName}: token already exists at ${tokenAddress} on ${hre.network.name}, skipping`)
        return true
    }
    return false
}

export default deploy
