# PULT omnichain bridge — audit scope & internal review

Date: 2026-09-21 (fee support added the same day; Arbitrum One added to the mesh 2026-10-26, see 4.7–4.8). Reviewer:
internal (pre-audit). Status: **ready for external audit** with the notes below. No contract code changed for Arbitrum:
it runs the same `PultOFT` as Robinhood; only deployment and wiring configuration grew.

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

- Owner may set a fee of up to 100 % (`BPS_DENOMINATOR`), which would make sends deliver 0. This matches the LayerZero
  reference; a lower hard cap (e.g. 10 %) is an easy hardening if the team wants it.
- `unchecked { amountReceivedLD = _removeDust(_amountLD - fee) }` is safe because `fee <= _amountLD` (bps ≤ 10 000).
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
6. **Pre-deploy checklist**: `pnpm test` green → full testnet run (BSC testnet, Robinhood testnet, Arbitrum Sepolia) →
   `lz:deploy` on `bsc` + `robinhood` + `arbitrum` → `lz:oapp:wire` → `lz:oapp:peers:get` shows 6 peers and
   `lz:oapp:config:get` shows LayerZero Labs + Horizen in all 6 directions → small amount over every direction → transfer
   ownership of all three OApps.

## 6. Test coverage

- `test/foundry/PultBridge.t.sol` (14): token metadata + `claimERC20`; constructor/peers/decimals; lock+mint; burn+unlock; full
  round trip; `permit` + send; dust removal; `SlippageExceeded`; missing allowance; unknown peer (`NoPeer`); compose delivery;
  `onlyOwner` on `setPeer`; fuzzed supply invariant.
- `test/foundry/PultBridgeFee.t.sol` (13): fee defaults, `setDefaultFeeBps` / `setFeeBps` bounds and override semantics,
  onlyOwner on all fee functions, fee on BSC→Robinhood and Robinhood→BSC, `quoteOFT`/`quoteSend` with fee, fee + slippage,
  zero-fee equivalence, `withdrawFees` on both sides (incl. re-bridging withdrawn OFT fees), fuzzed backing invariant.
- `test/foundry/PultBridgeGas.t.sol` (5): `lzReceive` gas per path with headroom assertions tied to `layerzero.config.ts`.
- `test/hardhat/PultBridge.test.ts` (11): same core flows plus fee + withdraw against `EndpointV2Mock`, with a three-chain
  mesh: BSC → Arbitrum, Robinhood ↔ Arbitrum direct (adapter balance unchanged), Arbitrum → BSC, per-destination fee,
  backing invariant over both OFT supplies. The Foundry suites still cover BSC ↔ Robinhood only (identical contract on
  Arbitrum).
