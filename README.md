# pult-contracts

PULT token and its LayerZero V2 omnichain bridge.

| Chain                                          | Contract                                         | Role                                                                                                                                        |
| ---------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| BSC (eid `30102`)                              | [`CatapultTrade`](contracts/CatapultTrade.sol)   | Existing PULT ERC20: [`0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154`](https://bscscan.com/address/0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154) |
| BSC (eid `30102`)                              | [`PultOFTAdapter`](contracts/PultOFTAdapter.sol) | LayerZero **OFTAdapter** with optional fee: locks / unlocks PULT                                                                            |
| Robinhood Chain (eid `30416`, chain id `4663`) | [`PultOFT`](contracts/PultOFT.sol)               | LayerZero **OFT** with optional fee: mints / burns PULT                                                                                     |

Built on the official LayerZero `create-lz-oapp` stack: Hardhat 2 + `hardhat-deploy` + `@layerzerolabs/toolbox-hardhat` for
deploy/wiring, Foundry + `TestHelperOz5` for tests.

## Contracts

- `contracts/CatapultTrade.sol` — verbatim source of the verified BSC deployment (OpenZeppelin 5.6.0: `ERC20` + `ERC20Permit` + `Ownable`,
  1 000 000 000 PULT minted to `recipient`, `claimERC20` rescue). Compiled with the same settings as on-chain
  (solc 0.8.34, evmVersion `osaka`, optimizer off) via a per-file override in `hardhat.config.ts`; the resulting
  creation code is identical to the BSC deployment tx except for the CBOR metadata hash (different source file name).
  Only deployed on testnets / locally.
- `contracts/PultOFTAdapter.sol` — `OFTAdapter(token, endpoint, delegate)` + LayerZero `Fee` mixin. **Exactly one** adapter
  may exist in the mesh. PULT has no transfer fee, so lock/unlock accounting is lossless.
- `contracts/PultOFT.sol` — `OFT("Catapult Trade", "PULT", endpoint, delegate)` + LayerZero `Fee` mixin, 18 local / 6 shared
  decimals (`decimalConversionRate = 1e12`, sub-1e12-wei dust is stripped on send). No supply minted at deploy.
- `test/mocks/*` — test-only subclasses exposing `mint` / `removeDust` (not compiled by Hardhat, never deployed).

Invariant: PULT locked in `PultOFTAdapter` == `PultOFT.totalSupply()` + `PultOFTAdapter.feeBalance()`.

## Bridge fee

Both contracts carry the fee model of LayerZero's `OFTAdapterFeeUpgradeable` / `OFTFeeUpgradeable`, re-implemented on the
non-upgradeable base (`@layerzerolabs/oft-evm/contracts/Fee.sol`). Fees are **0 by default**, so behaviour equals the default
OFT until the owner sets one.

| Call (owner only)                                | Effect                                                               |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| `setDefaultFeeBps(bps)`                          | fee for every destination, in basis points (100 = 1%, max 10 000)    |
| `setFeeBps(dstEid, bps, enabled)`                | per-destination override; `enabled=false` falls back to the default  |
| `withdrawFees(to)`                               | pays out `feeBalance` (adapter: PULT on BSC; OFT: PULT on Robinhood) |
| `getFee(dstEid, amount)` / `quoteOFT(sendParam)` | read the fee / the exact `amountReceivedLD` for a send               |

Mechanics: on `send`, `amountSentLD` is the full amount, the fee is taken **before** de-dusting,
`amountReceivedLD = removeDust(amount - fee)`, and fee + dust accrue to `feeBalance`. The adapter keeps the fee locked
alongside the backing; the OFT moves fee tokens to itself (they stay in `totalSupply` and stay backed). Front-ends must set
`minAmountLD` from `quoteOFT`, otherwise `SlippageExceeded` fires. Fees are charged on the source chain of each hop, so a
round trip pays the adapter fee going out and the OFT fee coming back.

```bash
FEE_BPS=100 npx hardhat run scripts/setFee.ts --network bsc                 # 1% on BSC -> Robinhood
FEE_BPS=50 DST_EID=30102 npx hardhat run scripts/setFee.ts --network robinhood  # 0.5% override Robinhood -> BSC
TO=0xTreasury npx hardhat run scripts/withdrawFees.ts --network bsc
```

## LayerZero endpoints (from the LayerZero metadata API)

| Network           | Chain id | EID   | EndpointV2                                   |
| ----------------- | -------- | ----- | -------------------------------------------- |
| BSC mainnet       | 56       | 30102 | `0x1a44076050125825900e736c501f859c50fE728c` |
| Robinhood mainnet | 4663     | 30416 | `0x6F475642a6e85809B1c36Fa62763669b1b48DD5B` |
| BSC testnet       | 97       | 40102 | `0x6EDCE65403992e310A62460808c4b910D972f10f` |
| Robinhood testnet | 46630    | 40451 | `0x3aCAAf60502791D199a5a5F0B173D78229eBFe32` |

The endpoint addresses are resolved automatically by `@layerzerolabs/toolbox-hardhat` from the `eid` set on each network in
`hardhat.config.ts`; nothing has to be hardcoded.

**The on-chain default DVN for BSC↔Robinhood is `LZDeadDVN` on both sides**: LayerZero provides no default security stack for
this pathway, so `lz:oapp:wire` with explicit DVNs is mandatory. DVNs available on **both** chains include LayerZero Labs,
Nethermind, Horizen, BitGo, Paxos, Luganodes, P2P, Canary, Superform, Frax, Nansen. `layerzero.config.ts` requires
`LayerZero Labs` + `Nethermind`, confirmations `[20, 5]` (on-chain defaults), enforced `lzReceive` gas 120k / 150k
(profiled in `test/foundry/PultBridgeGas.t.sol`). See [AUDIT.md](AUDIT.md) for the trust model and review notes.

## Setup

```bash
pnpm install
cp .env.example .env   # set MNEMONIC or PRIVATE_KEY, RPC URLs, BSCSCAN_API_KEY
```

Requires Node >= 18 and [Foundry](https://book.getfoundry.sh/) for the Solidity tests.

## Test

```bash
pnpm test              # forge test + hardhat test
pnpm test:forge        # test/foundry/PultBridge*.t.sol (TestHelperOz5: real ULN, DVN and executor flow + gas profile)
pnpm test:hardhat      # test/hardhat/PultBridge.test.ts (EndpointV2Mock)
```

Covered: token copy metadata and `claimERC20`, adapter/OFT constructor and peers, BSC → Robinhood lock+mint,
Robinhood → BSC burn+unlock, full round trip, `permit` + send, dust removal, `SlippageExceeded`, missing allowance,
unknown peer, compose message delivery, fuzzed supply invariant; fee configuration (default / per-eid / bounds / onlyOwner),
fee on both directions, `quoteOFT`, fee + slippage, `withdrawFees`, fuzzed backing invariant with fees; `lzReceive` gas profile.

## Deploy

```bash
# 1. Deploy (interactive: pick networks, then tags)
npx hardhat lz:deploy
#    bsc        -> tag PultOFTAdapter   (uses PULT_TOKEN_BSC from hardhat.config.ts)
#    robinhood  -> tag PultOFT
# Non-interactive:
npx hardhat lz:deploy --networks bsc --tags PultOFTAdapter --ci
npx hardhat lz:deploy --networks robinhood --tags PultOFT --ci

# 2. Wire peers, DVNs, confirmations and enforced options on both sides
npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts

# 3. Verify
npx hardhat lz:oapp:peers:get --oapp-config layerzero.config.ts
npx hardhat lz:oapp:config:get --oapp-config layerzero.config.ts
npx hardhat lz:oapp:enforced-opts:get --oapp-config layerzero.config.ts
```

The deploy scripts guard themselves: `PultOFTAdapter` only deploys on a network with an `oftAdapter.tokenAddress`
(the home chain), `PultOFT` only on networks without one, and `CatapultTrade` is skipped wherever a token address is configured.

Before wiring mainnet compare the chosen confirmations with LayerZero defaults:

```bash
npx hardhat lz:oapp:config:get:default --oapp-config layerzero.config.ts
```

### Testnet (BSC testnet ↔ Robinhood testnet)

```bash
npx hardhat lz:deploy --networks bsc-testnet --tags PultOFTAdapter --ci   # also deploys CatapultTrade (dependency)
npx hardhat lz:deploy --networks robinhood-testnet --tags PultOFT --ci
npx hardhat lz:oapp:wire --oapp-config layerzero.testnet.config.ts
```

### Verify source

Uses `@nomicfoundation/hardhat-verify` (`BSCSCAN_API_KEY` for BSC, Blockscout for Robinhood, no key needed).

```bash
npx hardhat verify --network bsc <adapter> 0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154 0x1a44076050125825900e736c501f859c50fE728c <owner>
npx hardhat verify --network robinhood <oft> "Catapult Trade" PULT 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B <owner>
```

Robinhood Chain uses Blockscout (`https://robinhoodchain.blockscout.com`); the custom chain is preconfigured in `hardhat.config.ts`.

## Bridging

Users on BSC `approve(adapter, amount)` (or `permit`) then call `adapter.send(SendParam, MessagingFee, refundAddress)` with the
quoted native fee from `quoteSend`. On Robinhood `PultOFT.send` burns and needs no approval. Amounts are rounded down to
`1e12` wei; set `minAmountLD` accordingly.

## Scripts

```bash
# deployer address + native balance on a network (reads PRIVATE_KEY / MAINNET_PRIVATE_KEY; DOTENV_CONFIG_PATH may point to another .env)
npx hardhat run scripts/whoami.ts --network bsc
# send tokens across (AMOUNT in whole tokens, TO defaults to the signer)
AMOUNT=1 npx hardhat run scripts/sendTest.ts --network bsc          # BSC -> Robinhood
AMOUNT=0.5 npx hardhat run scripts/sendTest.ts --network robinhood  # Robinhood -> BSC
```

## Layout

```
contracts/            CatapultTrade.sol, PultOFTAdapter.sol, PultOFT.sol
deploy/               CatapultTrade.ts, PultOFTAdapter.ts, PultOFT.ts (hardhat-deploy, run via lz:deploy)
test/foundry/         PultBridge.t.sol, PultBridgeFee.t.sol, PultBridgeGas.t.sol
test/hardhat/         PultBridge.test.ts
test/mocks/           PultOFTMock.sol, PultOFTAdapterMock.sol, OFTComposerMock.sol
scripts/              whoami.ts, sendTest.ts, setFee.ts, withdrawFees.ts
deployments/          hardhat-deploy artifacts per network (created by lz:deploy, committed for wiring)
AUDIT.md              scope, trust model, internal review findings, pre-deploy checklist
layerzero.config.ts   mainnet mesh (BSC <-> Robinhood)
layerzero.testnet.config.ts
```
