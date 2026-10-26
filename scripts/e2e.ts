import fs from 'fs'
import path from 'path'

import { BigNumber, Contract, Wallet, ethers } from 'ethers'
import { artifacts, config } from 'hardhat'

/**
 * End-to-end test of a LIVE mesh (BSC adapter + Robinhood / Arbitrum OFTs) with real LayerZero DVNs and executors.
 *
 *   user  = TEST_PRIVATE_KEY (needs gas on all three chains + PULT on BSC)
 *   owner = PRIVATE_KEY / MAINNET_PRIVATE_KEY (OApp owner; sets / withdraws fees)
 *
 * Flow (amounts in PULT, E2E_AMOUNT scales them, default 100):
 *   1. no fee:   BSC -> Robinhood 3x, BSC -> Arbitrum 3x, Robinhood -> Arbitrum 1x, Arbitrum -> Robinhood 0.5x
 *   2. guards:   owner cannot set 501 bps; recipient 0 / recipient == destination OApp / an amount that would deliver
 *                nothing / withdrawFees(to == contract) all revert
 *      fees:     5 % on Arbitrum -> Robinhood, 1 % on BSC -> Arbitrum with a dusty amount
 *   3. fees:     owner withdraws all fee balances, resets fees to 0 (fees are also reset in a `finally` if any
 *                stage 2-3 step fails, so an aborted run never leaves fees switched on)
 *   4. return:   everything (user balances and withdrawn OFT fees) is bridged back to BSC
 * After every delivered stage: backing invariant
 *   PULT.balanceOf(adapter) == supply(Robinhood) + supply(Arbitrum) + adapter.feeBalance
 * and exact balance checks (received == quoteOFT, fee == formula).
 *
 * Usage: DEPLOY_STAGE=staging NETWORKS=bsc,robinhood,arbitrum npx hardhat run scripts/e2e.ts   (or `pnpm e2e`)
 * The script changes fees with the owner key, so it refuses to run against production (DEPLOY_STAGE unset) unless
 * E2E_ALLOW_PRODUCTION=1 is set explicitly (e.g. the small post-deploy check before the bridge is announced).
 */
const DELIVERY_TIMEOUT_MS = 30 * 60 * 1000
// RPCs used only for eth_getLogs (delivery detection). bsc-dataseed rejects every eth_getLogs ("limit exceeded"),
// publicnode serves logs but rejects some other calls without a token. Override: E2E_LOGS_RPC_<NETWORK>.
const DEFAULT_LOGS_RPC: Record<string, string> = { bsc: 'https://bsc-rpc.publicnode.com' }
const POLL_MS = 10_000
const BPS = 10_000

type Chain = {
    name: string
    eid: number
    isHome: boolean
    provider: ethers.providers.StaticJsonRpcProvider
    user: Wallet
    owner: Wallet
    app: Contract // PultOFTAdapter or PultOFT (connected to user)
    logs: Contract // same contract on the logs RPC, read-only
    token: Contract // PULT on BSC, the PultOFT itself elsewhere (connected to user)
}

const fmt = (x: BigNumber) => ethers.utils.formatEther(x)
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

function log(msg: string) {
    console.log(`[${new Date().toISOString().slice(11, 19)}] ${msg}`)
}

async function main() {
    if (!process.env.DEPLOY_STAGE && process.env.E2E_ALLOW_PRODUCTION !== '1') {
        throw new Error('refusing to run against production: set DEPLOY_STAGE=staging, or E2E_ALLOW_PRODUCTION=1')
    }
    const userKey = process.env.TEST_PRIVATE_KEY
    const ownerKey = process.env.PRIVATE_KEY || process.env.MAINNET_PRIVATE_KEY
    if (!userKey || !ownerKey) throw new Error('TEST_PRIVATE_KEY and PRIVATE_KEY must be set')
    const unit = ethers.utils.parseEther(process.env.E2E_AMOUNT ?? '100')

    const names = (process.env.NETWORKS ?? 'bsc,robinhood,arbitrum').split(',')
    const adapterAbi = (await artifacts.readArtifact('PultOFTAdapter')).abi
    const oftAbi = (await artifacts.readArtifact('PultOFT')).abi
    const erc20Abi = (await artifacts.readArtifact('CatapultTrade')).abi

    const chains: Chain[] = []
    for (const name of names) {
        const net = config.networks[name] as { url: string; eid: number; oftAdapter?: unknown }
        const isHome = net.oftAdapter != null
        const contractName = isHome ? 'PultOFTAdapter' : 'PultOFT'
        const file = path.join(config.paths.deployments, name, `${contractName}.json`)
        const { address } = JSON.parse(fs.readFileSync(file, 'utf8'))
        const provider = new ethers.providers.StaticJsonRpcProvider(net.url)
        const user = new Wallet(userKey, provider)
        const owner = new Wallet(ownerKey, provider)
        const app = new Contract(address, isHome ? adapterAbi : oftAbi, user)
        const token = isHome ? new Contract(await app.token(), erc20Abi, user) : app
        const logsUrl =
            process.env[`E2E_LOGS_RPC_${name.toUpperCase().replace(/-/g, '_')}`] ?? DEFAULT_LOGS_RPC[name] ?? net.url
        const logs = new Contract(
            address,
            isHome ? adapterAbi : oftAbi,
            new ethers.providers.StaticJsonRpcProvider(logsUrl)
        )
        chains.push({ name, eid: net.eid, isHome, provider, user, owner, app, token, logs })
    }
    const [bsc, robinhood, arbitrum] = chains as [Chain, Chain, Chain]
    if (!bsc.isHome || robinhood.isHome || arbitrum.isHome) throw new Error('NETWORKS must be: home,oft,oft')

    log(`deployments=${config.paths.deployments} user=${bsc.user.address} owner=${bsc.owner.address}`)
    for (const c of chains) {
        log(
            `${c.name}: app=${c.app.address} native=${fmt(await c.user.getBalance())} token=${fmt(await c.token.balanceOf(c.user.address))}`
        )
    }

    // ------------------------------------------------------------------ helpers

    const checkInvariant = async (label: string) => {
        const [locked, s1, s2, adapterFees, f1, f2, own1, own2] = await Promise.all([
            bsc.token.balanceOf(bsc.app.address),
            robinhood.app.totalSupply(),
            arbitrum.app.totalSupply(),
            bsc.app.feeBalance(),
            robinhood.app.feeBalance(),
            arbitrum.app.feeBalance(),
            robinhood.app.balanceOf(robinhood.app.address),
            arbitrum.app.balanceOf(arbitrum.app.address),
        ])
        const backed = s1.add(s2).add(adapterFees)
        log(
            `invariant [${label}] locked=${fmt(locked)} supplyRobinhood=${fmt(s1)} supplyArbitrum=${fmt(s2)} adapterFees=${fmt(adapterFees)}`
        )
        if (!locked.eq(backed)) throw new Error(`backing invariant broken: ${fmt(locked)} != ${fmt(backed)}`)
        if (!own1.eq(f1) || !own2.eq(f2)) throw new Error('OFT fee custody broken (self balance != feeBalance)')
    }

    // A delivery is matched by the LayerZero message GUID: OFTSent(guid) on the source, OFTReceived(guid) on the
    // destination. Balance diffs would be wrong when the same wallet sends and receives on a chain concurrently.
    // Pay the chain's current gas price + 25 % (legacy tx): the base fee may tick up between read and send. ethers v5
    // would otherwise use a 1.5 gwei priority fee, ~30x the BSC price, and drain small test wallets.
    const gas = async (c: Chain) => ({ type: 0, gasPrice: (await c.provider.getGasPrice()).mul(125).div(100) })

    type Pending = {
        to: Chain
        recipient: string
        guid: string
        fromBlock: number
        expected: BigNumber
        tx: string
        label: string
    }

    /** Sends from `src` to `dst`; minAmountLD pinned to quoteOFT. Returns a pending delivery. */
    const send = async (
        src: Chain,
        dst: Chain,
        amount: BigNumber,
        opts: { signer?: 'user' | 'owner'; expectedReceived?: BigNumber } = {}
    ): Promise<Pending> => {
        const signer = opts.signer === 'owner' ? src.owner : src.user
        const app = src.app.connect(signer)
        const recipient = signer.address
        const sendParam = {
            dstEid: dst.eid,
            to: ethers.utils.hexZeroPad(recipient, 32),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: '0x',
            composeMsg: '0x',
            oftCmd: '0x',
        }
        const [, , receipt] = await app.quoteOFT(sendParam)
        if (opts.expectedReceived && !receipt.amountReceivedLD.eq(opts.expectedReceived)) {
            throw new Error(
                `quoteOFT ${fmt(receipt.amountReceivedLD)} != expected ${fmt(opts.expectedReceived)} (${src.name} -> ${dst.name})`
            )
        }
        sendParam.minAmountLD = receipt.amountReceivedLD
        const fee = await app.quoteSend(sendParam, false)

        if (src.isHome) {
            const token = src.token.connect(signer)
            if ((await token.allowance(recipient, app.address)).lt(amount)) {
                await (await token.approve(app.address, amount, await gas(src))).wait()
            }
        }
        const fromBlock = await dst.provider.getBlockNumber()
        const tx = await app.send(sendParam, { nativeFee: fee.nativeFee, lzTokenFee: 0 }, recipient, {
            value: fee.nativeFee,
            ...(await gas(src)),
        })
        const mined = await tx.wait()
        const sent = mined.events?.find((e: ethers.Event) => e.event === 'OFTSent')
        if (sent?.args == null) throw new Error(`no OFTSent event in ${tx.hash}`)
        if (!sent.args.amountReceivedLD.eq(receipt.amountReceivedLD)) throw new Error('OFTSent amount != quote')
        const label = `${src.name} -> ${dst.name} ${fmt(amount)} (receives ${fmt(receipt.amountReceivedLD)})`
        log(`sent ${label} lzFee=${fmt(fee.nativeFee)} https://layerzeroscan.com/tx/${tx.hash}`)
        return {
            to: dst,
            recipient,
            guid: sent.args.guid,
            fromBlock,
            expected: receipt.amountReceivedLD,
            tx: tx.hash,
            label,
        }
    }

    /** Waits until every pending message is executed on its destination and credited exactly. */
    const deliver = async (pending: Pending[]) => {
        const started = Date.now()
        const open = new Set(pending)
        while (open.size) {
            for (const p of [...open]) {
                let logs: ethers.Event[]
                try {
                    logs = await p.to.logs.queryFilter(p.to.logs.filters.OFTReceived(p.guid), p.fromBlock, 'latest')
                } catch (e) {
                    // public RPCs rate-limit eth_getLogs; retry on the next poll
                    log(`${p.to.name}: getLogs failed (${String((e as Error).message).slice(0, 80)}), retrying`)
                    continue
                }
                const received = logs[0]?.args
                if (received != null) {
                    if (received.toAddress.toLowerCase() !== p.recipient.toLowerCase()) {
                        throw new Error(`${p.label}: delivered to ${received.toAddress}`)
                    }
                    if (!received.amountReceivedLD.eq(p.expected)) {
                        throw new Error(`${p.label}: credited ${fmt(received.amountReceivedLD)}`)
                    }
                    log(
                        `delivered ${p.label} after ${Math.round((Date.now() - started) / 1000)}s (${logs[0]?.transactionHash})`
                    )
                    open.delete(p)
                }
            }
            if (!open.size) break
            if (Date.now() - started > DELIVERY_TIMEOUT_MS) {
                throw new Error(`not delivered: ${[...open].map((p) => `${p.label} ${p.tx}`).join('; ')}`)
            }
            await sleep(POLL_MS)
        }
    }

    const ownerTx = async (label: string, fn: () => Promise<ethers.ContractTransaction>) => {
        const tx = await fn()
        await tx.wait()
        log(`owner: ${label} ${tx.hash}`)
    }

    // The user's PULT across all three chains; it may hold PultOFT left over from an interrupted run, which step 4
    // bridges back. Only the bridge fees may be lost between start and end.
    const userTotal = async () => {
        const [a, b, c] = await Promise.all(chains.map((ch) => ch.token.balanceOf(ch.user.address)))
        return (a as BigNumber).add(b as BigNumber).add(c as BigNumber)
    }
    // Sets every fee this script touches back to 0 (default fees + the Arbitrum -> Robinhood override). Used at the
    // start (leftovers from an interrupted run) and in the `finally` of stages 2-3.
    const resetFees = async () => {
        for (const c of chains) {
            if ((await c.app.defaultFeeBps()) !== 0) {
                await ownerTx(`${c.name} default fee reset to 0`, async () =>
                    c.app.connect(c.owner).setDefaultFeeBps(0, await gas(c))
                )
            }
        }
        if ((await arbitrum.app.feeBps(robinhood.eid)).enabled) {
            await ownerTx('Arbitrum fee override to Robinhood removed', async () =>
                arbitrum.app.connect(arbitrum.owner).setFeeBps(robinhood.eid, 0, false, await gas(arbitrum))
            )
        }
    }
    await resetFees()

    await checkInvariant('start')
    const startTotal = await userTotal()
    const startPult: BigNumber = await bsc.token.balanceOf(bsc.user.address)
    if (startPult.lt(unit.mul(7))) throw new Error(`user needs >= ${fmt(unit.mul(7))} PULT on BSC`)

    // ------------------------------------------------------------------ 1. all directions, no fee
    log('=== 1. all directions without fee')
    for (const c of chains) {
        if ((await c.app.defaultFeeBps()) !== 0) throw new Error(`${c.name}: default fee must be 0 at start`)
    }
    await deliver([
        await send(bsc, robinhood, unit.mul(3), { expectedReceived: unit.mul(3) }),
        await send(bsc, arbitrum, unit.mul(3), { expectedReceived: unit.mul(3) }),
    ])
    await checkInvariant('after BSC -> OFTs')
    const lockedBefore: BigNumber = await bsc.token.balanceOf(bsc.app.address)
    await deliver([
        await send(robinhood, arbitrum, unit, { expectedReceived: unit }),
        await send(arbitrum, robinhood, unit.div(2), { expectedReceived: unit.div(2) }),
    ])
    if (!(await bsc.token.balanceOf(bsc.app.address)).eq(lockedBefore)) {
        throw new Error('OFT <-> OFT transfer changed the BSC lockbox')
    }
    await checkInvariant('after Robinhood <-> Arbitrum')

    // ------------------------------------------------------------------ 2. guards, fee cap + fees
    log('=== 2. guards, fee cap and fees')
    /** Requires `call` to revert with the custom error `name` (checked by its 4-byte selector in the revert data). */
    const expectRevert = async (
        label: string,
        iface: ethers.utils.Interface,
        name: string,
        call: () => Promise<unknown>
    ) => {
        const selector = iface.getSighash(name)
        try {
            await call()
        } catch (e) {
            if (JSON.stringify(e, Object.getOwnPropertyNames(e)).toLowerCase().includes(selector.slice(2))) return
            throw new Error(`${label}: reverted, but not with ${name}: ${String((e as Error).message).slice(0, 200)}`)
        }
        throw new Error(`${label}: expected ${name}, call succeeded`)
    }
    const maxFee: number = await arbitrum.app.MAX_FEE_BPS()
    if (maxFee !== 500) throw new Error(`MAX_FEE_BPS = ${maxFee}`)
    const param = (dst: Chain, to: string, amount: BigNumber) => ({
        dstEid: dst.eid,
        to,
        amountLD: amount,
        minAmountLD: 0,
        extraOptions: '0x',
        composeMsg: '0x',
        oftCmd: '0x',
    })
    const userTo = ethers.utils.hexZeroPad(bsc.user.address, 32)
    for (const c of chains) {
        const owner = c.app.connect(c.owner)
        const dst = c === bsc ? robinhood : bsc
        const iface = c.app.interface
        await expectRevert(`${c.name} setDefaultFeeBps(501)`, iface, 'InvalidBps', () =>
            owner.callStatic.setDefaultFeeBps(maxFee + 1)
        )
        await expectRevert(`${c.name} setFeeBps(.., 501)`, iface, 'InvalidBps', () =>
            owner.callStatic.setFeeBps(dst.eid, maxFee + 1, true)
        )
        await expectRevert(`${c.name} recipient 0`, iface, 'InvalidRecipient', () =>
            c.app.quoteSend(param(dst, ethers.constants.HashZero, unit), false)
        )
        await expectRevert(`${c.name} recipient == ${dst.name} OApp`, iface, 'InvalidRecipient', () =>
            c.app.quoteSend(param(dst, ethers.utils.hexZeroPad(dst.app.address, 32), unit), false)
        )
        await expectRevert(`${c.name} amount < 1e12 wei`, iface, 'AmountTooSmall', () =>
            c.app.quoteOFT(param(dst, userTo, BigNumber.from(10).pow(12).sub(1)))
        )
        await expectRevert(`${c.name} withdrawFees(this)`, iface, 'InvalidRecipient', () =>
            owner.callStatic.withdrawFees(c.app.address)
        )
        log(`${c.name}: fee > 5 %, recipient 0 / OApp, sub-unit amount, withdrawFees(this) all revert`)
    }

    const removeDust = (x: BigNumber) => x.div(1e12).mul(1e12)

    // Fees are switched on from here: always switch them off again, also when a step below throws.
    let arbFee = BigNumber.from(0)
    let adapterFee = BigNumber.from(0)
    try {
        await ownerTx('Arbitrum fee to Robinhood = 500 bps', async () =>
            arbitrum.app.connect(arbitrum.owner).setFeeBps(robinhood.eid, maxFee, true, await gas(arbitrum))
        )
        await ownerTx('BSC default fee = 100 bps', async () =>
            bsc.app.connect(bsc.owner).setDefaultFeeBps(100, await gas(bsc))
        )

        const dusty = unit.add(123_456_789) // < 1e12 wei of dust on top
        const expectArb = removeDust(unit.sub(unit.mul(maxFee).div(BPS)))
        const expectBsc = removeDust(dusty.sub(dusty.mul(100).div(BPS)))
        const arbFeesBefore: BigNumber = await arbitrum.app.feeBalance()
        const adapterFeesBefore: BigNumber = await bsc.app.feeBalance()
        await deliver([
            await send(arbitrum, robinhood, unit, { expectedReceived: expectArb }),
            await send(bsc, arbitrum, dusty, { expectedReceived: expectBsc }),
        ])
        arbFee = (await arbitrum.app.feeBalance()).sub(arbFeesBefore)
        adapterFee = (await bsc.app.feeBalance()).sub(adapterFeesBefore)
        if (!arbFee.eq(unit.sub(expectArb))) throw new Error(`Arbitrum fee ${fmt(arbFee)}`)
        if (!adapterFee.eq(dusty.sub(expectBsc))) throw new Error(`adapter fee ${fmt(adapterFee)}`)
        log(`fees charged: Arbitrum ${fmt(arbFee)} (5 %), BSC adapter ${fmt(adapterFee)} (1 % + dust)`)
        await checkInvariant('after fees')

        // ------------------------------------------------------------------ 3. withdraw + reset fees
        log('=== 3. withdraw fees, reset to 0')
        const withdrawn: Record<string, BigNumber> = {}
        for (const c of chains) {
            const bal: BigNumber = await c.app.feeBalance()
            withdrawn[c.name] = bal
            if (bal.gt(0)) {
                await ownerTx(`${c.name} withdrawFees ${fmt(bal)}`, async () =>
                    c.app.connect(c.owner).withdrawFees(c.owner.address, await gas(c))
                )
            }
            if (!(await c.app.feeBalance()).isZero()) throw new Error(`${c.name}: feeBalance not zero after withdraw`)
        }
    } finally {
        await resetFees()
    }
    await checkInvariant('after withdraw')
    if (
        !(await bsc.token.balanceOf(bsc.app.address)).eq(
            (await robinhood.app.totalSupply()).add(await arbitrum.app.totalSupply())
        )
    ) {
        throw new Error('after withdrawing, the adapter must hold exactly the remote supply')
    }

    // ------------------------------------------------------------------ 4. everything back to BSC
    log('=== 4. bridge everything back to BSC')
    const back: Pending[] = []
    for (const c of [robinhood, arbitrum]) {
        const userBal: BigNumber = await c.token.balanceOf(c.user.address)
        if (userBal.gt(0)) back.push(await send(c, bsc, userBal, { expectedReceived: removeDust(userBal) }))
    }
    await deliver(back)
    const ownerBack: Pending[] = []
    for (const c of [robinhood, arbitrum]) {
        const ownerBal: BigNumber = await c.token.balanceOf(c.owner.address)
        if (ownerBal.gte(1e12)) {
            ownerBack.push(await send(c, bsc, ownerBal, { signer: 'owner', expectedReceived: removeDust(ownerBal) }))
        }
    }
    await deliver(ownerBack)
    await checkInvariant('end')

    const endTotal = await userTotal()
    const userCost = startTotal.sub(endTotal)
    log(`user PULT (all chains): start ${fmt(startTotal)} end ${fmt(endTotal)} (paid ${fmt(userCost)} in bridge fees)`)
    if (!userCost.eq(arbFee.add(adapterFee))) {
        throw new Error(`user lost ${fmt(userCost)}, expected exactly the fees ${fmt(arbFee.add(adapterFee))}`)
    }
    const locked: BigNumber = await bsc.token.balanceOf(bsc.app.address)
    log(`adapter lockbox at end: ${fmt(locked)} PULT (only sub-1e12 dust can remain)`)
    log('E2E PASSED')
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
