#!/bin/bash
#
# Saves the DHIS2 mapping configured on a running server into the distro, so new installs load it.
#
#   ./scripts/export-dhis2-mapping.sh https://emr.example.org admin
#
# curl asks for the password. The mapping is written to distro/configuration/dhis2/dhis2-mapping.json;
# review it with `git diff` before committing.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <server address, e.g. https://emr.example.org> <username>"
  exit 1
fi

SERVER="${1%/}"
USERNAME="$2"
TARGET="$(cd "$(dirname "$0")/.." && pwd)/distro/configuration/dhis2/dhis2-mapping.json"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

status=$(curl -sS -u "$USERNAME" -H "Accept: application/json" -o "$TMP" -w "%{http_code}" \
  "$SERVER/openmrs/ws/rest/v1/ssemrdhis2/mapping")
if [ "$status" != "200" ]; then
  echo "The server answered HTTP $status. Check the address, the username and password, and that the user may manage DHIS2." >&2
  exit 1
fi

# Pretty-print for readable diffs, and refuse anything that is not a mapping document.
python3 - "$TMP" "$TARGET" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
document = json.load(open(src))
if not isinstance(document, dict) or "dataSets" not in document:
    sys.exit("The response is not a DHIS2 mapping document; nothing was written.")
with open(dst, "w") as out:
    json.dump(document, out, indent=4, ensure_ascii=False)
    out.write("\n")
print(f"Saved {len(document['dataSets'])} data set(s) to {dst}")
PY
