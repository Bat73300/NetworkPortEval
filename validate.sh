#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/ModuleCacheNetworkPortEval
swiftc -parse-as-library -module-cache-path "$PWD/.build/ModuleCacheNetworkPortEval" Sources/NetworkPortEval/Core.swift Sources/NetworkPortEval/Language.swift Validation/Smoke.swift -o .build/NetworkPortEvalValidation
.build/NetworkPortEvalValidation
./scripts/test-uninstall-macos.sh
