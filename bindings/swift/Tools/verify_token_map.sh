#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
"${TOKEN_MAP_PYTHON:-python3}" tests/dev/generate_swift_token_map.py --check
