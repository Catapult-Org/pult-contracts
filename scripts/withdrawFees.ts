import { deployments, ethers, network } from 'hardhat'

/**
 * Withdraws the accumulated bridge fees of the local OFT contract to TO (defaults to the signer).
 * Usage: DOTENV_CONFIG_PATH=... TO=0x... npx hardhat run scripts/withdrawFees.ts --network bsc
 */
async function main() {
    const [signer] = await ethers.getSigners()
    const isHome = network.config.oftAdapter != null
    const name = isHome ? 'PultOFTAdapter' : 'PultOFT'
    const oft = await ethers.getContractAt(name, (await deployments.get(name)).address, signer)
    const to = process.env.TO ?? signer.address
    // The contracts reject these too (InvalidRecipient); fail before spending gas.
    if (!ethers.utils.isAddress(to)) throw new Error(`TO=${to} is not an address`)
    if (to === ethers.constants.AddressZero || to.toLowerCase() === oft.address.toLowerCase()) {
        throw new Error('TO must not be the zero address or the bridge contract itself')
    }

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
