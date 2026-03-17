# DobDex — RWA Liquidity Infrastructure

## Repository

- **Repo**: https://github.com/Dobprotocol/DobDex
- **Branches**: `main` (stable), `prod` (active development)

## Dobprotocol Ecosystem

DobDex is the final step in the Dobprotocol pipeline. The full flow:

1. **DOBVALIDATOR** (`../DOBVALIDATOR/`) — Asset owners register their real-world assets. Dobprotocol validates them and creates oracle price feeds. → [validator.dobprotocol.com](https://validator.dobprotocol.com)
2. **Dob Token Studio / Dober-MVP** (`../Dober-MVP/`) — Validated assets are tokenized into ERC-20 participation tokens (DCT, SFT, RET, PWG, etc.). → [tokenize.dobprotocol.com](https://tokenize.dobprotocol.com)
3. **Distribution Contracts** (`../distribution-contracts/`) — EVM contracts for the ERC token standards used by the Token Studio.
4. **DobDex** (this repo) — Dobprotocol lists the tokenized asset: sets the oracle price in `DobValidatorRegistry`, approves it in `DobRwaVault`, and it becomes available for deposits, 1:1 peg swaps, and LP-backed liquidations. → [dex.dobprotocol.com](https://dex.dobprotocol.com)

## Project Structure

```
contracts/           # Foundry project (Uniswap V4 hooks + protocol contracts)
  src/
    DobPegHook.sol           # Uniswap V4 Custom Accounting Hook (NoOp swap at 1:1 peg)
    DobRwaVault.sol          # RWA vault + dUSDC ERC-20 token
    DobValidatorRegistry.sol # Oracle + liquidation parameters
    DobLPRegistry.sol        # Permissionless LP system for liquidation fills
    DobTokenFactory.sol      # Token factory for RWA tokens
    DobSwapRouter.sol        # Uniswap V4 swap router (Arb Sepolia)
    DobDirectSwap.sol        # Lightweight 1:1 peg swap (Robinhood, no Uniswap V4)
    RWAFaucet.sol            # Testnet faucet for RWA tokens
  test/
  script/
    DeployArbitrumSepolia.s.sol  # Arbitrum Sepolia deployment
    DeployRobinhoodTestnet.s.sol # Robinhood Testnet deployment
    DeploySwapRouter.s.sol       # DobSwapRouter deployment
    DeployDirectSwap.s.sol       # DobDirectSwap deployment
    oracle-updater.sh            # Oracle price update script
    oracle-cron.sh               # Cron wrapper for both chains
api/                 # Backend API server
  server.js          # Node.js, queries MVP + Validator DBs
  .env.example       # Credential template
  package.json
app/                 # Frontend (static HTML)
  landing.html       # Landing page
  protocol.html      # Protocol explainer page
  index.html         # App UI (swap interface)
  deck.html          # Pitch deck
specs.md             # Architecture specifications
DOBVALIDATOR_ORACLE_PROMPT.md  # Oracle integration guide for DOBVALIDATOR
```

## Deployed Contracts

### Arbitrum Sepolia (421614) — Full Uniswap V4
- PoolManager: `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317`
- Hook: `0xDD1bd603798bD864a5dF35aF3c12E836bA4e6888`
- DobSwapRouter: `0xc11B7f1B68d5911787fBD8ACf6251986d40f12E0`
- Registry: `0x686C24BD17Ff53Ed76b693CA69135e161C55af99`
- Vault (dUSDC): `0xacA7f5f523B2028FC350557B989c57161c1C366E`
- LPRegistry: `0xcfDf62D41222c832332209B03Ffe9eAD427f74F1`
- USDC: `0x7Edc4da416CB70C879693CB931fcdA50706b732E`

### Robinhood Testnet (46630) — DobDirectSwap (no Uniswap V4)
- DobDirectSwap: `0x0C4a9BE642E2923a5eBd2c300C8D3300119Dbd8A`
- Same Registry/Vault/LPRegistry/USDC addresses (deterministic CREATE)

## Core Protocol

- **dUSDC**: The protocol's stablecoin — minted 1:1 when depositing RWA tokens, redeemable 1:1 for USDC.
- **Oracle**: Managed by Dobprotocol (not self-service). Dobprotocol's AI validator agents set prices via `DobValidatorRegistry.setPrice()`.
- **Peg Mechanism**: Uniswap V4 hook intercepts swaps via `beforeSwap` + `beforeSwapReturnDelta`, settles at exact 1:1 oracle price using Custom Accounting (NoOp pattern). On chains without Uniswap V4, `DobDirectSwap` provides the same 1:1 swap.
- **Swap**: Bidirectional — Sell RWA (deposit RWA → mint dUSDC) and Buy RWA (burn dUSDC → withdraw RWA).
- **Redeem**: dUSDC → USDC conversion on the dUSDC page.
- **Liquidation**: Dobprotocol activates liquidation mode on distressed assets with a penalty rate. LPs set their own `minPenaltyBps` (minimum discount they require to participate in fills).
- **LP System**: Permissionless. LPs deposit USDC, back specific assets with conditions (minOraclePrice, minPenaltyBps, maxExposure, usdcAllocation), filled in FIFO order during liquidations.

## API Server

- `api/server.js` queries MVP (dob-prod) and Validator (dob-validator) PostgreSQL databases
- `GET /api/validated-pools?networks=421614,46630` — returns verified pools with certificate scores
- `GET /api/health` — health check
- Runs as systemd service `dobdex-api` on port 3050, proxied via nginx at `/api/`

## UI Pages

- `landing.html` — Landing page with hero, features, how it works
- `protocol.html` — Deep dive protocol explainer
- `index.html` — App UI: Swap (sell/buy RWA toggle), Liquidity Node, Assets, Activity, dUSDC (redeem + pool info)
- `deck.html` — 16-slide pitch deck
- Design system: dark/light theme toggle, Inter font, accent=#975AFF, blue=#597CE9, green=#40C057
- All pages use `zoom: 1.5` for default readability

## Strategic Infrastructure

- **AI Agent Economy**: Every protocol layer is designed for autonomous AI agents — Validator agents update oracles, LP Strategy agents manage liquidity, creating a composable agent marketplace.
- **Robinhood Chain**: L2 built on Arbitrum, purpose-built for tokenized RWAs. 100ms block times for fast oracle updates. Robinhood's retail distribution network.
- **Arbitrum Stylus**: Build DobValidatorRegistry oracle in Rust for 10-100x cheaper gas. Critical for running AI-driven risk models on-chain.

## Documentation

Comprehensive protocol documentation is hosted at **[docs.dobprotocol.com](https://docs.dobprotocol.com)**. The DobDex section covers:
- **Zero-slippage DEX**: How the 1:1 peg swap mechanism works via Uniswap V4 Custom Accounting
- **Liquidity Nodes**: Permissionless LP system, FIFO fills, and allocation strategies
- **Liquidations**: Distressed asset handling, penalty rates, and LP participation
- **DobPegHook**: Technical deep-dive into the Uniswap V4 hook (NoOp + beforeSwapReturnDelta)

Direct link: [docs.dobprotocol.com/dex/overview](https://docs.dobprotocol.com/dex/overview)

## Tech Stack

- Solidity ^0.8.26, Foundry
- Uniswap V4 (v4-core, v4-periphery, OpenZeppelin uniswap-hooks)
- Solmate (ERC20, Owned, SafeTransferLib, ReentrancyGuard)
- Frontend: Vanilla HTML/CSS/JS, ethers.js, MetaMask
- API: Node.js, pg (PostgreSQL)
