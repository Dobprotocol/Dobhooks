#!/usr/bin/env bash
# -────────────────────────────────────────────────────────────────
# Dobprotocol Oracle Updater
# Periodically updates RWA oracle prices with asset-type volatility.
#
# Each asset class has different volatility characteristics:
#   DCT (Datacenter)  - Low volatility, steady revenue (+-2%)
#   SFT (Solar Farm)  - Medium volatility, seasonal (+-5%)
#   RET (Real Estate) - Very low volatility, stable (+-1%)
#   PWG (Power Grid)  - Low-medium volatility (+-3%)
#   WFT (Wind Farm)   - Medium volatility, wind variability (+-4%)
#   GLT (Gold Reserve) - Low-medium, gold correlation (+-3%)
#   EVT (EV Fleet)    - High volatility, EV market (+-6%)
#   TBT (Treasury Bond)- Very low volatility, stable (+-1%)
#   FLT (Farmland)    - Low volatility, stable asset (+-2%)
#   SCT (Shipping)    - Medium volatility, cyclical (+-5%)
#
# Usage:
#   source ../.env
#   export RPC_URL=$ARB_SEPOLIA_RPC
#   export DCT=$DCT SFT=$SFT RET=$RET PWG=$PWG
#   export WFT=$WFT_ARB GLT=$GLT_ARB EVT=$EVT_ARB TBT=$TBT_ARB FLT=$FLT_ARB SCT=$SCT_ARB
#   ./oracle-updater.sh              # single update
#   ./oracle-updater.sh --loop 60    # update every 60 seconds
# -────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ──
RPC_URL="${RPC_URL:?Set RPC_URL}"
PRIVATE_KEY="${PRIVATE_KEY:?Set PRIVATE_KEY}"
REGISTRY="${REGISTRY:?Set REGISTRY address}"
DCT="${DCT:?Set DCT address}"
SFT="${SFT:?Set SFT address}"
RET="${RET:?Set RET address}"
PWG="${PWG:?Set PWG address}"
WFT="${WFT:-}"
GLT="${GLT:-}"
EVT="${EVT:-}"
TBT="${TBT:-}"
FLT="${FLT:-}"
SCT="${SCT:-}"

# Base prices (USD per token)
DCT_BASE=100    # $100
SFT_BASE=50     # $50
RET_BASE=250    # $250
PWG_BASE=75     # $75
WFT_BASE=180    # $180
GLT_BASE=62     # $62
EVT_BASE=42     # $42
TBT_BASE=10     # $10
FLT_BASE=85     # $85
SCT_BASE=28     # $28

# Volatility (max % deviation from base)
DCT_VOL=2    # +-2% — steady datacenter revenue
SFT_VOL=5    # +-5% — seasonal solar output
RET_VOL=1    # +-1% — stable real estate
PWG_VOL=3    # +-3% — moderate grid fluctuation
WFT_VOL=4    # +-4% — wind variability
GLT_VOL=3    # +-3% — gold price correlation
EVT_VOL=6    # +-6% — EV market volatility
TBT_VOL=1    # +-1% — treasury bond stability
FLT_VOL=2    # +-2% — farmland stable
SCT_VOL=5    # +-5% — shipping market cyclical

# ── Helpers ──
random_delta() {
  local vol=$1
  # Generate random number between -vol and +vol (integer %)
  local range=$((vol * 2 + 1))
  local raw=$(( RANDOM % range - vol ))
  echo "$raw"
}

to_18dec() {
  # Convert integer USD to 18-decimal wei string
  local usd=$1
  echo "${usd}000000000000000000"
}

update_price() {
  local name=$1 token=$2 base=$3 vol=$4
  local delta
  delta=$(random_delta "$vol")
  local price=$(( base + (base * delta / 100) ))

  # Ensure price is positive
  if [ "$price" -le 0 ]; then
    price=$base
  fi

  local price_wei
  price_wei=$(to_18dec "$price")

  echo "  $name: \$$price (${delta:+$delta}% from \$$base)"

  cast send "$REGISTRY" \
    "setPrice(address,uint256)" \
    "$token" "$price_wei" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --silent 2>/dev/null || echo "    [WARN] Failed to update $name"
}

do_update() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] Oracle update:"

  update_price "DCT (Datacenter)" "$DCT" "$DCT_BASE" "$DCT_VOL"
  update_price "SFT (Solar Farm)" "$SFT" "$SFT_BASE" "$SFT_VOL"
  update_price "RET (Real Estate)" "$RET" "$RET_BASE" "$RET_VOL"
  update_price "PWG (Power Grid)" "$PWG" "$PWG_BASE" "$PWG_VOL"
  [ -n "$WFT" ] && update_price "WFT (Wind Farm)" "$WFT" "$WFT_BASE" "$WFT_VOL"
  [ -n "$GLT" ] && update_price "GLT (Gold Reserve)" "$GLT" "$GLT_BASE" "$GLT_VOL"
  [ -n "$EVT" ] && update_price "EVT (EV Fleet)" "$EVT" "$EVT_BASE" "$EVT_VOL"
  [ -n "$TBT" ] && update_price "TBT (Treasury Bond)" "$TBT" "$TBT_BASE" "$TBT_VOL"
  [ -n "$FLT" ] && update_price "FLT (Farmland)" "$FLT" "$FLT_BASE" "$FLT_VOL"
  [ -n "$SCT" ] && update_price "SCT (Shipping)" "$SCT" "$SCT_BASE" "$SCT_VOL"

  echo ""
}

# ── Main ──
if [ "${1:-}" = "--loop" ]; then
  INTERVAL="${2:-60}"
  echo "Oracle updater running every ${INTERVAL}s (Ctrl+C to stop)"
  echo "Registry: $REGISTRY"
  echo ""
  while true; do
    do_update
    sleep "$INTERVAL"
  done
else
  echo "Oracle single update"
  echo "Registry: $REGISTRY"
  echo ""
  do_update
fi
