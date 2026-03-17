<p align="center">
  <img src="https://img.shields.io/badge/Solidity-%5E0.8.26-363636?style=flat-square&logo=solidity" alt="Solidity" />
  <img src="https://img.shields.io/badge/Foundry-Framework-orange?style=flat-square" alt="Foundry" />
  <img src="https://img.shields.io/badge/Uniswap-V4_Hook-FF007A?style=flat-square&logo=uniswap" alt="Uniswap V4" />
  <img src="https://img.shields.io/badge/Unichain-Sepolia-FF007A?style=flat-square" alt="Unichain" />
  <img src="https://img.shields.io/badge/Reactive-Network-00D395?style=flat-square" alt="Reactive Network" />
  <img src="https://img.shields.io/badge/Tests-77_passing-40C057?style=flat-square" alt="Tests" />
</p>

# Dobhooks — Uniswap V4 Hooks for RWA Liquidity

Zero-slippage DEX for tokenized real-world assets, built with Uniswap V4 Custom Accounting Hooks on **Unichain**, with cross-chain oracle automation via **Reactive Network**.

---

## Partner Integrations

### 1. Unichain (by Uniswap Labs)

DobPegHook is a Uniswap V4 Custom Accounting Hook deployed on **Unichain Sepolia (chain 1301)**. It intercepts swaps via `beforeSwap` + `beforeSwapReturnDelta` to settle at exact 1:1 oracle price — zero slippage, no AMM curve, no impermanent loss.

| What | Where in Code |
|------|---------------|
| **DobPegHook** — V4 Custom Accounting Hook | [`contracts/src/DobPegHook.sol`](contracts/src/DobPegHook.sol) |
| **DobSwapRouter** — V4 swap interface | [`contracts/src/DobSwapRouter.sol`](contracts/src/DobSwapRouter.sol) |
| **Unichain deployment script** | [`contracts/script/DeployUnichain.s.sol`](contracts/script/DeployUnichain.s.sol) |
| **UI integration** (chain 1301 config) | [`app/index.html`](app/index.html) — `CHAINS` object, `SUPPORTED_CHAINS`, wallet connection |
| **PoolManager** address | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` (Unichain Sepolia) |

**How it works:**
1. DobPegHook implements `beforeSwap` with `BEFORE_SWAP_RETURNS_DELTA` flag
2. Hook reads oracle price from `DobValidatorRegistry.getPrice(token)`
3. Returns exact delta to settle swap at 1:1 peg — PoolManager's AMM curve is completely bypassed
4. Result: zero-slippage swaps at oracle price, no liquidity pool needed

### 2. Reactive Network

ReactiveOracleSync is deployed on **Reactive Network Lasna Testnet (chain 5318007)**. It subscribes to `PriceUpdated` and `LiquidationEnabled` events from DobValidatorRegistry on Unichain and triggers automated cross-chain callbacks when prices drop below configured thresholds.

| What | Where in Code |
|------|---------------|
| **ReactiveOracleSync** — Reactive contract | [`contracts/src/ReactiveOracleSync.sol`](contracts/src/ReactiveOracleSync.sol) |
| **OracleAlertReceiver** — Callback handler on Unichain | [`contracts/src/OracleAlertReceiver.sol`](contracts/src/OracleAlertReceiver.sol) |
| **Reactive deployment script** | [`contracts/script/DeployReactive.s.sol`](contracts/script/DeployReactive.s.sol) |
| **Unichain deployment** (deploys OracleAlertReceiver) | [`contracts/script/DeployUnichain.s.sol`](contracts/script/DeployUnichain.s.sol) |
| **Callback Proxy** on Unichain Sepolia | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |

**How it works:**
1. ReactiveOracleSync subscribes to `PriceUpdated(address indexed token, uint256 priceUsd, uint48 timestamp)` events from DobValidatorRegistry on Unichain via Reactive Network's `ISubscriptionService`
2. When a price update fires on Unichain, Reactive Network's ReactVM calls `react()` on the contract
3. If the new price drops below a configured alert threshold, the contract emits a `Callback` event
4. Reactive Network delivers the callback to `OracleAlertReceiver` on Unichain via the Callback Proxy
5. Result: fully on-chain, cross-chain oracle monitoring with automated liquidation alerts — no off-chain bots

---

## Architecture

```
Unichain Sepolia (1301)                    Reactive Network (5318007)
┌─────────────────────────┐                ┌──────────────────────────┐
│  DobValidatorRegistry   │──PriceUpdated──│  ReactiveOracleSync      │
│  (oracle prices)        │    events      │  (subscribes & monitors) │
│                         │                │                          │
│  DobPegHook             │                │  If price < threshold:   │
│  (V4 Custom Accounting) │◄──Callback─────│  emit Callback event     │
│                         │   via Proxy    │                          │
│  OracleAlertReceiver    │                └──────────────────────────┘
│  (receives alerts)      │
│                         │
│  DobRwaVault (dUSDC)    │
│  DobLPRegistry (LPs)    │
│  DobSwapRouter          │
└─────────────────────────┘
```

## Deployed Contracts

### Unichain Sepolia (1301)

| Contract | Address |
|----------|---------|
| PoolManager (Uniswap V4) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| DobPegHook | `0x7A930578fd9e286Eb2B1484257ABD5681d216888` |
| DobSwapRouter | `0xF19Da1af27cCC8B52D774E48cAe046761d9840d6` |
| DobValidatorRegistry | `0x686C24BD17Ff53Ed76b693CA69135e161C55af99` |
| DobRwaVault (dUSDC) | `0xacA7f5f523B2028FC350557B989c57161c1C366E` |
| DobLPRegistry | `0xcfDf62D41222c832332209B03Ffe9eAD427f74F1` |
| OracleAlertReceiver | `0x3225c532A760D9482f88354C7B783E7c4a96cb2f` |
| USDC (Mock) | `0x7Edc4da416CB70C879693CB931fcdA50706b732E` |
| DCT | `0xADD824a93d5fA9A12c73cecA4eba30595C453AE8` |
| SFT | `0x948B342850FB5F540e8Af50D4164945cADD658eb` |
| RET | `0x00c491Efa4C129e3dC18823D28e2516EDBce3c7d` |
| PWG | `0xA30fdEf45588c0BBB5b508f50b739071ddd9aC58` |

### Reactive Network Lasna Testnet (5318007)

| Contract | Address |
|----------|---------|
| ReactiveOracleSync | `0x7Edc4da416CB70C879693CB931fcdA50706b732E` |

## Smart Contracts

| Contract | LOC | Description |
|----------|-----|-------------|
| `DobPegHook.sol` | 366 | Uniswap V4 Custom Accounting Hook — intercepts swaps, settles at 1:1 oracle peg |
| `DobRwaVault.sol` | 129 | RWA deposit vault, mints dUSDC ERC-20 at oracle price |
| `DobValidatorRegistry.sol` | 163 | On-chain oracle + liquidation parameters |
| `DobLPRegistry.sol` | 652 | Permissionless LP system with FIFO liquidation fills |
| `DobSwapRouter.sol` | 132 | Uniswap V4 swap interface |
| `DobDirectSwap.sol` | 106 | Lightweight 1:1 swap for non-V4 chains |
| `DobTokenFactory.sol` | — | RWA token factory + MockUSDC |
| `ReactiveOracleSync.sol` | 270 | Reactive Network cross-chain oracle monitor |
| `OracleAlertReceiver.sol` | 165 | Callback receiver for Reactive Network alerts |
| **Total** | **~2,100** | |

## Tests

```bash
cd contracts && forge test -vvv
```

77 tests passing across 7 test suites. Covers:
- DobPegHook: V4 swap settlement, liquidation mode, oracle staleness
- DobLPRegistry: LP registration, backing, fills, withdrawals, reserves
- DobTokenFactory: Token creation, sales, faucets
- DobRwaVault: Deposits, minting, asset approval
- DobValidatorRegistry: Price updates, liquidation params
- DobDirectSwap: 1:1 peg swaps

## Deployment

### Unichain Sepolia

```bash
cd contracts
export PRIVATE_KEY=<your-key>
export UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org

# Deploy full stack (V4 hook + OracleAlertReceiver)
forge script script/DeployUnichain.s.sol:DeployUnichain \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast -vvv
```

### Reactive Network

```bash
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/
export REGISTRY=<registry-from-unichain-deploy>
export ALERT_RECEIVER=<alert-receiver-from-unichain-deploy>

# Deploy ReactiveOracleSync
forge script script/DeployReactive.s.sol:DeployReactive \
  --rpc-url $REACTIVE_RPC --broadcast -vvv
```

## Project Structure

```
contracts/
  src/
    DobPegHook.sol              # Uniswap V4 Custom Accounting Hook (partner: Unichain)
    DobRwaVault.sol             # RWA vault + dUSDC token
    DobValidatorRegistry.sol    # Oracle + liquidation parameters
    DobLPRegistry.sol           # Permissionless LP system
    DobSwapRouter.sol           # V4 swap router
    DobDirectSwap.sol           # Lightweight 1:1 swap
    DobTokenFactory.sol         # Token factory
    ReactiveOracleSync.sol      # Cross-chain oracle monitor (partner: Reactive Network)
    OracleAlertReceiver.sol     # Callback receiver (partner: Reactive Network)
  script/
    DeployUnichain.s.sol        # Unichain Sepolia deployment
    DeployReactive.s.sol        # Reactive Network deployment
  test/                         # 77 tests
app/
  index.html                    # Swap UI (Unichain Sepolia)
  landing.html                  # Landing page
  demo.html                     # Interactive demo
  protocol.html                 # Protocol explainer
  deck.html                     # Pitch deck
api/
  server.js                     # Backend API
```

## Tech Stack

- **Solidity** ^0.8.26, Foundry
- **Uniswap V4** (v4-core, v4-periphery, Custom Accounting Hooks)
- **Unichain** — Uniswap's OP Stack L2 with 200ms Flashblocks
- **Reactive Network** — Cross-chain event-driven automation
- **Solmate** (ERC20, Owned, SafeTransferLib, ReentrancyGuard)
- **Frontend**: Vanilla HTML/CSS/JS, ethers.js, MetaMask

## Links

- **Live App**: [dex.dobprotocol.com](https://dex.dobprotocol.com)
- **Docs**: [docs.dobprotocol.com](https://docs.dobprotocol.com)
- **Unichain Explorer**: [sepolia.uniscan.xyz](https://sepolia.uniscan.xyz)
- **Reactive Explorer**: [lasna.reactscan.net](https://lasna.reactscan.net)

## License

MIT
