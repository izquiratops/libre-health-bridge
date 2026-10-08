#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 /path/to/LibreHealthBridge.xcresult" >&2
  exit 2
fi

# Export only named screenshots from the synthetic simulator UI tests.
# Do not use a result bundle from a run with real credentials or Health data.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun xcresulttool export attachments --path "$1" --output-path "$tmp" --filter '*.png'
output=$(cd "$(dirname "$0")" && pwd)/screenshots/ui-tests
mkdir -p "$output"
python3 - "$tmp" "$output" <<'PY'
import json
from pathlib import Path
import re
import shutil
import sys

source, dest = map(Path, sys.argv[1:])
for test in json.loads((source / 'manifest.json').read_text()):
    if not test['testIdentifier'].startswith('LibreHealthBridgeUITests/'):
        continue
    for attachment in test['attachments']:
        name = attachment['suggestedHumanReadableName'].split('_0_', 1)[0]
        if not re.fullmatch(r'[a-z0-9-]+', name):
            continue
        file = source / attachment['exportedFileName']
        if file.suffix != '.png' or not file.is_file():
            continue
        shutil.copyfile(file, dest / f'{name}.png')
        print(dest / f'{name}.png')
PY
