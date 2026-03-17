#!/usr/bin/env bash
# Oracle cron wrapper — updates prices on Unichain Sepolia
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/.env"

export PATH="$HOME/.foundry/bin:$PATH"
export PRIVATE_KEY REGISTRY DCT SFT RET PWG

# ── Unichain Sepolia ──
export RPC_URL="https://sepolia.unichain.org"
export WFT="0xc49cb00bEf4cb10Da2409bdaAbd8F30CBD2468A0"
export GLT="0x2e32C6F887147eEa29e4A1Fc99E8e3fDe1DD2DAB"
export EVT="0xdA68E71D5ab376a7C7752B49C69c42934a6141dd"
export TBT="0x0ac527fBdB2e598c03F5fbE3DF0B7a8a87d7499e"
export FLT="0x3A1D535f9c70808b0C10d4991AD5c8E31188f6C7"
export SCT="0x2c51566D4E0163170eE409Af8946b0D989916Ce0"
"$DIR/script/oracle-updater.sh"
