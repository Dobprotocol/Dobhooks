#!/usr/bin/env bash
# Oracle cron wrapper — updates prices on Arb Sepolia + Robinhood
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/.env"

export PATH="$HOME/.foundry/bin:$PATH"
export PRIVATE_KEY REGISTRY DCT SFT RET PWG

# ── Arb Sepolia ──
export RPC_URL="$ARB_SEPOLIA_RPC"
export WFT="$WFT_ARB" GLT="$GLT_ARB" EVT="$EVT_ARB" TBT="$TBT_ARB" FLT="$FLT_ARB" SCT="$SCT_ARB"
"$DIR/script/oracle-updater.sh"

# ── Robinhood Testnet ──
export RPC_URL="$ROBINHOOD_RPC"
export WFT="$WFT_RH" GLT="$GLT_RH" EVT="$EVT_RH" TBT="$TBT_RH" FLT="$FLT_RH" SCT="$SCT_RH"
"$DIR/script/oracle-updater.sh"
