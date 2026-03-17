# DOBVALIDATOR Oracle Integration Prompt

## Context

DobDex uses `DobValidatorRegistry` (on-chain oracle) to store USD prices for each validated RWA token. Currently, prices are updated via a bash cron script (`oracle-updater.sh`) with simulated volatility. The goal is to replace this with **real price updates from DOBVALIDATOR** — whenever the validator AI agent assesses or re-assesses an asset, it should push the price on-chain via `setPrice()`.

## What You Need to Build

Add an **oracle price update service** to the DOBVALIDATOR backend that:

1. **On certificate issuance** (after `APPROVED` + certificate generated): calls `DobValidatorRegistry.setPrice(tokenAddress, priceUsd)` on-chain for every network where the asset's participation token is deployed.

2. **On periodic re-assessment** (cron or triggered): re-evaluates asset prices based on the submission's `currentValue`, market conditions, and TRUFA scores, then updates on-chain.

3. **Exposes an internal API endpoint** for manual oracle updates by admin.

## DobValidatorRegistry Contract

Deployed on:
- **Arbitrum Sepolia (421614)**: `0x686C24BD17Ff53Ed76b693CA69135e161C55af99`
- **Robinhood Testnet (46630)**: `0x686C24BD17Ff53Ed76b693CA69135e161C55af99`

### ABI (only what you need)

```solidity
// Set or update the USD price for an RWA token (onlyOwner)
function setPrice(address token, uint256 priceUsd) external;

// Read current price
function getPrice(address token) external view returns (uint256 priceUsd, uint48 updatedAt);
```

- `priceUsd` is an **18-decimal** uint256. For example, $100 = `100000000000000000000` (100 * 1e18).
- `setPrice` is restricted to the contract owner. The caller must be the deployer wallet.
- `token` is the ERC-20 address of the RWA participation token (from MVP's `pools.participation_token_address`).

## Data Flow

```
DOBVALIDATOR                                          DobDex (on-chain)
    |                                                       |
    |  1. Admin approves submission                         |
    |  2. Certificate generated (certificateHash)           |
    |  3. MVP links certificate to pool                     |
    |     (pool.validator_certificate_hash = hash)          |
    |     (pool.is_verified = true)                         |
    |  4. Get token address from MVP pool                   |
    |     (pool.participation_token_address)                |
    |  5. Calculate price from submission data               |
    |     (currentValue, expectedRevenue, scores)           |
    |  6. Call setPrice(tokenAddress, priceUsd18)   ------> |  DobValidatorRegistry
    |                                                       |
```

## How to Get Token Addresses

Query the MVP database (same connection you already use for cross-platform integration):

```sql
SELECT
  p.participation_token_address,
  p.network_id,
  p.validator_certificate_hash,
  t.symbol,
  n.chain
FROM pools p
JOIN tokens t ON p.token_id = t.id
JOIN networks n ON p.network_id = n.id
WHERE p.validator_certificate_hash = $1
  AND p.participation_token_address IS NOT NULL
```

This returns the token address for each network where the asset is deployed.

## Implementation Guide

### 1. Create `backend/src/lib/oracle-service.ts`

```typescript
import { ethers } from 'ethers';

const REGISTRY_ABI = [
  'function setPrice(address token, uint256 priceUsd) external',
  'function getPrice(address token) external view returns (uint256 priceUsd, uint48 updatedAt)',
];

// DobValidatorRegistry address (same on all chains)
const REGISTRY_ADDRESS = '0x686C24BD17Ff53Ed76b693CA69135e161C55af99';

// RPC endpoints for each chain
const RPC_URLS: Record<number, string> = {
  421614: process.env.ARB_SEPOLIA_RPC || 'https://sepolia-rollup.arbitrum.io/rpc',
  46630: process.env.ROBINHOOD_RPC || 'https://rpc.testnet.chain.robinhood.com',
};

export class OracleService {
  private wallet: ethers.Wallet;

  constructor() {
    const pk = process.env.ORACLE_PRIVATE_KEY;
    if (!pk) throw new Error('ORACLE_PRIVATE_KEY not set');
    // Wallet will be connected to provider per-call
    this.wallet = new ethers.Wallet(pk);
  }

  /**
   * Update the oracle price for a token on a specific chain.
   * @param chainId - Network ID (421614 for Arb Sepolia, 46630 for Robinhood)
   * @param tokenAddress - ERC-20 address of the RWA participation token
   * @param priceUsd - Price in USD (as a regular number, e.g. 100.50)
   */
  async setPrice(chainId: number, tokenAddress: string, priceUsd: number): Promise<string> {
    const rpc = RPC_URLS[chainId];
    if (!rpc) throw new Error(`No RPC configured for chain ${chainId}`);

    const provider = new ethers.JsonRpcProvider(rpc);
    const signer = this.wallet.connect(provider);
    const registry = new ethers.Contract(REGISTRY_ADDRESS, REGISTRY_ABI, signer);

    // Convert USD price to 18-decimal format
    const priceWei = ethers.parseUnits(priceUsd.toFixed(18), 18);

    const tx = await registry.setPrice(tokenAddress, priceWei);
    const receipt = await tx.wait();

    console.log(`[ORACLE] Price updated: ${tokenAddress} = $${priceUsd} on chain ${chainId} (tx: ${receipt.hash})`);
    return receipt.hash;
  }

  /**
   * Calculate asset price from submission data.
   * This is where the AI valuation logic goes.
   */
  calculatePrice(submission: {
    currentValue: string;
    expectedRevenue: string;
    purchasePrice: string;
    overallScore?: number;
  }): number {
    const currentValue = parseFloat(submission.currentValue) || 0;
    const expectedRevenue = parseFloat(submission.expectedRevenue) || 0;
    const purchasePrice = parseFloat(submission.purchasePrice) || 0;

    // Base price = current assessed value
    let price = currentValue;

    // If no current value, fall back to purchase price
    if (price <= 0) price = purchasePrice;

    // Apply score-based multiplier (higher score = closer to full value)
    if (submission.overallScore) {
      const scoreMultiplier = submission.overallScore / 100; // 0.0 to 1.0
      price = price * (0.7 + 0.3 * scoreMultiplier); // 70%-100% of value based on score
    }

    return Math.max(price, 0.01); // Never return zero
  }

  /**
   * Update prices for all tokens linked to a certificate.
   * Called after certificate issuance.
   */
  async updatePricesForCertificate(
    certificateHash: string,
    submission: { currentValue: string; expectedRevenue: string; purchasePrice: string },
    overallScore: number,
    mvpDb: any // Your MVP database connection
  ): Promise<void> {
    const price = this.calculatePrice({ ...submission, overallScore });

    // Get token addresses from MVP DB
    const result = await mvpDb.query(`
      SELECT p.participation_token_address, p.network_id
      FROM pools p
      WHERE p.validator_certificate_hash = $1
        AND p.participation_token_address IS NOT NULL
    `, [certificateHash]);

    for (const row of result.rows) {
      try {
        await this.setPrice(row.network_id, row.participation_token_address, price);
      } catch (err) {
        console.error(`[ORACLE] Failed to update price on chain ${row.network_id}:`, err);
      }
    }
  }
}

export const oracleService = new OracleService();
```

### 2. Hook Into Certificate Generation

In `backend/src/lib/certificate-service.ts`, after successful certificate generation, trigger the oracle update:

```typescript
// After certificate is saved to DB and PDF generated...
// Add this at the end of generateAndSendCertificate():

try {
  const { oracleService } = await import('./oracle-service');
  await oracleService.updatePricesForCertificate(
    certificate.certificateHash,
    {
      currentValue: submission.currentValue,
      expectedRevenue: submission.expectedRevenue,
      purchasePrice: submission.purchasePrice,
    },
    certificate.overallScore || 0,
    mvpDb // Your MVP database pool
  );
} catch (oracleErr) {
  // Don't fail certificate generation if oracle update fails
  console.error('[ORACLE] Post-certification price update failed:', oracleErr);
}
```

### 3. Add Admin Oracle Endpoint

In `backend/src/routes/admin.ts` or a new `oracle.ts` route:

```typescript
// POST /api/admin/oracle/update-price
router.post('/oracle/update-price', adminMiddleware, async (req, res) => {
  const { chainId, tokenAddress, priceUsd } = req.body;

  if (!chainId || !tokenAddress || !priceUsd) {
    return res.status(400).json({ error: 'chainId, tokenAddress, priceUsd required' });
  }

  try {
    const txHash = await oracleService.setPrice(chainId, tokenAddress, priceUsd);
    return res.json({ success: true, txHash });
  } catch (err) {
    return res.status(500).json({ error: (err as Error).message });
  }
});

// POST /api/admin/oracle/update-all
// Re-assess and update all verified pools
router.post('/oracle/update-all', adminMiddleware, async (req, res) => {
  // Query all verified pools from MVP DB, recalculate prices, update on-chain
  // ... implementation
});
```

### 4. Environment Variables

Add to `backend/.env`:

```
# Oracle updater wallet (must be the DobValidatorRegistry owner)
ORACLE_PRIVATE_KEY=0x...

# RPC endpoints
ARB_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
ROBINHOOD_RPC=https://rpc.testnet.chain.robinhood.com

# MVP DB (for cross-platform queries)
MVP_DB_HOST=localhost
MVP_DB_PORT=5435
MVP_DB_NAME=dob-prod
MVP_DB_USER=...
MVP_DB_PASS=...
```

### 5. Dependencies

```bash
pnpm add ethers
```

## Important Notes

- The `ORACLE_PRIVATE_KEY` must be the owner of `DobValidatorRegistry`. Currently it's the deployer wallet.
- Price updates cost gas. Each `setPrice` call costs ~50k gas on Arb Sepolia.
- The oracle has a `MAX_ORACLE_DELAY` of 1 day. Prices older than 24h are marked stale in the DobDex UI.
- For production, consider a dedicated oracle wallet with limited funds, topped up periodically.
- The `calculatePrice()` function is a starting point. Replace with your AI valuation model.
- Fire-and-forget pattern: oracle updates should never block certificate generation.

## Testing

```bash
# Test manual price update via cast (Foundry)
cast send 0x686C24BD17Ff53Ed76b693CA69135e161C55af99 \
  "setPrice(address,uint256)" \
  <TOKEN_ADDRESS> \
  $(cast --to-wei 100) \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key $PRIVATE_KEY

# Verify price was set
cast call 0x686C24BD17Ff53Ed76b693CA69135e161C55af99 \
  "getPrice(address)(uint256,uint48)" \
  <TOKEN_ADDRESS> \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc
```
