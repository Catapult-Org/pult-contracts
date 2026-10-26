import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { expect } from 'chai'
import { Contract, ContractFactory } from 'ethers'
import { deployments, ethers } from 'hardhat'

import { Options } from '@layerzerolabs/lz-v2-utilities'

/**
 * Full mesh under test (EndpointV2Mock, no DVN/executor):
 *   eidBsc       -> CatapultTrade (PULT) + PultOFTAdapter
 *   eidRobinhood -> PultOFT
 *   eidArbitrum  -> PultOFT
 */
describe('PULT bridge: PultOFTAdapter (BSC) <-> PultOFT (Robinhood, Arbitrum)', function () {
    const eidBsc = 1
    const eidRobinhood = 2
    const eidArbitrum = 3

    let CatapultTrade: ContractFactory
    let PultOFTAdapter: ContractFactory
    let PultOFT: ContractFactory
    let EndpointV2Mock: ContractFactory

    let deployer: SignerWithAddress
    let userA: SignerWithAddress
    let userB: SignerWithAddress
    let endpointOwner: SignerWithAddress

    let pult: Contract
    let adapter: Contract
    let oft: Contract
    let oftArb: Contract
    let endpointBsc: Contract
    let endpointRobinhood: Contract
    let endpointArbitrum: Contract

    const options = Options.newOptions().addExecutorLzReceiveOption(200000, 0).toHex().toString()
    const TOTAL_SUPPLY = ethers.utils.parseEther('1000000000')

    // Minimal custom-error matcher (no hardhat-chai-matchers in the LayerZero toolchain)
    const expectRevert = async (promise: Promise<unknown>, customError: string) => {
        try {
            await promise
        } catch (error) {
            expect(String((error as Error).message ?? error)).to.include(customError)
            return
        }
        expect.fail(`expected revert with ${customError}`)
    }

    before(async function () {
        CatapultTrade = await ethers.getContractFactory('CatapultTrade')
        PultOFTAdapter = await ethers.getContractFactory('PultOFTAdapter')
        PultOFT = await ethers.getContractFactory('PultOFT')

        ;[deployer, userA, userB, endpointOwner] = await ethers.getSigners()

        // EndpointV2Mock is an external artifact wired in by @layerzerolabs/toolbox-hardhat
        const EndpointV2MockArtifact = await deployments.getArtifact('EndpointV2Mock')
        EndpointV2Mock = new ContractFactory(EndpointV2MockArtifact.abi, EndpointV2MockArtifact.bytecode, endpointOwner)
    })

    beforeEach(async function () {
        endpointBsc = await EndpointV2Mock.deploy(eidBsc)
        endpointRobinhood = await EndpointV2Mock.deploy(eidRobinhood)
        endpointArbitrum = await EndpointV2Mock.deploy(eidArbitrum)

        pult = await CatapultTrade.deploy(deployer.address, deployer.address)
        adapter = await PultOFTAdapter.deploy(pult.address, endpointBsc.address, deployer.address)
        oft = await PultOFT.deploy('Catapult Trade', 'PULT', endpointRobinhood.address, deployer.address)
        oftArb = await PultOFT.deploy('Catapult Trade', 'PULT', endpointArbitrum.address, deployer.address)

        // Every endpoint must know where each remote OApp lives (full mesh)
        const apps: [Contract, Contract, number][] = [
            [adapter, endpointBsc, eidBsc],
            [oft, endpointRobinhood, eidRobinhood],
            [oftArb, endpointArbitrum, eidArbitrum],
        ]
        for (const [app, endpoint, eid] of apps) {
            for (const [remoteApp, remoteEndpoint, remoteEid] of apps) {
                if (remoteEid === eid) continue
                await endpoint.setDestLzEndpoint(remoteApp.address, remoteEndpoint.address)
                await app.connect(deployer).setPeer(remoteEid, ethers.utils.zeroPad(remoteApp.address, 32))
            }
        }

        await pult.transfer(userA.address, ethers.utils.parseEther('100'))
    })

    const sendParam = (dstEid: number, to: string, amount: ReturnType<typeof ethers.utils.parseEther>) => [
        dstEid,
        ethers.utils.zeroPad(to, 32),
        amount,
        amount,
        options,
        '0x',
        '0x',
    ]

    it('token copy matches the BSC deployment (name/symbol/decimals/supply/owner)', async function () {
        expect(await pult.name()).to.equal('Catapult Trade')
        expect(await pult.symbol()).to.equal('PULT')
        expect(await pult.decimals()).to.equal(18)
        expect(await pult.totalSupply()).eql(TOTAL_SUPPLY)
        expect(await pult.owner()).to.equal(deployer.address)
    })

    it('wires adapter and OFT with default OFT decimals', async function () {
        expect(await adapter.token()).to.equal(pult.address)
        expect(await oft.token()).to.equal(oft.address)
        expect(await adapter.approvalRequired()).to.equal(true)
        expect(await oft.approvalRequired()).to.equal(false)
        expect(await adapter.sharedDecimals()).to.equal(6)
        expect(await oft.sharedDecimals()).to.equal(6)
        expect(await oft.name()).to.equal('Catapult Trade')
        expect(await oft.symbol()).to.equal('PULT')
        expect(await oft.totalSupply()).eql(ethers.BigNumber.from(0))
    })

    it('locks PULT on BSC and mints PultOFT on Robinhood', async function () {
        const initial = await pult.balanceOf(userA.address)
        const tokensToSend = ethers.utils.parseEther('1')

        const params = sendParam(eidRobinhood, userB.address, tokensToSend)
        const [nativeFee] = await adapter.quoteSend(params, false)

        await pult.connect(userA).approve(adapter.address, tokensToSend)
        await adapter.connect(userA).send(params, [nativeFee, 0], userA.address, { value: nativeFee })

        expect(await pult.balanceOf(userA.address)).eql(initial.sub(tokensToSend))
        expect(await pult.balanceOf(adapter.address)).eql(tokensToSend)
        expect(await oft.balanceOf(userB.address)).eql(tokensToSend)
        expect(await oft.totalSupply()).eql(tokensToSend)
    })

    it('burns PultOFT on Robinhood and unlocks PULT on BSC', async function () {
        const bridged = ethers.utils.parseEther('10')
        const back = ethers.utils.parseEther('4')

        let params = sendParam(eidRobinhood, userB.address, bridged)
        let [nativeFee] = await adapter.quoteSend(params, false)
        await pult.connect(userA).approve(adapter.address, bridged)
        await adapter.connect(userA).send(params, [nativeFee, 0], userA.address, { value: nativeFee })

        params = sendParam(eidBsc, userA.address, back)
        ;[nativeFee] = await oft.quoteSend(params, false)
        await oft.connect(userB).send(params, [nativeFee, 0], userB.address, { value: nativeFee })

        expect(await oft.balanceOf(userB.address)).eql(bridged.sub(back))
        expect(await oft.totalSupply()).eql(bridged.sub(back))
        expect(await pult.balanceOf(adapter.address)).eql(bridged.sub(back))
        expect(await pult.balanceOf(userA.address)).eql(ethers.utils.parseEther('100').sub(bridged).add(back))
    })

    it('rejects sends that would lose more than the dust to slippage', async function () {
        const amountWithDust = ethers.utils.parseEther('1').add(1)
        const params = sendParam(eidRobinhood, userB.address, amountWithDust)
        await expectRevert(adapter.quoteSend(params, false), 'SlippageExceeded')
    })

    it('rejects sends without allowance', async function () {
        const tokensToSend = ethers.utils.parseEther('1')
        const params = sendParam(eidRobinhood, userB.address, tokensToSend)
        const [nativeFee] = await adapter.quoteSend(params, false)
        await expectRevert(
            adapter.connect(userA).send(params, [nativeFee, 0], userA.address, { value: nativeFee }),
            'ERC20InsufficientAllowance'
        )
    })

    it('applies a configurable fee on send and lets the owner withdraw it', async function () {
        await adapter.connect(deployer).setDefaultFeeBps(100) // 1%
        const tokensToSend = ethers.utils.parseEther('1')
        const expected = ethers.utils.parseEther('0.99')

        const params = [
            eidRobinhood,
            ethers.utils.zeroPad(userB.address, 32),
            tokensToSend,
            expected,
            options,
            '0x',
            '0x',
        ]
        const [, , receipt] = await adapter.quoteOFT(params)
        expect(receipt.amountReceivedLD).eql(expected)

        const [nativeFee] = await adapter.quoteSend(params, false)
        await pult.connect(userA).approve(adapter.address, tokensToSend)
        await adapter.connect(userA).send(params, [nativeFee, 0], userA.address, { value: nativeFee })

        expect(await oft.balanceOf(userB.address)).eql(expected)
        expect(await adapter.feeBalance()).eql(tokensToSend.sub(expected))
        expect(await pult.balanceOf(adapter.address)).eql(tokensToSend)

        await expectRevert(adapter.connect(userA).withdrawFees(userA.address), 'OwnableUnauthorizedAccount')
        await adapter.connect(deployer).withdrawFees(userB.address)
        expect(await pult.balanceOf(userB.address)).eql(tokensToSend.sub(expected))
        expect(await adapter.feeBalance()).eql(ethers.BigNumber.from(0))
        expect(await pult.balanceOf(adapter.address)).eql(expected)
    })

    const bridge = async (
        app: Contract,
        from: SignerWithAddress,
        dstEid: number,
        to: string,
        amount: ReturnType<typeof ethers.utils.parseEther>
    ) => {
        const params = sendParam(dstEid, to, amount)
        const [nativeFee] = await app.quoteSend(params, false)
        if (app.address === adapter.address) await pult.connect(from).approve(adapter.address, amount)
        await app.connect(from).send(params, [nativeFee, 0], from.address, { value: nativeFee })
    }

    // Backing invariant over the whole mesh
    const expectBacked = async () => {
        const remoteSupply = (await oft.totalSupply()).add(await oftArb.totalSupply())
        expect(await pult.balanceOf(adapter.address)).eql(remoteSupply.add(await adapter.feeBalance()))
    }

    it('locks PULT on BSC and mints PultOFT on Arbitrum', async function () {
        const amount = ethers.utils.parseEther('3')
        await bridge(adapter, userA, eidArbitrum, userB.address, amount)

        expect(await oftArb.balanceOf(userB.address)).eql(amount)
        expect(await oftArb.totalSupply()).eql(amount)
        expect(await oft.totalSupply()).eql(ethers.BigNumber.from(0))
        await expectBacked()
    })

    it('moves PultOFT directly between Robinhood and Arbitrum without touching BSC', async function () {
        const amount = ethers.utils.parseEther('10')
        await bridge(adapter, userA, eidRobinhood, userB.address, amount)
        const locked = await pult.balanceOf(adapter.address)

        const hop = ethers.utils.parseEther('6')
        await bridge(oft, userB, eidArbitrum, userA.address, hop)
        expect(await oft.totalSupply()).eql(amount.sub(hop))
        expect(await oftArb.balanceOf(userA.address)).eql(hop)

        const back = ethers.utils.parseEther('2')
        await bridge(oftArb, userA, eidRobinhood, userB.address, back)
        expect(await oftArb.totalSupply()).eql(hop.sub(back))
        expect(await oft.balanceOf(userB.address)).eql(amount.sub(hop).add(back))

        expect(await pult.balanceOf(adapter.address)).eql(locked)
        await expectBacked()
    })

    it('burns PultOFT on Arbitrum and unlocks PULT on BSC', async function () {
        const amount = ethers.utils.parseEther('5')
        await bridge(adapter, userA, eidArbitrum, userB.address, amount)

        const before = await pult.balanceOf(userB.address)
        const back = ethers.utils.parseEther('5')
        await bridge(oftArb, userB, eidBsc, userB.address, back)

        expect(await oftArb.totalSupply()).eql(ethers.BigNumber.from(0))
        expect(await pult.balanceOf(userB.address)).eql(before.add(back))
        expect(await pult.balanceOf(adapter.address)).eql(ethers.BigNumber.from(0))
        await expectBacked()
    })

    it('applies per-destination fees only to the configured destination', async function () {
        await adapter.connect(deployer).setFeeBps(eidArbitrum, 50, true) // 0.5% BSC -> Arbitrum only
        const amount = ethers.utils.parseEther('10')

        const toArb = sendParam(eidArbitrum, userB.address, amount)
        toArb[3] = 0
        const [, , arbReceipt] = await adapter.quoteOFT(toArb)
        expect(arbReceipt.amountReceivedLD).eql(ethers.utils.parseEther('9.95'))

        const toRobinhood = sendParam(eidRobinhood, userB.address, amount)
        const [, , rhReceipt] = await adapter.quoteOFT(toRobinhood)
        expect(rhReceipt.amountReceivedLD).eql(amount)

        toArb[3] = arbReceipt.amountReceivedLD
        const [nativeFee] = await adapter.quoteSend(toArb, false)
        await pult.connect(userA).approve(adapter.address, amount)
        await adapter.connect(userA).send(toArb, [nativeFee, 0], userA.address, { value: nativeFee })
        await bridge(adapter, userA, eidRobinhood, userB.address, amount)

        expect(await oftArb.balanceOf(userB.address)).eql(ethers.utils.parseEther('9.95'))
        expect(await oft.balanceOf(userB.address)).eql(amount)
        expect(await adapter.feeBalance()).eql(ethers.utils.parseEther('0.05'))
        await expectBacked()
    })
})
