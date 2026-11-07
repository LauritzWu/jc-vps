#!/bin/bash
set -eu
base="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$base/lauritz-duo.py" "$@"
