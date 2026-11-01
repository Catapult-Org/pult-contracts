import fs from 'fs'
import path from 'path'

import { BigNumber, Contract, Wallet, ethers } from 'ethers'
import { artifacts, config } from 'hardhat'

/**
 * Retires a staging mesh (MixBytes interim audit, Deployment Requirement 3): every staging PultOFT ends with no
 * supply and no bridge contract has a peer set.
 *
 *   status (default, read-only): lockbox, supplies, fee balances, known holders, every peer
 *   RETIRE=1: 1. owner withdraws every feeBalance to itself
 *             2. every OFT balance held by the owner / TEST_PRIVATE_KEY is bridged back to BSC (to the same address)
 *             3. waits until BSC has unlocked every transfer (aborts before sending if a PultOFT holder outside
 *                the known keys exists, since the mesh could then not be emptied)
 *             4. owner sets every peer to bytes32(0) on all three contracts
 *
 * Usage: DEPLOY_STAGE=staging npx hardhat run scripts/retireStaging.ts            (status)
 *        DEPLOY_STAGE=staging RETIRE=1 npx hardhat run scripts/retireStaging.ts   (retire)
 * Refuses to run without DEPLOY_STAGE so the production mesh can never be retired by accident.
 */
const NAMES = ['bsc', 'robinhood', 'arbitrum']
const DELIVERY_TIMEOUT_MS = 30 * 60 * 1000
const POLL_MS = 15_000

type Chain = {
    name: string
    eid: number
    isHome: boolean
    app: Contract // connected to owner
    token: Contract // PULT on BSC, the PultOFT itself elsewhere
    owner: Wallet
    user?: Wallet
}

const fmt = (x: BigNumber) => ethers.utils.formatEther(x)
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const log = (msg: string) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`)

async function main() {
    if (!process.env.DEPLOY_STAGE) throw new Error('refusing to run against production: set DEPLOY_STAGE')
    const ownerKey = process.env.PRIVATE_KEY || process.env.MAINNET_PRIVATE_KEY
    if (!ownerKey) throw new Error('PRIVATE_KEY must be set')
    const userKey = process.env.TEST_PRIVATE_KEY
    const retire = process.env.RETIRE === '1'

    const adapterAbi = (await artifacts.readArtifact('PultOFTAdapter')).abi
    const oftAbi = (await artifacts.readArtifact('PultOFT')).abi
    const erc20Abi = (await artifacts.readArtifact('CatapultTrade')).abi

    const chains: Chain[] = []
    for (const name of NAMES) {
        const net = config.networks[name] as { url: string; eid: number; oftAdapter?: unknown }
        const isHome = net.oftAdapter != null
        const file = path.join(config.paths.deployments, name, `${isHome ? 'PultOFTAdapter' : 'PultOFT'}.json`)
        const { address } = JSON.parse(fs.readFileSync(file, 'utf8'))
        const provider = new ethers.providers.StaticJsonRpcProvider(net.url)
        const owner = new Wallet(ownerKey, provider)
        const app = new Contract(address, isHome ? adapterAbi : oftAbi, owner)
        const token = isHome ? new Contract(await app.token(), erc20Abi, owner) : app
        chains.push({
            name,
            eid: net.eid,
            isHome,
            app,
            token,
            owner,
            user: userKey ? new Wallet(userKey, provider) : undefined,
        })
    }
    const home = chains.find((c) => c.isHome)
    if (!home) throw new Error('no adapter chain')
    const holders = [...new Set([home.owner.address, ...(home.user ? [home.user.address] : [])])]

    async function status(): Promise<{ supply: BigNumber; peers: number }> {
        let remoteSupply = BigNumber.from(0)
        let livePeers = 0
        for (const c of chains) {
            const fee: BigNumber = await c.app.feeBalance()
            const owner: string = await c.app.owner()
            if (c.isHome) {
                log(
                    `${c.name} adapter ${c.app.address} owner=${owner} lockbox=${fmt(await c.token.balanceOf(c.app.address))} feeBalance=${fmt(fee)}`
                )
            } else {
                const supply: BigNumber = await c.app.totalSupply()
                remoteSupply = remoteSupply.add(supply)
                const held = await Promise.all(holders.map(async (h) => `${h}=${fmt(await c.app.balanceOf(h))}`))
                log(
                    `${c.name} oft ${c.app.address} owner=${owner} supply=${fmt(supply)} feeBalance=${fmt(fee)} ${held.join(' ')}`
                )
            }
            for (const d of chains) {
                if (d === c) continue
                const peer: string = await c.app.peers(d.eid)
                if (peer !== ethers.constants.HashZero) livePeers++
                log(`  peer ${c.name} -> ${d.name}: ${peer === ethers.constants.HashZero ? 'none' : peer}`)
            }
        }
        return { supply: remoteSupply, peers: livePeers }
    }

    const before = await status()
    if (!retire) {
        log('read-only run; set RETIRE=1 to retire this mesh')
        return
    }

    log('=== 1. withdraw fee balances')
    for (const c of chains) {
        if ((await c.app.feeBalance()).gt(0)) {
            await (await c.app.withdrawFees(c.owner.address)).wait()
            log(`${c.name}: fees withdrawn to owner`)
        }
    }

    log('=== 2. bridge remote balances back to BSC')
    for (const c of chains.filter((x) => !x.isHome)) {
        let unheld: BigNumber = await c.app.totalSupply()
        for (const h of holders) unheld = unheld.sub(await c.app.balanceOf(h))
        if (unheld.gt(0)) throw new Error(`${c.name}: ${fmt(unheld)} held by addresses outside the known keys`)
    }
    const lockedBefore: BigNumber = await home.token.balanceOf(home.app.address)
    let bridged = BigNumber.from(0)
    for (const c of chains.filter((x) => !x.isHome)) {
        for (const signer of [c.owner, ...(c.user ? [c.user] : [])]) {
            const bal: BigNumber = await c.app.balanceOf(signer.address)
            if (bal.isZero()) continue
            const sp = {
                dstEid: home.eid,
                to: ethers.utils.hexZeroPad(signer.address, 32),
                amountLD: bal,
                minAmountLD: bal,
                extraOptions: '0x',
                composeMsg: '0x',
                oftCmd: '0x',
            }
            const app = c.app.connect(signer)
            const fee = await app.quoteSend(sp, false)
            const tx = await app.send(sp, fee, signer.address, { value: fee.nativeFee })
            await tx.wait()
            bridged = bridged.add(bal)
            log(`${c.name}: ${fmt(bal)} from ${signer.address} -> BSC (${tx.hash})`)
        }
    }

    log('=== 3. wait until every transfer is unlocked on BSC')
    const target = lockedBefore.sub(bridged)
    const deadline = Date.now() + DELIVERY_TIMEOUT_MS
    for (;;) {
        const locked: BigNumber = await home.token.balanceOf(home.app.address)
        if (locked.lte(target)) break
        if (Date.now() > deadline) throw new Error(`timeout: lockbox ${fmt(locked)}, expected ${fmt(target)}`)
        log(`  lockbox ${fmt(locked)}, waiting for ${fmt(locked.sub(target))} to unlock`)
        await sleep(POLL_MS)
    }

    log('=== 4. unset every peer')
    for (const c of chains) {
        for (const d of chains) {
            if (d === c) continue
            if ((await c.app.peers(d.eid)) === ethers.constants.HashZero) continue
            await (await c.app.setPeer(d.eid, ethers.constants.HashZero)).wait()
            log(`${c.name}: peer for ${d.name} unset`)
        }
    }

    const after = await status()
    if (!after.supply.isZero() || after.peers !== 0) throw new Error('mesh not fully retired')
    log(`retired: remote supply ${fmt(before.supply)} -> 0, peers ${before.peers} -> 0`)
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
