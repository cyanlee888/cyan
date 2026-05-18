#!/usr/bin/env bash
# Verifies gcloud + Stitch MCP proxy prerequisites. Run from repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v gcloud &>/dev/null; then
  echo "Install Google Cloud SDK first: https://cloud.google.com/sdk/docs/install"
  exit 1
fi

echo "Current gcloud project:"
gcloud config get-value project 2>/dev/null || true
echo ""
echo "Running stitch-mcp doctor (needs network)..."
exec npx -y @_davideast/stitch-mcp doctor --verbose
