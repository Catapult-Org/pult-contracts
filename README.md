# pult-contracts

PULT token and its LayerZero V2 omnichain bridge.

| Chain                                          | Contract                                         | Role                                                                                                                                        |
| ---------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| BSC (eid `30102`)                              | [`CatapultTrade`](contracts/CatapultTrade.sol)   | Existing PULT ERC20: [`0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154`](https://bscscan.com/address/0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154) |
| BSC (eid `30102`)                              | [`PultOFTAdapter`](contracts/PultOFTAdapter.sol) | LayerZero **OFTAdapter** with optional fee: locks / unlocks PULT                                                                            |
| Robinhood Chain (eid `30416`, chain id `4663`) | [`PultOFT`](contracts/PultOFT.sol)               | LayerZero **OFT** with optional fee: mints / burns PULT                                                                                     |
| Arbitrum One (eid `30110`, chain id `42161`)   | [`PultOFT`](contracts/PultOFT.sol)               | LayerZero **OFT** with optional fee: mints / burns PULT (same contract as Robinhood)                                                        |

Full mesh: every pair of chains is wired directly. Robinhood ↔ Arbitrum burns on one side and mints on the other without
touching BSC. BSC stays the only chain holding real PULT; there is exactly one adapter.

Built on the official LayerZero `create-lz-oapp` stack: Hardhat 2 + `hardhat-deploy` + `@layerzerolabs/toolbox-hardhat` for
deploy/wiring, Foundry + `TestHelperOz5` for tests.

## Contracts

- `contracts/CatapultTrade.sol` — verbatim source of the verified BSC deployment (OpenZeppelin 5.6.0: `ERC20` + `ERC20Permit` + `Ownable`,
  1 000 000 000 PULT minted to `recipient`, `claimERC20` rescue). Compiled with the same settings as on-chain
  (solc 0.8.34, evmVersion `osaka`, optimizer off) via a per-file override in `hardhat.config.ts`; the resulting
  creation code is identical to the BSC deployment tx except for the CBOR metadata hash (different source file name).
  Only deployed on testnets / locally.
- `contracts/PultOFTAdapter.sol` — `OFTAdapter(token, endpoint, delegate)` + `PultFee`. **Exactly one** adapter
  may exist in the mesh. PULT has no transfer fee, so lock/unlock accounting is lossless.
- `contracts/PultOFT.sol` — `OFT("Catapult Trade", "PULT", endpoint, delegate)` + `PultFee`, 18 local / 6 shared
  decimals (`decimalConversionRate = 1e12`, sub-1e12-wei dust is stripped on send). No supply minted at deploy.
- `contracts/PultFee.sol` — LayerZero's `Fee` (same `IFee` ABI and storage) with fees capped at 5 % (`MAX_FEE_BPS = 500`).
- `test/mocks/*` — test-only subclasses exposing `mint` / `removeDust` (not compiled by Hardhat, never deployed).

Invariant: PULT locked in `PultOFTAdapter` == `PultOFT(Robinhood).totalSupply()` + `PultOFT(Arbitrum).totalSupply()` +
`PultOFTAdapter.feeBalance()`.

## Bridge fee

Both contracts carry the fee model of LayerZero's `OFTAdapterFeeUpgradeable` / `OFTFeeUpgradeable`, re-implemented on the
non-upgradeable base (`contracts/PultFee.sol`, LayerZero's `Fee.sol` with a 5 % cap). Fees are **0 by default**, so
behaviour equals the default OFT until the owner sets one. **No fee can exceed 5 %** (`InvalidBps` above 500 bps).
`withdrawFees` rejects address(0) and the contract itself (`InvalidRecipient`).

| Call (owner only)                                | Effect                                                                |
| ------------------------------------------------ | --------------------------------------------------------------------- |
| `setDefaultFeeBps(bps)`                          | fee for every destination, in basis points (100 = 1%, max 500 = 5%)   |
| `setFeeBps(dstEid, bps, enabled)`                | per-destination override; `enabled=false` falls back to the default   |
| `withdrawFees(to)`                               | pays out `feeBalance` (adapter: PULT on BSC; OFT: PULT on that chain) |
| `getFee(dstEid, amount)` / `quoteOFT(sendParam)` | read the fee / the exact `amountReceivedLD` for a send                |

Mechanics: on `send`, `amountSentLD` is the full amount, the fee is taken **before** de-dusting,
`amountReceivedLD = removeDust(amount - fee)`, and fee + dust accrue to `feeBalance`. The adapter keeps the fee locked
alongside the backing; the OFT moves fee tokens to itself (they stay in `totalSupply` and stay backed). Front-ends must set
`minAmountLD` from `quoteOFT`, otherwise `SlippageExceeded` fires. Fees are charged on the source chain of each hop, so a
round trip pays the adapter fee going out and the OFT fee coming back.

```bash
FEE_BPS=100 npx hardhat run scripts/setFee.ts --network bsc                 # 1% on BSC -> Robinhood
FEE_BPS=50 DST_EID=30102 npx hardhat run scripts/setFee.ts --network robinhood  # 0.5% override Robinhood -> BSC
FEE_BPS=30 DST_EID=30110 npx hardhat run scripts/setFee.ts --network bsc        # 0.3% override BSC -> Arbitrum
TO=0xTreasury npx hardhat run scripts/withdrawFees.ts --network bsc
```

## LayerZero endpoints (from the LayerZero metadata API)

| Network           | Chain id | EID   | EndpointV2                                   |
| ----------------- | -------- | ----- | -------------------------------------------- |
| BSC mainnet       | 56       | 30102 | `0x1a44076050125825900e736c501f859c50fE728c` |
| Robinhood mainnet | 4663     | 30416 | `0x6F475642a6e85809B1c36Fa62763669b1b48DD5B` |
| Arbitrum One      | 42161    | 30110 | `0x1a44076050125825900e736c501f859c50fE728c` |
| BSC testnet       | 97       | 40102 | `0x6EDCE65403992e310A62460808c4b910D972f10f` |
| Robinhood testnet | 46630    | 40451 | `0x3aCAAf60502791D199a5a5F0B173D78229eBFe32` |
| Arbitrum Sepolia  | 421614   | 40231 | `0x6EDCE65403992e310A62460808c4b910D972f10f` |

The endpoint addresses are resolved automatically by `@layerzerolabs/toolbox-hardhat` from the `eid` set on each network in
`hardhat.config.ts`; nothing has to be hardcoded.

**The on-chain default DVN of both Robinhood pathways (BSC↔Robinhood, Arbitrum↔Robinhood) is `LZDeadDVN`**: LayerZero
provides no default security stack for them, so `lz:oapp:wire` with explicit DVNs is mandatory. DVNs available as
messaging DVNs on **all three** chains (metadata API, 2026-10-26): LayerZero Labs, Horizen, Luganodes, P2P, Canary,
Superform, Frax, Nansen, Deutsche Telekom, Twinstake, ApeDVN. `Nethermind` is **not** usable: on BSC and Arbitrum it is
only listed as an lzRead DVN, so name resolution fails. `layerzero.config.ts` requires `LayerZero Labs` + `Horizen` on
every pathway; confirmations are the on-chain defaults (BSC → 20, Arbitrum → 20, Robinhood → 5); enforced `lzReceive` gas
200k / 250k (profiled in `test/foundry/PultBridgeGas.t.sol`, ≥ 25 % headroom). See [AUDIT.md](AUDIT.md) for the trust model and review notes.

## Setup

```bash
pnpm install
cp .env.example .env   # set MNEMONIC or PRIVATE_KEY, RPC URLs, ETHERSCAN_API_KEY
```

Use pnpm 9/10 (`npx pnpm@10 install`): pnpm 11 ignores the `pnpm.overrides` field and rejects the frozen lockfile.
Requires Node >= 18 and [Foundry](https://book.getfoundry.sh/) for the Solidity tests.

## Test

```bash
pnpm test              # forge test + hardhat test
pnpm test:forge        # test/foundry/PultBridge*.t.sol (TestHelperOz5: real ULN, DVN and executor flow + gas profile + 3-chain mesh)
pnpm test:hardhat      # test/hardhat/PultBridge.test.ts (EndpointV2Mock)
```

Covered: token copy metadata and `claimERC20`, adapter/OFT constructor and peers, BSC → Robinhood lock+mint,
Robinhood → BSC burn+unlock, full round trip, `permit` + send, dust removal, `SlippageExceeded`, missing allowance,
unknown peer, compose message delivery, fuzzed supply invariant; fee configuration (default / per-eid / bounds / onlyOwner),
fee on both directions, `quoteOFT`, fee + slippage, `withdrawFees`, fuzzed backing invariant with fees, 5 % fee cap;
`lzReceive` gas profile; three-chain mesh (all 6 directions, sub-dust amounts, max fee + dust, fees after many transfers,
fuzzed random walk with backing / custody / conservation invariants).

Foundry: `curl -L https://foundry.paradigm.xyz | bash && foundryup`.

## Deploy

```bash
# 1. Deploy (interactive: pick networks, then tags)
npx hardhat lz:deploy
#    bsc        -> tag PultOFTAdapter   (wraps the existing token, PULT_TOKEN_BSC in hardhat.config.ts)
#    robinhood  -> tag PultOFT
#    arbitrum   -> tag PultOFT
# Non-interactive:
npx hardhat lz:deploy --networks bsc --tags PultOFTAdapter --ci
npx hardhat lz:deploy --networks robinhood,arbitrum --tags PultOFT --ci

# 2. Wire peers, DVNs, confirmations and enforced options on all three chains (6 directions).
#    Signs transactions on every chain: the deployer (= owner/delegate) needs native gas on BSC, Robinhood and Arbitrum.
npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts

# 3. Check the live config: fails on a missing or undeclared peer, a dead/default DVN, wrong confirmations or enforced
#    gas, or owner != delegate
npx hardhat run scripts/checkConfig.ts      # LZ_CONFIG=layerzero.testnet.config.ts for testnet

# 4. End-to-end on the live mesh (TEST_PRIVATE_KEY wallet: gas on all chains + >= 7 x E2E_AMOUNT PULT on BSC).
#    The script switches fees on and off with the owner key, so production needs an explicit opt-in; fees are reset
#    in a `finally` even if the run aborts.
E2E_ALLOW_PRODUCTION=1 E2E_AMOUNT=1 npx hardhat run scripts/e2e.ts
```

Do not announce the adapter address before step 3 passes: until wiring, the Robinhood pathways verify through
LayerZero's dead DVN and a transfer would never be delivered.

### Staging mesh on mainnet

`DEPLOY_STAGE=staging` deploys a separate, throwaway mesh on the real chains (own adapter over the real PULT, own PultOFTs
named "PULT Staging" / "PULT-STG"), recorded in `deployments-staging/` instead of `deployments/`. Same wiring config as
production. Used for the live end-to-end run before the production deploy:

```bash
DEPLOY_STAGE=staging npx hardhat lz:deploy --networks bsc --tags PultOFTAdapter --ci
DEPLOY_STAGE=staging npx hardhat lz:deploy --networks robinhood,arbitrum --tags PultOFT --ci
DEPLOY_STAGE=staging npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts --ci
DEPLOY_STAGE=staging npx hardhat run scripts/checkConfig.ts
DEPLOY_STAGE=staging E2E_AMOUNT=100 npx hardhat run scripts/e2e.ts   # = pnpm e2e (pnpm 9/10)
```

The current staging mesh and the retired first one are listed in [AUDIT.md](AUDIT.md) §0.2. A retired staging mesh is
emptied and unpeered (`setPeer(eid, 0)` in every direction) so it cannot carry messages; its artifacts stay in
`deployments-staging-v1/`.

The deploy scripts guard themselves: `PultOFTAdapter` only deploys on a network with an `oftAdapter.tokenAddress`
(the home chain), `PultOFT` only on networks without one, and `CatapultTrade` is skipped wherever a token address is configured.

Before wiring mainnet compare the chosen confirmations with LayerZero defaults:

```bash
npx hardhat lz:oapp:config:get:default --oapp-config layerzero.config.ts
```

### Testnet (BSC testnet ↔ Robinhood testnet ↔ Arbitrum Sepolia)

```bash
npx hardhat lz:deploy --networks bsc-testnet --tags PultOFTAdapter --ci   # also deploys CatapultTrade (dependency)
npx hardhat lz:deploy --networks robinhood-testnet,arbitrum-sepolia --tags PultOFT --ci
npx hardhat lz:oapp:wire --oapp-config layerzero.testnet.config.ts
AMOUNT=1 DST=arbitrum-sepolia npx hardhat run scripts/sendTest.ts --network bsc-testnet
```

### Verify source

Uses `@nomicfoundation/hardhat-verify`: one Etherscan v2 key (`ETHERSCAN_API_KEY`) for BSC and Arbitrum, Blockscout
for Robinhood (no key). `hardhat.config.ts` enables exactly one verifier based on `--network`.

```bash
npx hardhat verify --network bsc <adapter> 0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154 0x1a44076050125825900e736c501f859c50fE728c <owner>
npx hardhat verify --network robinhood <oft> "Catapult Trade" PULT 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B <owner>
npx hardhat verify --network arbitrum <oft> "Catapult Trade" PULT 0x1a44076050125825900e736c501f859c50fE728c <owner>
```

Robinhood Chain uses Blockscout (`https://robinhoodchain.blockscout.com`); the custom chain is preconfigured in `hardhat.config.ts`.

## Bridging

Users on BSC `approve(adapter, amount)` (or `permit`) then call `adapter.send(SendParam, MessagingFee, refundAddress)` with the
quoted native fee from `quoteSend`. On Robinhood and Arbitrum `PultOFT.send` burns and needs no approval. Amounts are
rounded down to `1e12` wei; set `minAmountLD` from `quoteOFT` (covers fee and dust). `quoteOFT` also returns the fee in
`oftFeeDetails`.

Rejected on the source chain (quote and send revert, nothing moves): recipient `bytes32(0)` or the destination bridge
contract (`InvalidRecipient`), and amounts that would deliver 0 after fee and dust (`AmountTooSmall`, e.g. < 1e12 wei).

## Scripts

```bash
# deployer address + native balance on a network (reads PRIVATE_KEY / MAINNET_PRIVATE_KEY; DOTENV_CONFIG_PATH may point to another .env)
npx hardhat run scripts/whoami.ts --network bsc
# send tokens across (AMOUNT in whole tokens, DST = destination network name, TO defaults to the signer)
AMOUNT=1 npx hardhat run scripts/sendTest.ts --network bsc                      # BSC -> Robinhood (default DST)
AMOUNT=1 DST=arbitrum npx hardhat run scripts/sendTest.ts --network bsc         # BSC -> Arbitrum
AMOUNT=0.5 DST=arbitrum npx hardhat run scripts/sendTest.ts --network robinhood # Robinhood -> Arbitrum
AMOUNT=0.5 npx hardhat run scripts/sendTest.ts --network arbitrum               # Arbitrum -> BSC (default DST)
```

## Layout

```
contracts/            CatapultTrade.sol, PultOFTAdapter.sol, PultOFT.sol, PultFee.sol
deploy/               CatapultTrade.ts, PultOFTAdapter.ts, PultOFT.ts (hardhat-deploy, run via lz:deploy)
test/foundry/         PultBridge.t.sol, PultBridgeFee.t.sol, PultBridgeGas.t.sol, PultBridgeMesh.t.sol,
                      PultBridgeHardening.t.sol
test/hardhat/         PultBridge.test.ts
test/mocks/           PultOFTMock.sol, PultOFTAdapterMock.sol, OFTComposerMock.sol
scripts/              whoami.ts, sendTest.ts, setFee.ts, withdrawFees.ts, checkConfig.ts, e2e.ts
deployments/          hardhat-deploy artifacts per network (created by lz:deploy, committed for wiring)
deployments-staging/  the current staging mesh on mainnet (DEPLOY_STAGE=staging)
deployments-staging-v1/ the retired first staging mesh (emptied, unpeered)
AUDIT.md              scope, trust model, internal review findings, pre-deploy checklist
layerzero.config.ts   mainnet mesh (BSC <-> Robinhood <-> Arbitrum)
layerzero.testnet.config.ts
```
