
# Architecture Specifications: Index Wrapper Model

## 1. System Components & Repository Structure

The architecture is split into the **Vault** (handling regulated assets) and the **DEX Hook** (handling liquid trades). The codebase inherits its structure, deployment scripts, and testing utilities directly from the official `uniswapfoundation/v4-template`.

* **`src/DobRwaVault.sol`:** The central depository. Accepts deposits of ERC-3643 tokens, queries the Oracle, and mints `dobRWA`.
* **`src/DobValidatorRegistry.sol`:** The on-chain Oracle updated by Dobprotocol's AI agents. Maps specific RWA contract addresses to validated USD valuations.
* **`src/DobPegHook.sol`:** The Uniswap V4 Hook. Manages custom accounting to ensure swaps execute exactly at the peg defined by the Vault's collateral.
* **`lib/v4-core` & `lib/v4-periphery`:** Standard Uniswap libraries managed via Foundry, providing the `PoolManager` and routing logic.

## 2. Hook Permissions & Flags (`DobPegHook.sol`)

The hook relies on V4 Custom Accounting (AsyncSwap) to override internal swap logic. Following the `v4-template` deployment patterns, the hook address must be mined with the following flags enabled:

* `beforeInitialize: true` (Admin-only pool creation).
* `beforeAddLiquidity: true` (Enforces KYC/AML whitelisting for LPs).
* `beforeSwap: true` (Intercepts swap for Oracle valuation).
* `beforeSwapReturnDelta: true` (Allows hook to return a custom `BeforeSwapDelta`, skipping V3-style math).

## 3. Execution Path: The Secondary Sale (Atomic Flow)

Because Uniswap V4 utilizes **Flash Accounting** (EIP-1153 Transient Storage), depositing an asset and receiving USDC occurs in a single transaction:

1. **Deposit:** User sends 1 "Datacenter Token" to `DobRwaVault.sol`.
2. **Valuation:** Vault queries `DobValidatorRegistry` (e.g., Datacenter Token = $100,000).
3. **Minting:** Vault mints 100,000 `dobRWA` tokens to the user.
4. **The Hook Intercept:** The Router initiates an exact-input swap on the `PoolManager` to swap 100,000 `dobRWA` for `USDC`.
5. **Custom Accounting:** * `beforeSwap` triggers.
* Hook intercepts the 100,000 `dobRWA`.
* Hook returns a `BeforeSwapDelta` to the `PoolManager` indicating exactly 100,000 `USDC` is owed to the user.
* `PoolManager` skips standard AMM execution.


6. **Settlement:** User receives 100,000 `USDC`.

## 4. Risk & Security Parameters

* **ERC-3643 Compliance Enforcement:** `DobRwaVault` integrates with decentralized identity registries (like ONCHAINID) to reject unauthorized deposits.
* **Oracle Staleness & Circuit Breakers:** If the `DobValidatorRegistry` price timestamp exceeds `MAX_ORACLE_DELAY`, minting is paused.
* **Vault Concentration Limits:** The Vault tracks RWA category values. Deposits pushing a single asset class past a max threshold (e.g., >30% TVL) are rejected to maintain index diversification.

## 5. Liquidation Node

The Liquidity Node mechanism allows distressed or flagged RWA assets to be liquidated at a risk-adjusted discount, subject to configurable caps. This serves three purposes:

1. **Capital provision:** Provides exit liquidity for asset holders, even when the asset is under review.
2. **Risk-priced acquisition:** The discount (e.g., 20%) reflects Dobprotocol's risk assessment — LPs acquire assets at a price that compensates for the assessed risk probability.
3. **Abuse prevention:** Caps limit exposure to any single asset being dumped, and the discount deters attempts to sell valueless assets.

### Risk Assessment as Discount

The `penaltyBps` is not an arbitrary penalty — it reflects Dobprotocol's AI validator assessment of the asset's risk probability. For example, if validators assess a 20% probability of value loss, `penaltyBps = 2000` is set. The seller receives a discounted exit price that reflects the real-world risk, and LPs who accept that risk are compensated with the spread.

### Parameters (set in `DobValidatorRegistry`)

* **`penaltyBps`:** Risk-adjusted discount in basis points (e.g., 2000 = 20% risk). User receives `amountIn × (10000 − penaltyBps) / 10000` USDC.
* **`cap` (per-asset):** Maximum total `dobRWA` that can be liquidated for a given RWA token.
* **`globalLiquidationCap`:** Safety-net cap across all assets combined.

### Discount Destination

The discount portion of `dobRWA` is permanently locked as ERC6909 claims within the hook contract. This effectively removes the tokens from circulation, reducing total `dobRWA` supply and benefiting all remaining holders.

### Activation

Liquidation mode is triggered by passing `abi.encode(rwaTokenAddress)` as `hookData` in the swap call. Without `hookData`, swaps execute at the normal 1:1 peg regardless of liquidation status.

### USDC Source

In normal mode (no liquidation), USDC for swaps comes from the hook's own reserves (seeded by the protocol via `seedUsdc()`). In liquidation mode, USDC comes from Liquidity Node LPs who have backed the distressed asset and whose conditions match the current risk assessment.

---

