#!/usr/bin/env bash
# Oracle cron wrapper — updates prices on Unichain Sepolia
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/.env"

export PATH="$HOME/.foundry/bin:$PATH"
export PRIVATE_KEY

# ── Unichain Sepolia (override .env Arbitrum addresses) ──
export RPC_URL="https://sepolia.unichain.org"
export REGISTRY="0x652E5572aF3a879D591a4DD289566bcF28BeA52B"
export DCT="0x9E1aeb6c2f8f17C372D62ECe44792818d8BFb97a"
export SFT="0x1784CD059E11D3d8eBf25b5daaC183614F772bC0"
export RET="0xde66Fd2575B92f62b0bcD2F976ea6398C3D06551"
export PWG="0x1dcB1e529869173AB35064B45e35B26aEdc1B475"
export WFT="0xB48eeFa4Dc3fc9D32E16Ab74cC8f67D220cd33a5"
export GLT="0x9A46d60CD009150dF71764dA7FadCc1628d6a46A"
export EVT="0x3a1f86B027fDC57558178F066609c8ec039cD457"
export TBT="0x6a7D84C6f7908132371ed28Bed8f1530E5341D44"
export FLT="0x6C5A6a2294f4680f54Ac76843D22BA806c7d108a"
export SCT="0xF8D2691F646de6E0E61131C907D2E326Ab3aDa92"
"$DIR/script/oracle-updater.sh"
