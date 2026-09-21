import { deployments, ethers, network } from 'hardhat'

/**
 * Sets the bridge fee on the local OFT contract (PultOFTAdapter on BSC, PultOFT elsewhere).
 *   FEE_BPS=100                      -> setDefaultFeeBps(100)            (1% for every destination)
 *   FEE_BPS=50 DST_EID=30416         -> setFeeBps(30416, 50, true)       (override for one destination)
 *   FEE_BPS=0  DST_EID=30416 ENABLED=false -> setFeeBps(30416, 0, false) (remove the override)
 * Usage: DOTENV_CONFIG_PATH=... FEE_BPS=100 npx hardhat run scripts/setFee.ts --network bsc
 */
async function main() {
    const [signer] = await ethers.getSigners()
    const isHome = network.name === 'bsc' || network.name === 'bsc-testnet'
    const name = isHome ? 'PultOFTAdapter' : 'PultOFT'
    const oft = await ethers.getContractAt(name, (await deployments.get(name)).address, signer)

    const feeBps = Number(process.env.FEE_BPS)
    if (!Number.isInteger(feeBps) || feeBps < 0 || feeBps > 10_000)
        throw new Error('FEE_BPS must be an integer in [0, 10000]')

    console.log(`network=${network.name} ${name}=${oft.address} owner=${await oft.owner()} signer=${signer.address}`)
    console.log(
        `current defaultFeeBps=${await oft.defaultFeeBps()} feeBalance=${ethers.utils.formatEther(await oft.feeBalance())}`
    )

    let tx
    if (process.env.DST_EID) {
        const dstEid = Number(process.env.DST_EID)
        const enabled = (process.env.ENABLED ?? 'true') !== 'false'
        tx = await oft.setFeeBps(dstEid, feeBps, enabled)
        console.log(`setFeeBps(${dstEid}, ${feeBps}, ${enabled}) tx: ${tx.hash}`)
    } else {
        tx = await oft.setDefaultFeeBps(feeBps)
        console.log(`setDefaultFeeBps(${feeBps}) tx: ${tx.hash}`)
    }
    await tx.wait()
    console.log(`done. defaultFeeBps=${await oft.defaultFeeBps()}`)
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
