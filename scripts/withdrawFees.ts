import { deployments, ethers, network } from 'hardhat'

/**
 * Withdraws the accumulated bridge fees of the local OFT contract to TO (defaults to the signer).
 * Usage: DOTENV_CONFIG_PATH=... TO=0x... npx hardhat run scripts/withdrawFees.ts --network bsc
 */
async function main() {
    const [signer] = await ethers.getSigners()
    const isHome = network.name === 'bsc' || network.name === 'bsc-testnet'
    const name = isHome ? 'PultOFTAdapter' : 'PultOFT'
    const oft = await ethers.getContractAt(name, (await deployments.get(name)).address, signer)
    const to = process.env.TO ?? signer.address

    const balance = await oft.feeBalance()
    console.log(
        `network=${network.name} ${name}=${oft.address} feeBalance=${ethers.utils.formatEther(balance)} -> ${to}`
    )
    if (balance.isZero()) {
        console.log('nothing to withdraw')
        return
    }
    const tx = await oft.withdrawFees(to)
    console.log(`withdrawFees tx: ${tx.hash}`)
    await tx.wait()
    console.log(`done. feeBalance=${ethers.utils.formatEther(await oft.feeBalance())}`)
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
