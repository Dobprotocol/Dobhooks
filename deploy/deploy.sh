#!/usr/bin/env bash
# Deploy DobDex (dex.dobprotocol.com) to the dob-platform EC2.
# Static site (app/) is served by nginx from /opt/Dobhooks/app; the API
# (dobdex-api, :3050) only needs a restart when api/ changed: pass --api.
set -euo pipefail
/home/kai/Escritorio/PROGRAMACION/Admin/operations/scripts/deploy_guard.sh main || exit 1
cd "$(dirname "$0")/.."
git push origin main main:prod
SHA=$(git rev-parse HEAD)
SSH="ssh -i $HOME/.ssh/dob-platform-getorquesta.pem -o BatchMode=yes ubuntu@54.175.80.234"
$SSH "sudo git -C /opt/Dobhooks fetch -q origin prod && sudo git -C /opt/Dobhooks merge --ff-only origin/prod \
  && test \"\$(sudo git -C /opt/Dobhooks rev-parse HEAD)\" = $SHA \
  && echo \"$SHA $(date -u +%Y-%m-%dT%H:%M:%SZ)\" | sudo tee /opt/Dobhooks/REVISION >/dev/null"
if [ "${1:-}" = "--api" ]; then $SSH "sudo systemctl restart dobdex-api"; fi
curl -fsS https://dex.dobprotocol.com/REVISION
