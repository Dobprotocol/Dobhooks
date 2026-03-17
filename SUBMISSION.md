# DobDex — Hackathon Submission

## Arbitrum Open House NYC: Founder House

---

## Project Name

**DobDex** — Zero-Slippage RWA Liquidity Infrastructure

## One-Line Description

A Uniswap V4 Custom Accounting Hook DEX that enables zero-slippage swaps for tokenized real-world assets, with a permissionless LP system for orderly liquidations — deployed on Arbitrum Sepolia, Robinhood Chain, and Base Sepolia.

## Tracks

- **Open House NYC Champions** — Full Uniswap V4 integration on Arbitrum Sepolia
- **Robinhood Chain Founder-in-Residence** — Complete protocol deployed on Robinhood Chain
- **Robinhood Chain Innovation Award** — DobDirectSwap + Oracle system on Robinhood Chain

## Links

| Resource | URL |
|----------|-----|
| **Live Demo** | https://dex.dobprotocol.com |
| **Interactive Product Demo** | https://dex.dobprotocol.com/demo.html |
| **GitHub Repository** | https://github.com/Dobprotocol/DobDex |
| **Protocol Documentation** | https://dex.dobprotocol.com/protocol.html |
| **Pitch Deck (16 slides)** | https://dex.dobprotocol.com/deck.html |
| **Landing Page** | https://dex.dobprotocol.com/landing.html |

## Deployed Contracts

### Arbitrum Sepolia (421614) — Full Uniswap V4

| Contract | Address | Explorer |
|----------|---------|----------|
| DobPegHook (V4) | 0xDD1bd603798bD864a5dF35aF3c12E836bA4e6888 | [arbiscan](https://sepolia.arbiscan.io/address/0xDD1bd603798bD864a5dF35aF3c12E836bA4e6888) |
| DobSwapRouter | 0xc11B7f1B68d5911787fBD8ACf6251986d40f12E0 | [arbiscan](https://sepolia.arbiscan.io/address/0xc11B7f1B68d5911787fBD8ACf6251986d40f12E0) |
| DobValidatorRegistry | 0x686C24BD17Ff53Ed76b693CA69135e161C55af99 | [arbiscan](https://sepolia.arbiscan.io/address/0x686C24BD17Ff53Ed76b693CA69135e161C55af99) |
| DobRwaVault (dUSDC) | 0xacA7f5f523B2028FC350557B989c57161c1C366E | [arbiscan](https://sepolia.arbiscan.io/address/0xacA7f5f523B2028FC350557B989c57161c1C366E) |
| DobLPRegistry | 0xcfDf62D41222c832332209B03Ffe9eAD427f74F1 | [arbiscan](https://sepolia.arbiscan.io/address/0xcfDf62D41222c832332209B03Ffe9eAD427f74F1) |

### Robinhood Chain Testnet (46630) — DobDirectSwap

| Contract | Address |
|----------|---------|
| DobDirectSwap | 0x0C4a9BE642E2923a5eBd2c300C8D3300119Dbd8A |
| DobValidatorRegistry | 0x686C24BD17Ff53Ed76b693CA69135e161C55af99 |
| DobRwaVault (dUSDC) | 0xacA7f5f523B2028FC350557B989c57161c1C366E |
| DobLPRegistry | 0xcfDf62D41222c832332209B03Ffe9eAD427f74F1 |

### Base Sepolia (84532) — DobDirectSwap

| Contract | Address | Explorer |
|----------|---------|----------|
| DobDirectSwap | 0x6E7266C075e931bfF4172bd9ce97D1439fAf694a | [basescan](https://sepolia.basescan.org/address/0x6E7266C075e931bfF4172bd9ce97D1439fAf694a) |
| DobValidatorRegistry | 0xacA7f5f523B2028FC350557B989c57161c1C366E | [basescan](https://sepolia.basescan.org/address/0xacA7f5f523B2028FC350557B989c57161c1C366E) |
| DobRwaVault (dUSDC) | 0xcfDf62D41222c832332209B03Ffe9eAD427f74F1 | [basescan](https://sepolia.basescan.org/address/0xcfDf62D41222c832332209B03Ffe9eAD427f74F1) |

---

## Project Description

### Problem

Real-world assets (RWAs) represent a $16T+ market moving on-chain, but tokenized RWA holders face a critical problem: **no exit liquidity**. Traditional AMMs introduce slippage and impermanent loss that don't make sense for oracle-priced assets. When an asset becomes distressed, there's no mechanism for orderly liquidation.

### Solution

DobDex is a **zero-slippage DEX** purpose-built for tokenized real-world assets. It uses a **Uniswap V4 Custom Accounting Hook** (NoOp swap pattern) to intercept swaps and settle at the exact oracle price — no AMM curve, no slippage, no impermanent loss.

**How it works:**
1. User initiates a swap on the Uniswap V4 PoolManager
2. `beforeSwap()` hook intercepts and queries the DobValidatorRegistry oracle
3. Hook returns a `BeforeSwapDelta` — PoolManager skips AMM math entirely
4. Settlement at exact 1:1 oracle price — zero slippage

For chains without Uniswap V4 (like Robinhood Chain), `DobDirectSwap` provides the same 1:1 oracle-pegged swap without any V4 dependency.

### Liquidation System

When Dobprotocol's AI validators detect asset distress, a permissionless **Liquidity Node** system activates:

- **LPs deposit USDC** into DobLPRegistry and set per-asset conditions
- **FIFO matching** — LPs are filled in registration order during liquidations
- **Penalty spread** — LPs earn the discount as profit (e.g., buy at 80%, receive dUSDC at 100%)
- **33% reserve holds** — Prevents cascading exits during stress events
- **Anti-flash-loan** — MIN_BACKING_AGE prevents flash-loan LP attacks
- **Time-locked withdrawals** — 24h delay prevents front-running liquidation events

### Arbitrum & Robinhood Chain Integration

- **Arbitrum Sepolia**: Full Uniswap V4 Hook deployment with Custom Accounting
- **Robinhood Chain**: DobDirectSwap — optimized for Robinhood's 100ms block times, purpose-built for retail RWA trading
- **Base Sepolia**: Additional DobDirectSwap deployment demonstrating multi-chain portability

### Why Robinhood Chain?

Robinhood Chain is an L2 built on Arbitrum Orbit, purpose-built for tokenized RWAs. DobDex is designed to be core infrastructure on Robinhood Chain:
- **100ms block times** enable real-time oracle updates from AI validators
- **Retail distribution** — Robinhood's user base provides the demand side for tokenized RWAs
- **DobDirectSwap** is purpose-built for chains without Uniswap V4, making it the ideal swap primitive for Robinhood Chain

### Roadmap to Mainnet

1. **Arbitrum Stylus** — Port DobValidatorRegistry oracle to Rust for 10-100x cheaper gas, enabling AI-driven risk models to run on-chain
2. **AI Agent Marketplace** — Autonomous validator agents update oracles, LP strategy agents optimize liquidity allocation
3. **Cross-chain dUSDC** — Bridge dUSDC between Arbitrum, Robinhood Chain, and Base via LayerZero
4. **Mainnet deployment** — Arbitrum One + Robinhood Chain mainnet with real validated RWA assets

---

## Technical Details

### Smart Contracts (~1,900 LOC Solidity)

| Contract | LOC | Purpose |
|----------|-----|---------|
| DobPegHook.sol | 366 | Uniswap V4 Custom Accounting Hook |
| DobRwaVault.sol | 129 | RWA deposit vault + dUSDC ERC-20 token |
| DobValidatorRegistry.sol | 163 | On-chain oracle + liquidation parameters |
| DobLPRegistry.sol | 652 | Permissionless LP system for liquidation fills |
| DobDirectSwap.sol | 106 | Lightweight 1:1 peg swap (no V4 dependency) |
| DobSwapRouter.sol | 132 | Uniswap V4 swap routing |
| DobTokenFactory.sol | 210 | RWA token factory |
| RWAFaucet.sol | 57 | Testnet USDC faucet |

### Test Suite

**77 tests, 0 failures** across 7 test suites:

- Oracle tests (price setting, staleness, reverts)
- Vault tests (deposit, unauthorized asset, stale oracle)
- Hook swap tests (1:1 peg both directions, access control)
- Liquidation tests (penalty, caps, partial fills, global caps)
- LP system tests (registration, backings, FIFO fills, reserve holds, withdrawals, claims)
- Token factory tests (creation, integration, access control)
- Full integration tests (buy → deposit → swap → redeem flow)

### Tech Stack

- Solidity ^0.8.26, Foundry
- Uniswap V4 (v4-core, v4-periphery, OpenZeppelin uniswap-hooks)
- Solmate (ERC20, Owned, SafeTransferLib, ReentrancyGuard)
- Frontend: Vanilla HTML/CSS/JS, ethers.js v6
- Backend: Node.js, PostgreSQL
- API: REST endpoints for validated pool data + swap history

### Security Features

- `ReentrancyGuard` on all state-modifying transfers
- `MIN_BACKING_AGE` (1 hour) prevents flash-loan LP attacks
- `MAX_BACKERS_PER_ASSET` caps gas cost of on-chain iteration
- `maxOracleDelay` (24h) circuit breaker pauses minting on stale oracle
- Time-locked withdrawals (24h) prevent front-running liquidations
- Reserve holds (33%) prevent cascading exits during stress
- Per-asset and global liquidation caps prevent unlimited dumping

---

## Dobprotocol Ecosystem

DobDex is the final piece of a full-stack RWA infrastructure:

1. **DOBVALIDATOR** — AI validates real-world assets, creates oracle feeds → [validator.dobprotocol.com](https://validator.dobprotocol.com)
2. **Token Studio** — Tokenizes validated assets into ERC-20 participation tokens → [tokenize.dobprotocol.com](https://tokenize.dobprotocol.com)
3. **DobDex** — Lists tokens, oracle pricing, zero-slippage swaps, LP liquidity → [dex.dobprotocol.com](https://dex.dobprotocol.com)

---

## How to Test

1. Visit [dex.dobprotocol.com](https://dex.dobprotocol.com)
2. Connect MetaMask
3. Switch network (Arbitrum Sepolia / Robinhood Chain / Base Sepolia)
4. Go to **Get Tokens** → Claim 100k test USDC
5. Buy RWA tokens (DCT, SFT, etc.)
6. **Swap** → Sell RWA tokens, receive dUSDC at oracle price (zero slippage)
7. **dUSDC** → Redeem dUSDC for USDC 1:1
8. **Liquidity Node** → Register as LP, deposit USDC, back assets

Or view the [Interactive Demo](https://dex.dobprotocol.com/demo.html) without connecting a wallet.
