#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Separate experimental App Sandbox build. It intentionally starts with only
# the network-client entitlement; add no further entitlement before testing.
export APP_BUNDLE_NAME="NetworkPortEval-MAS"
export APP_BUNDLE_ID="com.networkporteval.desktop.mas"
export APP_SHORT_VERSION="0.1.0"
export APP_BUILD_VERSION="8"
export APP_ENTITLEMENTS="$PWD/Entitlements/MacAppStore.entitlements"

exec ./build-app.sh
