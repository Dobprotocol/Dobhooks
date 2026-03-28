# DobDex — RWA Exit Liquidity Infrastructure

## Repository

- **Repo**: https://github.com/Dobprotocol/Dobhooks
- **Branches**: `main` (stable), `prod` (active development)

## Business Model

The full Dobprotocol flow:
1. **Asset owner** needs capital → tokenizes their real-world asset
2. **Token gives APR** via periodic distributions (handled by Token Studio's `DistributionPool.sol`, NOT by DobDex)
3. **Liquidity Nodes** (individual LPs or Pooled LN) provide USDC exit liquidity for token holders
4. **Retail investors** buy tokens for the APR yield, knowing they can exit anytime through LPs
5. **When selling**, the seller pays a discount to the LP who provides the exit USDC (FIFO order)
6. **The Main LN** is a `DobPooledLN` managed by Dobprotocol — anyone can co-invest and earn proportional RWA tokens

**CRITICAL**: The dUSDC → USDC swap is NOT oracle-pegged. The oracle only prices the RWA → dUSDC vault conversion. Exit liquidity is priced by Liquidity Nodes (LP discount via `minPenaltyBps`). `lpOnlyMode` is the production default — all sells route through LPs. Never describe swaps as "zero slippage" or "1:1 oracle peg".

## Dobprotocol Ecosystem

DobDex is the final step in the Dobprotocol pipeline:

1. **DOBVALIDATOR** (`../DOBVALIDATOR/`) — Asset owners register their real-world assets. Dobprotocol validates them and creates oracle price feeds. → [validator.dobprotocol.com](https://validator.dobprotocol.com)
2. **Dob Token Studio / Dober-MVP** (`../Dober-MVP/`) — Validated assets are tokenized into ERC-20 participation tokens (DCT, SFT, RET, PWG, etc.). Tokens generate APR via `DistributionPool.sol`. → [tokenize.dobprotocol.com](https://tokenize.dobprotocol.com)
3. **Distribution Contracts** (`../distribution-contracts/`) — EVM + Stellar contracts for periodic yield distribution to token holders.
4. **DobDex** (this repo) — Dobprotocol lists the tokenized asset: sets the oracle price in `DobValidatorRegistry`, approves it in `DobRwaVault`, and it becomes available for deposits, LP-priced exit swaps, and liquidations. → [dex.dobprotocol.com](https://dex.dobprotocol.com)

## Project Structure

```
contracts/           # Foundry project (Uniswap V4 hooks + protocol contracts)
  src/
    DobPegHook.sol           # Uniswap V4 Custom Accounting Hook (LP-routed exit swaps)
    DobRwaVault.sol          # RWA vault + dUSDC ERC-20 token
    DobValidatorRegistry.sol # Oracle + liquidation parameters
    DobLPRegistry.sol        # Permissionless LP system for liquidation + sell fallback fills
    DobPooledLN.sol          # Shared Liquidity Node (pooled LP position in LPRegistry)
    DobTokenFactory.sol      # Token factory for RWA tokens
    DobSwapRouter.sol        # Uniswap V4 swap router
    DobDirectSwap.sol        # Lightweight LP-routed swap (chains without Uniswap V4)
    ReactiveOracleSync.sol   # Cross-chain oracle monitor (Reactive Network)
    OracleAlertReceiver.sol  # Receives cross-chain callbacks from Reactive Network
    RWAFaucet.sol            # Testnet faucet for RWA tokens
  test/
  script/
    DeployUnichain.s.sol         # Unichain Sepolia deployment (primary)
    DeployArbitrumSepolia.s.sol  # Arbitrum Sepolia deployment
    DeployRobinhoodTestnet.s.sol # Robinhood Testnet deployment
    DeployBaseSepolia.s.sol      # Base Sepolia deployment
    DeployReactive.s.sol         # Reactive Network oracle sync deployment
    DeploySwapRouter.s.sol       # DobSwapRouter deployment
    DeployDirectSwap.s.sol       # DobDirectSwap deployment
    DeployExtraTokens.s.sol      # Additional RWA token deployment
    UpgradeUnichain.s.sol        # Upgrade Hook + LPRegistry on Unichain
    DeployPooledLN.s.sol         # Deploy DobPooledLN (shared Liquidity Node)
    oracle-updater.sh            # Oracle price update script
    oracle-cron.sh               # Cron wrapper for oracle updates (Unichain Sepolia)
api/                 # Backend API server
  server.js          # Node.js, queries MVP + Validator DBs
  .env.example       # Credential template
  package.json
app/                 # Frontend (static HTML)
  landing.html       # Landing page
  protocol.html      # Protocol explainer page
  index.html         # App UI (swap interface)
  deck.html          # Pitch deck
  demo.html          # Demo page
specs.md             # Architecture specifications
DOBVALIDATOR_ORACLE_PROMPT.md  # Oracle integration guide for DOBVALIDATOR
```

## Deployed Chains

### Unichain Sepolia (1301) — PRIMARY, Full Uniswap V4
- PoolManager: `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`
- DobPegHook: `0x9966a54849979F9d037f797Bc1594731fbd82888` (CREATE2 via HookMiner)
- DobValidatorRegistry: `0x652E5572aF3a879D591a4DD289566bcF28BeA52B`
- DobRwaVault (dUSDC): `0x5d38b9bD487D8a0ff7997dB953a68F650B242e00`
- DobLPRegistry: `0xb00Ee936e85B9e0F2f67bd890D545a0E8FCa404F`
- DobPooledLN: `0x8EBB4B407Eb6365FbFaB9Cf01689a62c24cC7c25`
- MockUSDC: `0x217f355497A67F5ef82cff105Fb14a84C9A9E071`
- OracleAlertReceiver: `0x7D336CC15A7675EAa717F004B973623F7Db59a4b`
- Config: swapFee=0.3%, protocolFee=0.1%, PooledLN backs DCT+SFT at 3% discount
- 10 RWA tokens: DCT (Datacenter, Low, 8.5%), SFT (Solar Farm, Medium, 7.2%), RET (Real Estate, Low, 6%), PWG (Power Grid, Low, 5.8%), WFT (Wind Farm, Medium, 6.5%), GLT (Gold Reserve, Low, 3.2%), EVT (EV Fleet, High, 9%), TBT (Treasury Bond, Low, 4.3%), FLT (Farmland, Low, 5.5%), SCT (Shipping, Medium, 7.8%)
- Frontend configured exclusively for this chain

### Arbitrum Sepolia (421614) — Full Uniswap V4
- PoolManager: `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317`
- Hook: `0xDD1bd603798bD864a5dF35aF3c12E836bA4e6888`
- DobSwapRouter: `0xc11B7f1B68d5911787fBD8ACf6251986d40f12E0`
- Registry: `0x686C24BD17Ff53Ed76b693CA69135e161C55af99`
- Vault (dUSDC): `0xacA7f5f523B2028FC350557B989c57161c1C366E`
- LPRegistry: `0xcfDf62D41222c832332209B03Ffe9eAD427f74F1`
- USDC: `0x7Edc4da416CB70C879693CB931fcdA50706b732E`
- 4 core + 6 extra RWA tokens

### Robinhood Testnet (46630) — DobDirectSwap (no Uniswap V4)
- DobDirectSwap: `0x0C4a9BE642E2923a5eBd2c300C8D3300119Dbd8A`
- Same Registry/Vault/LPRegistry/USDC addresses as Arbitrum (deterministic CREATE)
- 4 core + 6 extra RWA tokens

### Base Sepolia (84532) — DobDirectSwap (no Uniswap V4)
- Full core protocol + DobDirectSwap
- 4 core + 6 extra RWA tokens

### Reactive Network Lasna Testnet (5318007) — Cross-chain Oracle
- ReactiveOracleSync: monitors PriceUpdated + LiquidationEnabled events on Unichain Sepolia
- Sends cross-chain callbacks to OracleAlertReceiver on Unichain

## Core Protocol

- **dUSDC**: The protocol's intermediate stablecoin — minted when depositing RWA tokens at oracle price, burned when withdrawing. Used as the settlement token between the vault and the hook.
- **Oracle**: Managed by Dobprotocol (not self-service). AI validator agents set prices via `DobValidatorRegistry.setPrice()`. Oracle is used ONLY for: (1) vault deposit/withdraw (RWA ↔ dUSDC conversion), (2) LP condition checks (`minOraclePrice`), (3) resale market pricing, (4) staleness circuit breakers. Oracle does NOT determine the dUSDC → USDC swap rate.
- **Sell Flow (UI)**: User selects RWA token + amount → preview shows oracle price, swap fee, protocol fee, LP discount estimate, configurable slippage → executes 4-step tx: (1) approve RWA to vault, (2) vault.deposit mints dUSDC, (3) approve dUSDC to router, (4) router.swap with hookData=[rwaToken, minAmountOut] routes through LPs → seller receives USDC. With `lpOnlyMode` (production default), ALL sells must go through LPs.
- **Buy Flow**: User sends USDC → buys RWA tokens directly at oracle price (no LP discount, no fees). Route: "Direct at Oracle Price".
- **Redeem**: dUSDC → USDC conversion routed through LPs (same as sell). Swap and protocol fees + LP discount apply.
- **Liquidation**: Dobprotocol activates liquidation mode on distressed assets with a penalty rate. LPs set their own `minPenaltyBps` (minimum discount they require to participate in fills).
- **LP System**: Permissionless. LPs deposit USDC, back specific assets with conditions (minOraclePrice, minPenaltyBps, maxExposure, usdcAllocation), filled in FIFO order. LPs participate in two modes:
  - **Normal sells** (`queryAndFillAtMarket`): LPs fill at their own `minPenaltyBps` discount — the primary sell mechanism.
  - **Liquidation fills** (`queryAndFill`): protocol-mandated penalty rate on distressed assets.
- **LP-Only Mode**: Per-token toggle (`hook.setLpOnlyMode(token, true)`). Production default. Sells skip hook USDC reserves entirely — only succeed if LPs fill them. This is the intended behavior: sellers always pay LP discount for exit.
- **Pooled LN** (`DobPooledLN`): Shared USDC vault that acts as a single LP in `DobLPRegistry`. Managed by Dobprotocol (operator), open for anyone to co-invest. Depositors receive shares, earn proportional RWA tokens from fills. Operator can update discounts dynamically via `updateDiscount()`. Multiple instances can coexist with different strategies. The "Main LN" is Dobprotocol's primary Pooled LN instance.
- **Dynamic Discounts**: Both individual LPs and Pooled LNs can change their `minPenaltyBps` at any time via `updateConditions()` / `updateDiscount()`, enabling on-chain/off-chain data-driven pricing.
- **RWA Resale Market**: LPs (or anyone holding RWA tokens) can list them for sale at oracle price via `hook.listRwaForSale(rwaToken, amount)`. Buyers purchase via `hook.buyListedRwa(rwaToken, amount)`, paying USDC at oracle price + swap fee. Sellers receive USDC directly. FIFO fill order, max 50 sellers per token.
- **Security**: Emergency pause on all contracts, oracle price bounds (`maxPriceChangeBps`), slippage protection (`minAmountOut` in hookData), admin transfer (`transferAdmin()`), protocol fee (`protocolFeeBps`). UI enforces: oracle staleness check (blocks sell/buy when stale), hook paused check, LP liquidity check for lpOnly assets, exact-amount approvals (no MaxUint256).
- **Cross-chain Oracle**: Reactive Network monitors oracle events on Unichain and triggers callbacks for liquidation alerts.
- **Oracle Cron**: Local crontab runs `oracle-cron.sh` every 5 minutes to keep prices fresh on Unichain Sepolia. `maxOracleDelay` is 24 hours — if cron stops, vault operations revert with `OracleStale()`.

## Partner Integrations

- **Uniswap / Unichain**: Primary deployment on Unichain Sepolia with full Uniswap V4 Custom Accounting hook (DobPegHook). The hook uses the NoOp + beforeSwapReturnDelta pattern to route sells through Liquidity Nodes at LP-set discount rates.
- **Reactive Network**: Cross-chain oracle monitoring. ReactiveOracleSync on Lasna Testnet subscribes to DobValidatorRegistry events on Unichain and sends callbacks to OracleAlertReceiver for automated liquidation alerts.

## API Server

- `api/server.js` queries MVP (dob-prod) and Validator (dob-validator) PostgreSQL databases
- `GET /api/validated-pools?networks=421614,46630` — returns verified pools with certificate scores
- `GET /api/health` — health check
- Runs as systemd service `dobdex-api` on port 3050, proxied via nginx at `/api/`

## UI Pages

- `landing.html` — Landing page with hero, features, how it works
- `protocol.html` — Deep dive protocol explainer (architecture, swap flow, LP system, Pooled LN, security)
- `index.html` — App UI with 7 tabs:
  - **Swap**: Sell RWA (full LP-routed flow with fee breakdown + configurable slippage), Buy RWA (direct at oracle price), Resale Market (list/buy peer-to-peer)
  - **Liquidity Node**: Network Overview, Pooled LN (deposit/withdraw with share preview, claim RWA), Individual LP (register, back assets, update conditions, claim, withdraw with 24h countdown)
  - **Assets**: All 10 RWA tokens with oracle price, TVL, LP liquidity, yield, risk badge, exit cost range. Sortable by price/yield/risk/liquidity.
  - **Portfolio**: Total value dashboard, RWA holdings with risk badges, LP backings with per-asset earned RWA, Pooled LN value, pending withdrawals, Glossary (8 key terms)
  - **Activity**: Persistent activity log (localStorage), filterable by type (swap/lp/deposit/system), tx explorer links
  - **Get Tokens**: USDC faucet with cooldown, buy RWA tokens at oracle price
  - **dUSDC**: Swap dUSDC↔USDC with slippage control, Hook LP pool deposit/withdraw, pool stats
- `simulate.html` — Interactive protocol simulator with 8 scenario walkthroughs
- `deck.html` — Pitch deck
- `demo.html` — Audio-narrated demo walkthrough
- Design system: dark/light theme toggle, Inter font, accent=#975AFF, blue=#597CE9, green=#40C057
- All pages use `zoom: 1.5` for default readability
- Onboarding modal on first visit (role picker: Investor → Buy tab, LP → Liquidity Node tab)
- Docs link in nav bar → docs.dobprotocol.com/dex/overview

## Strategic Infrastructure

- **AI Agent Economy**: Every protocol layer is designed for autonomous AI agents — Validator agents update oracles, LP Strategy agents manage liquidity, creating a composable agent marketplace.
- **Multi-chain**: Unichain (primary, full V4), Arbitrum (V4), Base & Robinhood (DobDirectSwap fallback), Reactive Network (cross-chain oracle sync).

## Documentation

Comprehensive protocol documentation is hosted at **[docs.dobprotocol.com](https://docs.dobprotocol.com)**. The DobDex section covers:
- **LP-Priced DEX**: How the Uniswap V4 Custom Accounting hook routes sells through Liquidity Nodes
- **Liquidity Nodes**: Permissionless LP system, FIFO fills, and allocation strategies
- **Liquidations**: Distressed asset handling, penalty rates, and LP participation
- **DobPegHook**: Technical deep-dive into the Uniswap V4 hook (NoOp + beforeSwapReturnDelta)

Direct link: [docs.dobprotocol.com/dex/overview](https://docs.dobprotocol.com/dex/overview)

## Deploy Protocol

When user says "deploy", follow these steps:
1. Commit all changes with descriptive message
2. Push to both main and prod: `git push origin main && git push origin main:prod`
3. SSH to prod and pull: `gcloud compute ssh ... --command 'sudo git -C /opt/Dobhooks pull origin prod && sudo systemctl reload nginx'`
4. Verify production: `curl -s -o /dev/null -w "%{http_code}" https://dex.dobprotocol.com/`

The repo lives at `/opt/Dobhooks` on the prod server. Use `sudo git` to pull (permissions).

## Production Server Access

Access to the production server is ONLY for getting logs and uploading files (e.g., media).

```bash
# SSH to prod server
gcloud compute ssh --zone 'us-central1-c' 'dob-platform' --project 'stoked-utility-453816-e2'

# SCP files to prod server
gcloud compute scp <local-file> dob-platform:<remote-path> --zone 'us-central1-c' --project 'stoked-utility-453816-e2'
```

## Tech Stack

- Solidity ^0.8.26, Foundry
- Uniswap V4 (v4-core, v4-periphery, OpenZeppelin uniswap-hooks)
- Solmate (ERC20, Owned, SafeTransferLib, ReentrancyGuard)
- Reactive Network (cross-chain oracle monitoring)
- Frontend: Vanilla HTML/CSS/JS, ethers.js, MetaMask
- API: Node.js, pg (PostgreSQL)
