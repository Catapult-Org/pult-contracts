import { deployments, ethers, network } from 'hardhat'

import { Options } from '@layerzerolabs/lz-v2-utilities'

/**
 * Sends `AMOUNT` (human units, default 1) of the bridged token from the current network to the peer chain.
 *   bsc       -> PultOFTAdapter (approve + send) -> Robinhood (eid 30416)
 *   robinhood -> PultOFT (send)                  -> BSC       (eid 30102)
 * Usage: DOTENV_CONFIG_PATH=... AMOUNT=1 TO=0x... npx hardhat run scripts/sendTest.ts --network bsc
 */
async function main() {
    const [signer] = await ethers.getSigners()
    const amount = ethers.utils.parseEther(process.env.AMOUNT ?? '1')
    const to = process.env.TO ?? signer.address

    const isHome = network.name === 'bsc' || network.name === 'bsc-testnet'
    const dstEid = isHome ? (network.name === 'bsc' ? 30416 : 40451) : network.name === 'robinhood' ? 30102 : 40102

    const oftDeployment = await deployments.get(isHome ? 'PultOFTAdapter' : 'PultOFT')
    const oft = await ethers.getContractAt(isHome ? 'PultOFTAdapter' : 'PultOFT', oftDeployment.address, signer)
    const tokenAddress: string = await oft.token()
    const token = await ethers.getContractAt('CatapultTrade', tokenAddress, signer)

    console.log(
        `network=${network.name} signer=${signer.address} oft=${oft.address} token=${tokenAddress} dstEid=${dstEid}`
    )
    console.log(`token balance before: ${ethers.utils.formatEther(await token.balanceOf(signer.address))}`)

    if (isHome) {
        const allowance = await token.allowance(signer.address, oft.address)
        if (allowance.lt(amount)) {
            const tx = await token.approve(oft.address, amount)
            console.log(`approve tx: ${tx.hash}`)
            await tx.wait()
        }
    }

    // Extra options are combined with the enforced ones on-chain; enforced already covers lzReceive gas.
    const extraOptions = Options.newOptions().toHex()
    const sendParam = {
        dstEid,
        to: ethers.utils.hexZeroPad(to, 32),
        amountLD: amount,
        minAmountLD: amount,
        extraOptions,
        composeMsg: '0x',
        oftCmd: '0x',
    }

    const fee = await oft.quoteSend(sendParam, false)
    console.log(`quoted nativeFee: ${ethers.utils.formatEther(fee.nativeFee)}`)

    const tx = await oft.send(sendParam, { nativeFee: fee.nativeFee, lzTokenFee: 0 }, signer.address, {
        value: fee.nativeFee,
    })
    console.log(`send tx: ${tx.hash}`)
    const receipt = await tx.wait()
    console.log(`mined in block ${receipt.blockNumber}, gasUsed ${receipt.gasUsed.toString()}`)
    console.log(`LayerZero Scan: https://layerzeroscan.com/tx/${tx.hash}`)
    console.log(`token balance after: ${ethers.utils.formatEther(await token.balanceOf(signer.address))}`)
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
