#!/usr/bin/env bash
set -euo pipefail
: "${QRK_PARITY_TOKEN_MAP:?Set QRK_PARITY_TOKEN_MAP to your local prior index; it is never downloaded or bundled.}"
qrk_root="$(cd "$(dirname "$0")/.." && pwd)"
cargo +stable test --manifest-path "$qrk_root/core/Cargo.toml" -p qrk-core corpus::tests::runtime_token_parity -- --exact
