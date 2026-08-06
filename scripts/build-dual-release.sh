#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Dual-release helper — delegates to Docker SDK matrix (23.05 / 24.10 / 25.12 × dual arch).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$ROOT/scripts/smoke-host.sh"
echo "Building all SDK cells (long)..."
"$ROOT/scripts/docker-sdk.sh" build-all
echo "Reproducible verify (x86-64)..."
"$ROOT/scripts/verify-reproducible-build.sh"
echo "Done. Stage feed with ./scripts/publish-packages.sh after setting key env vars."
