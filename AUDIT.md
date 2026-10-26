# PULT omnichain bridge — audit scope & internal review

Date: 2026-09-21 (fee support added the same day; Arbitrum One added to the mesh 2026-10-26, see 4.7–4.8; fee cap,
gas limits and live staging run 2026-10-27, see §0 and 4.9–4.10). Reviewer: internal (pre-audit). Status: **ready for
external audit** with the notes below. Arbitrum runs the same `PultOFT` as Robinhood.

## 0. Response to the external auditor's pre-review (2026-10-27)

| #   | Point raised                                                           | Status                                                                                                                                                                                                                                          | Evidence                                                                                                                                                                                                                                |
| --- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Default DVN on BSC ↔ Robinhood is a dead DVN; messages could get stuck | **Confirmed and closed by configuration.** Every pathway is wired with 2 explicit required DVNs (LayerZero Labs + Horizen) and explicit confirmations; `scripts/checkConfig.ts` reads the effective on-chain config and fails on any difference | §0.1 below: live check before wiring (dead DVN on Robinhood pathways) and after wiring (48/48 ok)                                                                                                                                       |
| 2   | Owner can set fees up to 100 %                                         | **Fixed in code.** New `contracts/PultFee.sol` caps every fee at `MAX_FEE_BPS = 500` (5 %), on the default and per-destination setters, also for disabled overrides                                                                             | `PultBridgeFee.t.sol`: `test_fee_cap_is_5_percent_on_both_contracts`, `testFuzz_fee_setters_never_store_more_than_cap`; Hardhat `caps every fee at 5 %`; live run §0.2                                                                  |
| 3   | Lock/mint backing invariant                                            | **Holds; no bug found.** Fees are taken before the message is built, so only `amountReceivedLD` is ever minted/unlocked                                                                                                                         | `PultBridgeMesh.t.sol`: `testFuzz_random_mesh_walk_preserves_invariants` (12 random hops over all 6 directions, random fees ≤ 5 %, 3 invariants after every hop; 10 000 runs green); live run §0.2 checks it on chain after every stage |
| 4   | Dust, fee rounding, `feeBalance`, `withdrawFees`                       | **Correct; covered by tests.** Fee rounds down, dust (< 1e12 wei) accrues to `feeBalance`, `withdrawFees` can move only `feeBalance`                                                                                                            | `PultBridgeMesh.t.sol`: `test_amount_below_dust_goes_entirely_to_fee_balance`, `test_max_fee_with_dust_exact_accounting`, `test_withdrawFees_after_many_transfers_keeps_backing`; live run §0.2                                         |

Found while answering point 3: the enforced `lzReceive` gas (120k / 150k) left only ~3 % headroom on the first message
(4.9). Raised to 200k / 250k.

### 0.1 DVN configuration, verified on chain

`LZ_CONFIG=layerzero.config.ts npx hardhat run scripts/checkConfig.ts` compares, for each of the 6 directions: peer, send
library, executor, send ULN config, enforced options, receive library, receive ULN config, plus owner == endpoint delegate.
ULN configs are read through `EndpointV2.getConfig`, i.e. the effective config (OApp settings merged with LayerZero defaults).

Result on the staging mesh (§0.2), 2026-10-27:

- **Before** `lz:oapp:wire`: every check failed. BSC → Robinhood, Robinhood → BSC, Robinhood → Arbitrum and the receive
  side for BSC → Robinhood used a single required DVN `0x6788…E842` (`LZDeadDVN`) or a placeholder default; no peers, no
  enforced gas. A transfer at that point would never be delivered.
- **After** `lz:oapp:wire` (27 transactions): **48/48 checks ok.** All 6 directions: 2 required DVNs (LayerZero Labs +
  Horizen), 0 optional, confirmations BSC 20 / Arbitrum 20 / Robinhood 5, enforced `lzReceive` gas 200k / 250k, peers
  set, delegate == owner.

### 0.2 Live end-to-end run on mainnet (staging mesh)

A separate mesh with the audited code was deployed on the real chains (`DEPLOY_STAGE=staging`, `deployments-staging/`):

| Chain     | Contract                                | Address                                      |
| --------- | --------------------------------------- | -------------------------------------------- |
| BSC       | `PultOFTAdapter` over the real PULT     | `0xFb66e0167c9C97b01FE3b5F453198e7B6252CDb5` |
| Robinhood | `PultOFT` ("PULT Staging" / "PULT-STG") | `0x14522Cb95a0B7D99E03F5e680C2f866623d61Ae9` |
| Arbitrum  | `PultOFT` ("PULT Staging" / "PULT-STG") | `0x8B059687246d6570306AB86E6c6F68130f760C69` |

`scripts/e2e.ts` with a separate user wallet, real DVNs and executors, every delivery matched by GUID (`OFTSent` →
`OFTReceived`) and checked for the exact amount. Final run (2026-10-27 21:01–21:05 UTC, unit 20 PULT), all passed:

1. BSC → Robinhood 60, BSC → Arbitrum 60, Robinhood → Arbitrum 20, Arbitrum → Robinhood 10: delivered in 11–45 s,
   received == sent; OFT ↔ OFT left the BSC lockbox unchanged.
2. `setDefaultFeeBps(501)` and `setFeeBps(.., 501)` revert on all three contracts. 5 % on Arbitrum → Robinhood:
   20 sent, exactly 19.0 received, `feeBalance` +1.0. 1 % on BSC → Arbitrum with a dusty amount: 20.000000000123456789
   sent, exactly 19.8 received, adapter `feeBalance` +0.200000000123456789 (fee + dust).
3. `withdrawFees` on all contracts → `feeBalance` 0; the adapter then held exactly the remote supply (143.55 =
   69.0 + 74.55).
4. Everything bridged back to BSC: lockbox 0, both OFT supplies 0. User lost exactly the fees (1.200000000123456789).

The backing invariant (locked == supply(Robinhood) + supply(Arbitrum) + adapter.feeBalance) and OFT fee custody were
checked on chain after every stage. Earlier interrupted runs failed only in the test harness (balance-diff delivery
detection, ethers' 1.5 gwei default priority fee draining the test wallet, public RPC rate limits); every message they
sent was delivered and accounted for.

## 1. Scope

| File                                                                                     | LOC  | Notes                                                                                                                       |
| ---------------------------------------------------------------------------------------- | ---- | --------------------------------------------------------------------------------------------------------------------------- |
| `contracts/PultOFTAdapter.sol`                                                           | ~100 | `OFTAdapter` + `Fee` from `@layerzerolabs/oft-evm@4.0.1`; overrides `_debitView`/`_debit`, adds `feeBalance`/`withdrawFees` |
| `contracts/PultOFT.sol`                                                                  | ~95  | `OFT` + `Fee` from `@layerzerolabs/oft-evm@4.0.1`; overrides `_debitView`/`_debit`, adds `feeBalance`/`withdrawFees`        |
| `contracts/CatapultTrade.sol`                                                            | 33   | verbatim copy of the live BSC token `0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154`; **already deployed, informational only**  |
| `deploy/*.ts`, `hardhat.config.ts`, `layerzero.config.ts`, `layerzero.testnet.config.ts` | —    | deployment + LayerZero wiring configuration (peers, DVNs, confirmations, enforced options)                                  |

Out of scope (third-party, separately audited): `@layerzerolabs/oft-evm`, `@layerzerolabs/oapp-evm`, `@layerzerolabs/lz-evm-protocol-v2`,
`@layerzerolabs/lz-evm-messagelib-v2`, `@openzeppelin/contracts@5.6.0`. Exact versions are pinned in `pnpm-lock.yaml`.

Test-only code (not deployed): `test/mocks/*` (`mint()` without access control is intentional there).

## 2. System description

- BSC (eid 30102) is the **home chain**. `PultOFTAdapter` locks PULT via `safeTransferFrom` on send and `safeTransfer`s it back on receive.
- Robinhood Chain (eid 30416) and Arbitrum One (eid 30110) each hold a `PultOFT`, a mint/burn ERC20 with the same
  name/symbol/decimals. The mesh is fully connected: Robinhood ↔ Arbitrum transfers burn on one chain and mint on the
  other without touching BSC. The sum of both supplies equals PULT locked in the adapter (net of `feeBalance`) at all times
  (two-chain fuzz: `testFuzz_bridge_preserves_supply_invariant`; three-chain: `test/hardhat/PultBridge.test.ts`).
- Amounts travel as `uint64` in 6 shared decimals; local 18 decimals → `decimalConversionRate = 1e12`.
- **Fee (added 2026-09-21 on request).** The fee logic is a line-by-line port of LayerZero's `OFTAdapterFeeUpgradeable` /
  `OFTFeeUpgradeable` (devtools `packages/oft-evm-upgradeable`) onto the non-upgradeable base: `amountSentLD = amount`,
  `amountReceivedLD = removeDust(amount - amount * bps / 10_000)`, fee + dust accrue to `feeBalance`; owner-only
  `setDefaultFeeBps`, `setFeeBps(dstEid, bps, enabled)`, `withdrawFees(to)`. Adapter fees stay locked next to the backing
  (`withdrawFees` can only move `feeBalance`); OFT fees are moved to the OFT contract itself and remain part of `totalSupply`.
  Default fee is 0, in which case behaviour equals the default OFT except that dust now accrues to `feeBalance` instead of
  staying with the sender. Invariant: `token.balanceOf(adapter) == PultOFT.totalSupply() + adapter.feeBalance()`.
- Message security: 2 required DVNs (LayerZero Labs, Horizen) on all six directions, no optional DVNs. Confirmations are
  the on-chain LayerZero defaults of the sending chain: BSC 20, Arbitrum 20, Robinhood 5. Enforced executor gas: 120k
  (`SEND`), 150k (`SEND_AND_CALL`).

## 3. Trust model / privileged roles

| Role                                       | Where     | Powers                                                                                                                                                                                                                                                                                    |
| ------------------------------------------ | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `owner` (= `delegate`) of `PultOFTAdapter` | BSC       | `setPeer`, `setDelegate`, `setEnforcedOptions`, `setMsgInspector`, `setPreCrime`, endpoint config via delegate (`setConfig`, `setSendLibrary`, `setReceiveLibrary`, `skip/nilify/burn` nonces); **fees**: `setDefaultFeeBps` / `setFeeBps` up to 100 %, `withdrawFees` (fee balance only) |
| `owner` (= `delegate`) of `PultOFT`        | Robinhood | same as above                                                                                                                                                                                                                                                                             |
| `owner` (= `delegate`) of `PultOFT`        | Arbitrum  | same as above                                                                                                                                                                                                                                                                             |
| DVNs (LayerZero Labs, Horizen)             | all       | must both attest to a packet before it is executable                                                                                                                                                                                                                                      |
| Executor (LayerZero)                       | all       | liveness only; anyone can execute a verified packet permissionlessly                                                                                                                                                                                                                      |
| `owner` of `CatapultTrade`                 | BSC       | `claimERC20` (rescue tokens held by the token contract itself). Cannot mint, pause or freeze PULT                                                                                                                                                                                         |

A malicious or compromised OApp owner on **any** of the three chains can re-point `setPeer` to an attacker contract and mint
unbacked PultOFT / drain the adapter. A third chain adds a third owner key to protect. This is inherent to every OFT
deployment and is the primary operational risk. See 5.1.

## 4. Internal findings

The only custom Solidity is the fee port described in §2 (verified against the LayerZero reference and covered by
`test/foundry/PultBridgeFee.t.sol`). Points for the auditors on that code:

- Fees are capped at 5 % (`PultFee.MAX_FEE_BPS = 500`, see 4.10). `PultFee` keeps the ABI, storage layout, events and
  errors of LayerZero's `Fee.sol`; only the bound in the two setters changed (10 000 → 500).
- `unchecked { amountReceivedLD = _removeDust(_amountLD - fee) }` is safe because `fee <= _amountLD` (bps ≤ 500).
- `PultOFT._debit` transfers the fee to `address(this)` before burning; `withdrawFees` uses `_transfer(address(this), to)`,
  so the OFT never mints or burns fee tokens and the remote backing stays intact.
- Fee is applied before de-dust, so the dust remainder also accrues to `feeBalance` (LayerZero semantics).

Remaining findings concern configuration and operations.

### 4.1 [Medium → fixed] Default DVN on the BSC↔Robinhood pathway is `LZDeadDVN`

`SendUln302.getUlnConfig(address(0), 30416)` on BSC and `getUlnConfig(address(0), 30102)` on Robinhood both return
`LZDeadDVN` as the single required DVN. LayerZero ships **no default security stack** for this pathway; any deployment that relies
on defaults never delivers a message. `layerzero.config.ts` sets explicit DVNs, and `lz:oapp:wire` must be run on both chains
before opening the bridge. Verification: `npx hardhat lz:oapp:config:get --oapp-config layerzero.config.ts` must show no dead DVN.

### 4.2 [Low → fixed] Confirmations were symmetric `[20, 20]`

On-chain defaults are 20 (BSC→Robinhood) and 5 (Robinhood→BSC). Robinhood blocks are slow when the chain is idle, so 20
confirmations there would add long delays without a security benefit. Config now `[20, 5]`.

### 4.3 [Low → fixed] Enforced `lzReceive` gas of 80k from the LayerZero example was too tight

Profiled against the real endpoint (`test/foundry/PultBridgeGas.t.sol`): first message on a pathway to a fresh recipient
costs 79,140 gas (mint) / 58,098 (unlock); with compose 107,940 / 86,898. Under-provisioned messages get stuck until someone
re-executes them manually. Raised to 120k / 150k (≥25% headroom, asserted by tests).

### 4.4 [Info → fixed] Test mocks lived under `contracts/`

`PultOFTMock` with a public `mint()` was compiled into deployable Hardhat artifacts. Moved to `test/mocks/` (Foundry-only).

### 4.5 [Info → fixed] Floating pragma on production contracts

`^0.8.22` → `0.8.30` for `PultOFT` / `PultOFTAdapter`. `CatapultTrade` keeps `^0.8.27` to stay verbatim with the verified source.

### 4.7 [Medium → fixed] `Nethermind` DVN no longer resolves; wiring would fail

`generateConnectionsConfig` resolves DVN names through the LayerZero metadata API and skips lzRead DVNs. As of 2026-10-26
`Nethermind` is listed on BSC and Arbitrum only as an lzRead DVN, so `lz:oapp:wire` aborted with
`Can't find DVN: "Nethermind" on chainKey: "bsc"` (fail-closed: nothing could be wired). Replaced by `Horizen`, which is a
messaging DVN on BSC, Arbitrum and Robinhood. Both configs are resolved against the live metadata before deploy.

### 4.8 [Low → fixed] Contract verification used the retired Etherscan v1 API

A per-network `etherscan.apiKey` object makes `hardhat-verify` use each explorer's v1 API; Etherscan shut those down in 2025,
so BSC verification would fail. Now: one `ETHERSCAN_API_KEY` (v2 multichain) for BSC + Arbitrum, Blockscout for Robinhood,
with exactly one verifier enabled for the selected `--network`.

### 4.9 [Medium → fixed] Enforced `lzReceive` gas had ~3 % headroom

`PultBridgeGas.t.sol` had never been run with a current Foundry. With forge 1.8 the first message on a pathway to a fresh
recipient measures 116,624 gas (mint) / 102,882 (unlock), with compose 145,816 / 132,074, against enforced 120k / 150k:
3 % headroom on the first mint, and the test (which requires 25 %) failed. Any small cost increase on a destination would
have stranded the first transfers until manual re-execution. Raised to 200k / 250k (≥ 58 % headroom); the gas test
passes again. Cost of the extra gas: ~0.00002 ETH / 0.00004 BNB per transfer at current prices.

### 4.10 [Medium → fixed] Fee could be set to 100 % (auditor point 2)

LayerZero's `Fee.setDefaultFeeBps` / `setFeeBps` are `external` and not `virtual`, so they cannot be overridden. Replaced by
`contracts/PultFee.sol`: same interface (`IFee`), `MAX_FEE_BPS = 500`, setters revert `InvalidBps` above it. A user always
receives ≥ 95 % of the amount minus < 1e12 wei dust.

### 4.6 [Info] Bytecode of `CatapultTrade` copy

Compiled with the on-chain settings (solc 0.8.34, evm `osaka`, optimizer off, OZ 5.6.0) the creation code equals the BSC deploy
tx except for the CBOR metadata hash (file name differs). Constructor args on chain: recipient `0x561a…25f5`, owner `0x7f40…8b6c`.

Runtime bytecode re-verified 2026-10-26 against `eth_getCode(0x2eae…c154, latest)` on BSC mainnet:

- Local `npx hardhat compile` (per-file override in `hardhat.config.ts`): runtime code is 8,210 bytes on both sides. After
  masking the 7 EIP-712 immutable slots (`immutableReferences`), the first 8,157 bytes are **identical**; the only diff is the
  51-byte CBOR metadata tail (IPFS hash; embedded solc version `0.8.34` matches). Cause: Sourcify stores the file as
  `contract-4b92899db1.sol` with `@openzeppelin/contracts@5.6.0/…` import paths, which changes the metadata hash only.
- [Sourcify](https://sourcify.dev/server/v2/contract/56/0x2eae2fef601c75d4ec24bdadb17fe6e3d910c154): `exact_match` for
  creation and runtime code, verified 2026-07-15. Its `CatapultTrade` source is byte-identical to `contracts/CatapultTrade.sol`,
  and all 26 OpenZeppelin files are byte-identical to `node_modules/@openzeppelin/contracts@5.6.0`.
- Deployer (creation tx `0x2b1edd7e…9749e1042`, block 110,169,430) and current `owner()` are both `0x7f40…8b6c`. The full
  1 B supply was minted to `recipient`, not the owner; owner powers are limited to those in §3.

Keep the `CatapultTrade.sol` override in `hardhat.config.ts`: the project default (0.8.30, optimizer on) does not reproduce
the deployed bytecode.

## 5. Recommendations (not blockers for audit)

1. **Ownership**: after wiring, transfer `owner` and `delegate` of both OApps to a multisig
   (`npx hardhat lz:ownable:transfer-ownership --oapp-config layerzero.config.ts`). The LayerZero `Ownable` is single-step; a
   multisig removes the need for `Ownable2Step`.
2. **Rate limiting**: default OFT has none. With a 1 B supply token, consider LayerZero's `RateLimiter` mixin on both contracts
   to cap outflow per window and bound the blast radius of a DVN/owner compromise. This changes the contracts from "default" and
   would need re-audit.
3. **Executor options for compose**: `SEND_AND_CALL` enforces only `LZ_RECEIVE` gas; the caller must add `LZ_COMPOSE` gas for
   the composer. This mirrors the LayerZero reference and is acceptable.
4. **Tokens sent directly** to the adapter (plain `transfer`, not `send`) are unrecoverable by design.
   Front-end should never expose the adapter address as a deposit address.
5. **Recipient `address(0)`** on Robinhood is redirected to `0xdead` by `OFT._credit`; on BSC `safeTransfer(address(0))`
   reverts and the message stays retryable. Front-end must validate recipients.
6. **Pre-deploy checklist**: `pnpm test` green → staging run on mainnet (`DEPLOY_STAGE=staging`, §0.2) → `lz:deploy` on
   `bsc` + `robinhood` + `arbitrum` → `lz:oapp:wire` → `scripts/checkConfig.ts` passes (no dead DVN, 6 peers, LayerZero Labs +
   Horizen in all 6 directions) → `scripts/e2e.ts` with a small amount → transfer ownership of all three OApps → open the
   bridge. Never announce the adapter address before `checkConfig` passes.

## 6. Test coverage

- `test/foundry/PultBridge.t.sol` (14): token metadata + `claimERC20`; constructor/peers/decimals; lock+mint; burn+unlock; full
  round trip; `permit` + send; dust removal; `SlippageExceeded`; missing allowance; unknown peer (`NoPeer`); compose delivery;
  `onlyOwner` on `setPeer`; fuzzed supply invariant.
- `test/foundry/PultBridgeFee.t.sol` (14): fee defaults, 5 % cap on both contracts (incl. fuzz), `setDefaultFeeBps` /
  `setFeeBps` bounds and override semantics,
  onlyOwner on all fee functions, fee on BSC→Robinhood and Robinhood→BSC, `quoteOFT`/`quoteSend` with fee, fee + slippage,
  zero-fee equivalence, `withdrawFees` on both sides (incl. re-bridging withdrawn OFT fees), fuzzed backing invariant.
- `test/foundry/PultBridgeGas.t.sol` (5): `lzReceive` gas per path with ≥ 25 % headroom assertions tied to
  `layerzero.config.ts` (200k / 250k).
- `test/foundry/PultBridgeMesh.t.sol` (7): the full three-chain mesh with the production contracts and the real ULN: all 6
  directions, OFT ↔ OFT without touching BSC, sub-dust amounts, 5 % fee with dust, `withdrawFees` after 30 transfers with
  mixed fees (adapter then holds exactly the remote supply), and a fuzzed random walk (12 hops, random fees ≤ 5 %) checking
  backing, fee custody and total conservation after every hop.
- `test/hardhat/PultBridge.test.ts` (12): same core flows plus fee + withdraw against `EndpointV2Mock`, three-chain mesh,
  5 % cap.
- Totals: Foundry 40, Hardhat 12, all green; fuzz tests also green at 10 000 runs (`FOUNDRY_FUZZ_RUNS=10000`).
