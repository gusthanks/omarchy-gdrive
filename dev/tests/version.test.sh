#!/usr/bin/env bash
# The version is written in three places: manifest.json, the CLI
# (lib/common.sh) and the top entry of CHANGELOG.md. They must agree.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest=$(jq -r .version "$repo/manifest.json")
cli=$(sed -n 's/^: "${CLI_VERSION:=\(.*\)}"$/\1/p' "$repo/lib/common.sh")
changelog=$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' "$repo/CHANGELOG.md" | head -n 1)
[[ -n $manifest && $manifest == "$cli" && $manifest == "$changelog" ]] || {
  echo "FAIL: version mismatch: manifest.json=$manifest lib/common.sh=$cli CHANGELOG.md=$changelog" >&2
  exit 1
}
echo "ok - version $manifest in manifest.json, the CLI and CHANGELOG.md"
