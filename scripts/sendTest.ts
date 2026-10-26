import { config, deployments, ethers, network } from 'hardhat'

import { Options } from '@layerzerolabs/lz-v2-utilities'

/**
 * Sends `AMOUNT` (human units, default 1) of PULT from the current network to the `DST` network.
 *   bsc               -> PultOFTAdapter (approve + send)
 *   robinhood/arbitrum -> PultOFT (send, burns)
 * DST is a network name from hardhat.config.ts (e.g. robinhood, arbitrum, bsc). Default: robinhood from BSC, BSC
 * otherwise (testnet names accordingly). TO defaults to the signer.
 * minAmountLD is taken from quoteOFT, i.e. the exact amount after the bridge fee and dust removal.
 * Usage: DOTENV_CONFIG_PATH=... AMOUNT=1 DST=arbitrum TO=0x... npx hardhat run scripts/sendTest.ts --network bsc
 */
async function main() {
    const [signer] = await ethers.getSigners()
    const amount = ethers.utils.parseEther(process.env.AMOUNT ?? '1')
    const to = process.env.TO ?? signer.address

    const isHome = network.config.oftAdapter != null
    const isTestnet = network.name.includes('testnet') || network.name.includes('sepolia')
    const dstName =
        process.env.DST ??
        (isHome ? (isTestnet ? 'robinhood-testnet' : 'robinhood') : isTestnet ? 'bsc-testnet' : 'bsc')
    const dstEid = config.networks[dstName]?.eid
    if (dstEid == null) throw new Error(`DST=${dstName} is not a network with an eid in hardhat.config.ts`)
    if (dstName === network.name) throw new Error('DST must differ from --network')

    const oftDeployment = await deployments.get(isHome ? 'PultOFTAdapter' : 'PultOFT')
    const oft = await ethers.getContractAt(isHome ? 'PultOFTAdapter' : 'PultOFT', oftDeployment.address, signer)
    const tokenAddress: string = await oft.token()
    const token = await ethers.getContractAt('CatapultTrade', tokenAddress, signer)

    console.log(
        `network=${network.name} signer=${signer.address} oft=${oft.address} token=${tokenAddress} dst=${dstName} (${dstEid})`
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
        minAmountLD: ethers.BigNumber.from(0),
        extraOptions,
        composeMsg: '0x',
        oftCmd: '0x',
    }
    // Pin the exact received amount (after fee + dust) so the send cannot deliver less than quoted.
    const [, , oftReceipt] = await oft.quoteOFT(sendParam)
    sendParam.minAmountLD = oftReceipt.amountReceivedLD
    console.log(
        `amountSent=${ethers.utils.formatEther(oftReceipt.amountSentLD)} amountReceived=${ethers.utils.formatEther(oftReceipt.amountReceivedLD)}`
    )

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
