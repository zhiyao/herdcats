#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    printf 'Usage: bash install-openrouter-key.sh APP_NAME KEYCHAIN_SERVICE\n' >&2
    exit 2
fi

review_app=$1
review_service=$2
review_auth=$(mktemp)
review_remote_auth=/data/home/review/.pi/agent/auth.json
review_remote_upload="${review_remote_auth}.upload-$(openssl rand -hex 6)"
trap 'rm -f "$review_auth"' EXIT
chmod 600 "$review_auth"

security find-generic-password -w -a review -s "$review_service" |
    python3 -c 'import json, sys
key = sys.stdin.read().strip()
if not key.startswith("sk-or-"):
    raise SystemExit("Expected an OpenRouter API key in Keychain")
json.dump({"openrouter": {"type": "api_key", "key": key}}, sys.stdout)
' > "$review_auth"

fly sftp put "$review_auth" "$review_remote_upload" \
    --app "$review_app" --user review --mode 0600
fly ssh console --app "$review_app" -C \
    "mv -f $review_remote_upload $review_remote_auth"
fly ssh console --app "$review_app" -C \
    "chown review:review $review_remote_auth"
printf 'OpenRouter key installed for Pi on %s.\n' "$review_app"
