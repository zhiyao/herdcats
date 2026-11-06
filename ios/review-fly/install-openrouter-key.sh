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
# Fly runs -C without a shell, so invoke /bin/sh explicitly. The script below
# contains no single quotes, so it can be wrapped in one safely.
review_remote_script="set -eu
for p in /data/home/review /data/home/review/.pi /data/home/review/.pi/agent \"$review_remote_upload\" \"$review_remote_auth\"; do
    if [ -L \"\$p\" ]; then
        echo \"Refusing symlink: \$p\" >&2
        exit 1
    fi
done
runuser -u review -- mv -f \"$review_remote_upload\" \"$review_remote_auth\""
fly ssh console --app "$review_app" -C "/bin/sh -c '$review_remote_script'"
printf 'OpenRouter key installed for Pi on %s.\n' "$review_app"
