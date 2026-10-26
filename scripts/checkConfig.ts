import fs from 'fs'
import path from 'path'

import { ethers } from 'ethers'
import { config } from 'hardhat'

import { EndpointId } from '@layerzerolabs/lz-definitions'
import { Options } from '@layerzerolabs/lz-v2-utilities'

/**
 * Reads the LIVE LayerZero configuration of every pathway in a LayerZero config file and compares it with what the
 * file declares. Exits non-zero on any mismatch, so it can gate "open the bridge".
 *
 * Per connection (A -> B), all on chain A: peer, send library, executor, send ULN config (confirmations, required
 * DVNs, no optional DVNs) and enforced options for SEND / SEND_AND_CALL towards B, plus A's receive library and receive
 * ULN config for messages coming FROM B (that is what `receiveConfig` of the A -> B connection configures).
 * ULN configs are read through `EndpointV2.getConfig`, i.e. the EFFECTIVE config the protocol uses (OApp config
 * merged with defaults), so a left-over default such as LZDeadDVN shows up as a mismatch.
 * Also checks that every OApp's endpoint delegate is its owner, and that it has NO peers besides the declared ones:
 * `peers(eid)` is read for every LayerZero V2 endpoint id of the same stage (mainnet 30xxx / testnet 40xxx) listed in
 * @layerzerolabs/lz-definitions, so a stray peer (wrong eid, an old staging contract) fails the check. Current state
 * only, so it works on any public RPC (no event history / archive access needed).
 *
 * Usage: LZ_CONFIG=layerzero.config.ts [DEPLOY_STAGE=staging] npx hardhat run scripts/checkConfig.ts
 */
const ENDPOINT_ABI = [
    'function getSendLibrary(address sender, uint32 dstEid) view returns (address)',
    'function getReceiveLibrary(address receiver, uint32 srcEid) view returns (address lib, bool isDefault)',
    'function getConfig(address oapp, address lib, uint32 eid, uint32 configType) view returns (bytes)',
    'function delegates(address oapp) view returns (address)',
]
const OAPP_ABI = [
    'function peers(uint32 eid) view returns (bytes32)',
    'function enforcedOptions(uint32 eid, uint16 msgType) view returns (bytes)',
    'function owner() view returns (address)',
    'function endpoint() view returns (address)',
]
const V2_EIDS = [...new Set(Object.values(EndpointId).filter((x): x is number => typeof x === 'number'))]
const CONFIG_TYPE_EXECUTOR = 1
const CONFIG_TYPE_ULN = 2
const ULN_TUPLE =
    'tuple(uint64 confirmations, uint8 requiredDVNCount, uint8 optionalDVNCount, uint8 optionalDVNThreshold, address[] requiredDVNs, address[] optionalDVNs)'
const EXECUTOR_TUPLE = 'tuple(uint32 maxMessageSize, address executor)'

interface UlnConfig {
    confirmations: bigint | number | string
    requiredDVNs: string[]
    optionalDVNs: string[]
    optionalDVNThreshold: number
}

const lower = (xs: string[]) => xs.map((x) => x.toLowerCase()).sort()

async function main() {
    const lzConfigPath = path.resolve(process.env.LZ_CONFIG ?? 'layerzero.config.ts')
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const lzConfig = await require(lzConfigPath).default()

    // eid -> hardhat network (name, url)
    const networkByEid = new Map<number, { name: string; url: string }>()
    for (const [name, net] of Object.entries(config.networks)) {
        const eid = (net as { eid?: number }).eid
        const url = (net as { url?: string }).url
        if (eid != null && url != null) networkByEid.set(eid, { name, url })
    }
    const network = (eid: number) => {
        const net = networkByEid.get(eid)
        if (net == null) throw new Error(`no hardhat network with eid ${eid}`)
        return net
    }
    const providers = new Map<number, ethers.providers.Provider>()
    const provider = (eid: number) => {
        let p = providers.get(eid)
        if (p == null) {
            p = new ethers.providers.StaticJsonRpcProvider(network(eid).url)
            providers.set(eid, p)
        }
        return p
    }
    const addressOf = (point: { eid: number; contractName?: string; address?: string }) => {
        if (point.address) return point.address
        const file = path.join(config.paths.deployments, network(point.eid).name, `${point.contractName}.json`)
        if (!fs.existsSync(file)) throw new Error(`missing deployment ${file}`)
        return JSON.parse(fs.readFileSync(file, 'utf8')).address as string
    }

    /** Live non-zero peers (eid -> peer) of `addr` over every V2 eid of the same stage as `eid`. */
    const livePeers = async (eid: number, addr: string) => {
        const oapp = new ethers.Contract(addr, OAPP_ABI, provider(eid))
        const stage = Math.floor(eid / 10_000)
        const candidates = V2_EIDS.filter((e) => Math.floor(e / 10_000) === stage)
        const peers = new Map<number, string>()
        for (let i = 0; i < candidates.length; i += 25) {
            const batch = candidates.slice(i, i + 25)
            const results: string[] = await Promise.all(batch.map((e) => oapp.peers(e)))
            batch.forEach((e, j) => {
                const peer = (results[j] ?? ethers.constants.HashZero).toLowerCase()
                if (peer !== ethers.constants.HashZero) peers.set(e, peer)
            })
        }
        return peers
    }

    const failures: string[] = []
    const check = (ok: boolean, label: string, detail = '') => {
        console.log(`${ok ? '  ok  ' : '  FAIL'} ${label}${detail ? `: ${detail}` : ''}`)
        if (!ok) failures.push(`${label} ${detail}`)
    }
    const coder = ethers.utils.defaultAbiCoder

    console.log(`config=${path.relative(process.cwd(), lzConfigPath)} deployments=${config.paths.deployments}\n`)

    // owner / delegate per OApp
    for (const { contract } of lzConfig.contracts) {
        const addr = addressOf(contract)
        const oapp = new ethers.Contract(addr, OAPP_ABI, provider(contract.eid))
        const endpoint = new ethers.Contract(await oapp.endpoint(), ENDPOINT_ABI, provider(contract.eid))
        const [owner, delegate] = await Promise.all([oapp.owner(), endpoint.delegates(addr)])
        console.log(`${network(contract.eid).name} ${contract.contractName} ${addr} owner=${owner}`)
        check(owner === delegate, `  delegate == owner`, `${delegate}`)

        // no peers besides the declared connections
        const declared = new Map<number, string>()
        for (const c of lzConfig.connections) {
            if (c.from.eid === contract.eid && c.from.contractName === contract.contractName) {
                declared.set(c.to.eid, ethers.utils.hexZeroPad(addressOf(c.to), 32).toLowerCase())
            }
        }
        const live = await livePeers(contract.eid, addr)
        const stray = [...live].filter(([eid, peer]) => declared.get(eid) !== peer)
        check(
            stray.length === 0,
            `  no undeclared peers`,
            stray.length ? stray.map(([eid, peer]) => `${eid}=${peer}`).join(', ') : `${declared.size} declared`
        )
    }

    for (const { from, to, config: expected } of lzConfig.connections) {
        const fromNet = network(from.eid).name
        const toNet = network(to.eid).name
        console.log(`\n${fromNet} (${from.eid}) -> ${toNet} (${to.eid})`)

        const fromAddr = addressOf(from)
        const toAddr = addressOf(to)
        const fromApp = new ethers.Contract(fromAddr, OAPP_ABI, provider(from.eid))
        const fromEndpoint = new ethers.Contract(await fromApp.endpoint(), ENDPOINT_ABI, provider(from.eid))

        // peer
        const peer = await fromApp.peers(to.eid)
        check(peer.toLowerCase() === ethers.utils.hexZeroPad(toAddr, 32).toLowerCase(), 'peer', peer)

        // send side
        const sendLib: string = await fromEndpoint.getSendLibrary(fromAddr, to.eid)
        if (expected?.sendLibrary) {
            check(sendLib.toLowerCase() === expected.sendLibrary.toLowerCase(), 'send library', sendLib)
        }
        const [executorCfg] = coder.decode(
            [EXECUTOR_TUPLE],
            await fromEndpoint.getConfig(fromAddr, sendLib, to.eid, CONFIG_TYPE_EXECUTOR)
        )
        const expectedExecutor = expected?.sendConfig?.executorConfig?.executor
        check(
            expectedExecutor
                ? executorCfg.executor.toLowerCase() === expectedExecutor.toLowerCase()
                : executorCfg.executor !== ethers.constants.AddressZero,
            'executor',
            executorCfg.executor
        )
        const [sendUln] = coder.decode(
            [ULN_TUPLE],
            await fromEndpoint.getConfig(fromAddr, sendLib, to.eid, CONFIG_TYPE_ULN)
        )
        checkUln('send ULN', sendUln, expected?.sendConfig?.ulnConfig, check)

        // enforced options
        for (const msgType of [1, 2]) {
            const onChain: string = await fromApp.enforcedOptions(to.eid, msgType)
            const wanted = (expected?.enforcedOptions ?? []).filter((o: { msgType: number }) => o.msgType === msgType)
            let options = Options.newOptions()
            for (const o of wanted) options = options.addExecutorLzReceiveOption(o.gas, o.value)
            const expectedHex = wanted.length ? options.toHex() : '0x'
            const gas = onChain !== '0x' ? Options.fromOptions(onChain).decodeExecutorLzReceiveOption()?.gas : 0
            check(
                onChain.toLowerCase() === expectedHex.toLowerCase(),
                `enforced options msgType ${msgType}`,
                `lzReceive gas ${gas}`
            )
        }

        // receive side: A receiving messages from B
        const [receiveLib] = await fromEndpoint.getReceiveLibrary(fromAddr, to.eid)
        if (expected?.receiveLibraryConfig?.receiveLibrary) {
            check(
                receiveLib.toLowerCase() === expected.receiveLibraryConfig.receiveLibrary.toLowerCase(),
                `receive library (from ${toNet})`,
                receiveLib
            )
        }
        const [receiveUln] = coder.decode(
            [ULN_TUPLE],
            await fromEndpoint.getConfig(fromAddr, receiveLib, to.eid, CONFIG_TYPE_ULN)
        )
        checkUln(`receive ULN (from ${toNet})`, receiveUln, expected?.receiveConfig?.ulnConfig, check)
    }

    console.log(failures.length ? `\n${failures.length} check(s) FAILED` : '\nall checks passed')
    if (failures.length) process.exit(1)
}

function checkUln(
    label: string,
    actual: { confirmations: ethers.BigNumber; requiredDVNs: string[]; optionalDVNs: string[] },
    expected: UlnConfig | undefined,
    check: (ok: boolean, label: string, detail?: string) => void
) {
    const detail = `confirmations=${actual.confirmations} required=[${actual.requiredDVNs.join(', ')}] optional=[${actual.optionalDVNs.join(', ')}]`
    if (expected == null) {
        check(false, label, `not declared in config; live: ${detail}`)
        return
    }
    const ok =
        actual.confirmations.toString() === expected.confirmations.toString() &&
        JSON.stringify(lower(actual.requiredDVNs)) === JSON.stringify(lower(expected.requiredDVNs)) &&
        JSON.stringify(lower(actual.optionalDVNs)) === JSON.stringify(lower(expected.optionalDVNs))
    check(ok, label, detail)
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
