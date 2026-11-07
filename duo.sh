#!/bin/bash
set -eu
base="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$base/manager.sh" "$@"
