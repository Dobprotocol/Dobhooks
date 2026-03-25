
# Architecture Specifications: Index Wrapper Model

## 1. System Components & Repository Structure

The architecture is split into the **Vault** (handling regulated assets), the **DEX Hook** (routing swaps through Liquidity Nodes), and the **LP system** (providing exit liquidity). The codebase inherits its structure, deployment scripts, and testing utilities directly from the official `uniswapfoundation/v4-template`.

* **`src/DobRwaVault.sol`:** The central depository. Accepts deposits of ERC-20 RWA tokens, queries the Oracle, and mints `dUSDC` (the protocol's USD-pegged stablecoin).
* **`src/DobValidatorRegistry.sol`:** The on-chain Oracle updated by Dobprotocol's AI agents. Maps specific RWA contract addresses to validated USD valuations. Includes price change bounds and emergency controls.
* **`src/DobPegHook.sol`:** The Uniswap V4 Hook. Routes sell swaps through Liquidity Nodes — LPs provide USDC exit liquidity at their chosen discount rate. Uses Custom Accounting (NoOp pattern) to bypass the AMM. Includes slippage protection, LP pool isolation, and pause mechanism.
* **`src/DobLPRegistry.sol`:** Permissionless LP registry for the Liquidity Node. LPs deposit USDC, back specific assets with conditions, and earn discounted RWA tokens.
* **`lib/v4-core` & `lib/v4-periphery`:** Standard Uniswap libraries managed via Foundry, providing the `PoolManager` and routing logic.

## 2. Hook Permissions & Flags (`DobPegHook.sol`)

The hook relies on V4 Custom Accounting (AsyncSwap) to override internal swap logic. Following the `v4-template` deployment patterns, the hook address must be mined with the following flags enabled:

* `beforeInitialize: true` (Admin-only pool creation).
* `beforeAddLiquidity: true` (Admin-only liquidity provision).
* `beforeSwap: true` (Intercepts swap, routes through Liquidity Nodes).
* `beforeSwapReturnDelta: true` (Allows hook to return a custom `BeforeSwapDelta`, skipping V3-style math).

## 3. Execution Path: The Secondary Sale (Atomic Flow)

Because Uniswap V4 utilizes **Flash Accounting** (EIP-1153 Transient Storage), depositing an asset and receiving USDC occurs in a single transaction:

1. **Deposit:** User sends 1 "Datacenter Token" to `DobRwaVault.sol`.
2. **Valuation:** Vault queries `DobValidatorRegistry` (e.g., Datacenter Token = $100,000).
3. **Minting:** Vault mints 100,000 `dUSDC` tokens to the user.
4. **The Hook Intercept:** The Router initiates an exact-input swap on the `PoolManager` to swap 100,000 `dUSDC` for `USDC`.
5. **LP-Priced Exit:**
   * `beforeSwap` triggers. Hook detects a sell (dUSDC → USDC).
   * With `lpOnlyMode` enabled, the hook routes the entire sell to Liquidity Nodes via `queryAndFillAtMarket()`.
   * LPs fill the order at their chosen discount rate (e.g., 3% = 97,000 USDC for 100,000 dUSDC).
   * Hook returns a `BeforeSwapDelta` to the `PoolManager`. AMM execution is skipped.
6. **Settlement:** User receives USDC (minus swap fee + protocol fee + LP discount). LPs receive discounted dUSDC (convertible to RWA tokens).

## 4. Risk & Security Parameters

* **Oracle Staleness & Circuit Breakers:** If the `DobValidatorRegistry` price timestamp exceeds `maxOracleDelay`, minting and swaps are paused.
* **Oracle Price Bounds:** `maxPriceChangeBps` limits how much a price can change per update. `emergencySetPrice()` bypasses the limit for legitimate corrections.
* **Emergency Pause:** All four core contracts (`DobPegHook`, `DobRwaVault`, `DobValidatorRegistry`, `DobLPRegistry`) have `pause()`/`unpause()` functions to halt operations during incidents.
* **LP Pool Isolation:** The permissionless LP pool (swap fee yield) is protected from sell drain. Only protocol-seeded reserves and Liquidity Node LP fills cover sell-side swaps.
* **Slippage Protection:** Sellers can encode `(rwaToken, minAmountOut)` in hookData to revert if the output falls below their minimum.
* **Admin Rotation:** Hook admin is mutable via `transferAdmin()`. Vault, Registry, and LPRegistry use Solmate's `Owned` with `transferOwnership()`.

## 5. Liquidity Node

The Liquidity Node is a permissionless LP marketplace where LPs deposit USDC, back specific RWA assets, and set their own discount terms. LPs participate in two modes:

### Mode 1: Sell Fallback (always-on)

When a seller swaps dUSDC → USDC and the hook's own USDC reserves are insufficient, the shortfall is routed to LPs via `queryAndFillAtMarket()`. Each LP fills at their own `minPenaltyBps` discount rate in FIFO order. **No distress or protocol activation required** — LPs set standing bids and the system fills automatically when needed.

* Seller gets a blended rate from LPs at their discount. With `lpOnlyMode` (default), all USDC comes from LPs.
* LPs receive dUSDC (redeemable for underlying RWA tokens) at their chosen discount.
* The seller passes `abi.encode(rwaTokenAddress, minAmountOut)` as `hookData` to enable LP routing with slippage protection. Legacy format `abi.encode(rwaTokenAddress)` is also supported.

### Mode 2: Liquidation (protocol-activated)

When Dobprotocol flags an asset as distressed, a protocol-mandated penalty rate is applied via `queryAndFill()`. This serves:

1. **Capital provision:** Provides exit liquidity for asset holders, even when the asset is under review.
2. **Risk-priced acquisition:** The discount (e.g., 20%) reflects Dobprotocol's risk assessment — LPs acquire assets at a price that compensates for the assessed risk probability.
3. **Abuse prevention:** Caps limit exposure to any single asset being dumped, and the discount deters attempts to sell valueless assets.

### Risk Assessment as Discount

The `penaltyBps` is not an arbitrary penalty — it reflects Dobprotocol's AI validator assessment of the asset's risk probability. For example, if validators assess a 20% probability of value loss, `penaltyBps = 2000` is set. The seller receives a discounted exit price that reflects the real-world risk, and LPs who accept that risk are compensated with the spread.

### Parameters (set in `DobValidatorRegistry`)

* **`penaltyBps`:** Risk-adjusted discount in basis points (e.g., 2000 = 20% risk). User receives `amountIn × (10000 − penaltyBps) / 10000` USDC.
* **`cap` (per-asset):** Maximum total `dUSDC` that can be liquidated for a given RWA token.
* **`globalLiquidationCap`:** Safety-net cap across all assets combined.

### Discount Destination

The discount portion of `dUSDC` is permanently locked as ERC6909 claims within the hook contract. This effectively removes the tokens from circulation, reducing total `dUSDC` supply and benefiting all remaining holders.

## 6. USDC Sources & LP Pool Isolation

The hook holds two separate pools of USDC:

1. **Protocol Reserves** (`protocolReserveUsdc`): Seeded via `seedUsdc()`, replenished via `redeemUsdcClaims()` (converts ERC6909 USDC claims from buy swaps to real USDC), and grows from protocol fees. **This is the only pool used to cover sell swaps.**
2. **LP Pool** (`totalLpUsdc`): Permissionless USDC deposits via `depositUsdc()`. Grows from swap fees (`swapFeeBps`). **Protected from sell drain — never used to cover swaps.** LPs earn yield from swap fees and can withdraw at any time (after `MIN_LP_DURATION`).

The Liquidity Node (`DobLPRegistry`) is a separate contract with its own USDC pool, used for LP fills on liquidations and sell fallbacks.

## 7. Fee Structure

| Fee | Applied to | Destination | Max |
|-----|-----------|-------------|-----|
| `swapFeeBps` | Normal sells, Resale Market buys | LP Pool (`totalLpUsdc`) | 10% (1000 bps) |
| `protocolFeeBps` | All sells (normal + liquidation), Resale Market buys | Protocol Reserve (`protocolReserveUsdc`) | 5% (500 bps) |
| `PROTOCOL_FEE_BPS` (1.5%) | LP fills (liquidation + sell fallback) | LPRegistry treasury (`accumulatedFees`) | Fixed 150 bps |

## 8. Redeem (dUSDC → USDC)

"Redeem" is functionally a sell swap through the hook (dUSDC → USDC). There is no separate `redeem()` function because it would bypass Uniswap V4's Custom Accounting settlement mechanism. On the UI, the "Redeem" tab performs a standard sell swap routed through Liquidity Nodes. Swap fee, protocol fee, and LP discount apply. On chains without Uniswap V4, `DobDirectSwap` provides the same functionality.

## 9. RWA Resale Market

LPs (or anyone holding RWA tokens) can list them for sale at oracle price via `listRwaForSale()`. Buyers purchase via `buyListedRwa()`, paying USDC at oracle price + swap fee + protocol fee. Sellers receive USDC directly. FIFO fill order, max 50 sellers per token.

## 10. Three LP Systems

| System | Contract | Risk Profile | Returns |
|--------|----------|-------------|---------|
| **LP Pool** (passive) | `DobPegHook.depositUsdc()` | Low — USDC is isolated from sells | Swap fee yield on shares |
| **Liquidity Node** (individual) | `DobLPRegistry.register()` + `backAsset()` | High — USDC used for fills, exposed to RWA | Discounted RWA tokens from liquidation/sell fills |
| **Pooled LN** (shared) | `DobPooledLN.deposit()` | High — same as individual LN, but shared | Proportional share of RWA tokens acquired from fills |

## 11. Pooled Liquidity Node (`DobPooledLN.sol`)

The Pooled LN is a shared USDC vault that acts as a single LP position in the `DobLPRegistry`. Managed by an operator (e.g., Dobprotocol), open for anyone to co-invest.

### How It Works

1. **Anyone deposits USDC** into the pooled LN and receives shares proportional to their contribution.
2. **The operator** (Dobprotocol admin) decides which RWA assets to back and sets the discount rate (`minPenaltyBps`).
3. **When sells or liquidations occur**, the pooled LN fills them like any other LP in the registry — earning discounted RWA tokens.
4. **The operator claims** the earned RWA tokens from the registry and **distributes** them to depositors proportionally.
5. **Depositors withdraw** their RWA tokens (which generate APR via the Token Studio's distribution mechanism).

### Dynamic Discount Updates

The operator can call `updateDiscount(rwaToken, newPenaltyBps)` at any time to change the discount rate for a backed asset. This enables:

* **On-chain data-driven pricing**: Adjust discounts based on oracle price movements, TVL changes, or utilization.
* **Off-chain data-driven pricing**: A keeper bot updates discounts based on external market data, risk assessments, or AI validator signals.
* **Manual adjustments**: Operator sets discounts based on strategic decisions.

The underlying `DobLPRegistry.updateConditions()` handles re-sorting the backer array so the cheapest LPs are always filled first.

### Main LN (Dobprotocol-Managed)

Dobprotocol deploys one `DobPooledLN` instance as the **main Liquidity Node** — the default exit liquidity provider for the DEX. Anyone can deposit USDC into this pool and earn a proportional share of all RWA tokens the LN acquires. Since RWA tokens generate APR (via the Token Studio's `DistributionPool`), depositors effectively earn yield from the underlying real-world assets.

### Multiple Strategies

Multiple `DobPooledLN` instances can coexist, each with a different operator and strategy (e.g., "conservative" with high discount requirements, "aggressive" with low discounts). They all register as independent LPs in the same `DobLPRegistry`.

---
