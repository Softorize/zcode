#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app_id> <private_key_pem>" >&2
  exit 1
fi

app_id="$1"
key_file="$2"
now="$(date +%s)"
iat="$((now - 60))"
exp="$((now + 540))"

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

header='{"alg":"RS256","typ":"JWT"}'
payload="{\"iat\":${iat},\"exp\":${exp},\"iss\":\"${app_id}\"}"

header_b64="$(printf '%s' "$header" | base64url)"
payload_b64="$(printf '%s' "$payload" | base64url)"
signing_input="${header_b64}.${payload_b64}"
signature_b64="$(printf '%s' "$signing_input" | openssl dgst -binary -sha256 -sign "$key_file" | base64url)"

printf '%s.%s\n' "$signing_input" "$signature_b64"
