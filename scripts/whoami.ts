import { ethers, network } from 'hardhat'

// Prints the deployer address and native balance on the selected network. Never prints secrets.
async function main() {
    const [signer] = await ethers.getSigners()
    if (!signer) throw new Error('No signer configured (set PRIVATE_KEY / MAINNET_PRIVATE_KEY or MNEMONIC)')
    const balance = await signer.getBalance()
    const gasPrice = await ethers.provider.getGasPrice()
    console.log(`network=${network.name} chainId=${(await ethers.provider.getNetwork()).chainId}`)
    console.log(`deployer=${signer.address}`)
    console.log(
        `balance=${ethers.utils.formatEther(balance)} gasPrice=${ethers.utils.formatUnits(gasPrice, 'gwei')} gwei`
    )
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
