#!/bin/bash
# Deploy DobDex to production server
# Usage: ./deploy.sh

set -e

echo "Deploying Dobhooks to dex.dobprotocol.com..."
gcloud compute ssh --zone "us-central1-c" "dob-platform" --project "stoked-utility-453816-e2" -- "cd /opt/Dobhooks && sudo git pull origin main"
echo "Done! Live at https://dex.dobprotocol.com"
