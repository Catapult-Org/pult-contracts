import assert from 'assert'

import { type DeployFunction } from 'hardhat-deploy/types'

/**
 * Deploys the PULT OFTAdapter on the home chain (BSC).
 *
 * WARNING: ONLY 1 OFTAdapter may exist for PULT in the whole LayerZero mesh.
 *
 * The token address comes from `networks.<name>.oftAdapter.tokenAddress` in hardhat.config.ts.
 * If it is empty (testnets) the script falls back to the `CatapultTrade` deployment on the same network.
 */
const contractName = 'PultOFTAdapter'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre

    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    // External deployment provided by @layerzerolabs/toolbox-hardhat based on the network `eid`
    const endpointV2Deployment = await hre.deployments.get('EndpointV2')

    let tokenAddress = hre.network.config.oftAdapter?.tokenAddress
    if (!tokenAddress) {
        const token = await hre.deployments.get('CatapultTrade')
        tokenAddress = token.address
        console.log(`Using locally deployed CatapultTrade at ${tokenAddress}`)
    }

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            tokenAddress, // PULT token to lock/unlock
            endpointV2Deployment.address, // LayerZero EndpointV2
            deployer, // owner + delegate
        ],
        log: true,
        skipIfAlreadyDeployed: true,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName]
deploy.dependencies = ['CatapultTrade']

// Only the home chain (the one with an `oftAdapter` block in its network config) gets the adapter.
deploy.skip = async (hre) => {
    if (hre.network.config.oftAdapter == null) {
        console.log(`${contractName}: network ${hre.network.name} is not the PULT home chain, skipping`)
        return true
    }
    return false
}

export default deploy
