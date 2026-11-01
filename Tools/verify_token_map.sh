#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
"${TOKEN_MAP_PYTHON:-python3}" Tools/generate_token_map.py --check
