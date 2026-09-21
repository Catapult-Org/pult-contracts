import assert from 'assert'

import { type DeployFunction } from 'hardhat-deploy/types'

/**
 * Deploys the mint/burn PultOFT on every non-home chain (Robinhood Chain).
 * Name / symbol mirror the BSC token: "Catapult Trade" / "PULT", 18 decimals.
 */
const contractName = 'PultOFT'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre

    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${hre.network.name}`)
    console.log(`Deployer: ${deployer}`)

    // External deployment provided by @layerzerolabs/toolbox-hardhat based on the network `eid`
    const endpointV2Deployment = await hre.deployments.get('EndpointV2')

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            'Catapult Trade', // name
            'PULT', // symbol
            endpointV2Deployment.address, // LayerZero EndpointV2
            deployer, // owner + delegate
        ],
        log: true,
        skipIfAlreadyDeployed: true,
    })

    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${address}`)
}

deploy.tags = [contractName]

// Never deploy a mint/burn OFT on the home chain: that is what the adapter is for.
deploy.skip = async (hre) => {
    if (hre.network.config.oftAdapter != null) {
        console.log(`${contractName}: network ${hre.network.name} is the PULT home chain (adapter), skipping`)
        return true
    }
    return false
}

export default deploy
