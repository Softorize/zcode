#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <web_base_url> [github_repo_url] [output_path]" >&2
  exit 1
fi

base_url="$1"
repo_url="${2:-https://github.com/Softorize/zcode}"
output_path="${3:-/tmp/zcode-github-app-manifest.json}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${script_dir}/render_manifest.sh" "$base_url" "$repo_url" > "$output_path"

cat <<EOF
Rendered GitHub App manifest:
  $output_path

Next steps:
1. Open https://github.com/settings/apps/new
2. Upload the rendered manifest JSON
3. Download the generated private key PEM
4. Generate a JWT:
   scripts/github_app/generate_jwt.sh "\$GITHUB_APP_ID" path/to/private-key.pem
5. Exchange for an installation token:
   scripts/github_app/get_installation_token.sh "\$GITHUB_APP_ID" path/to/private-key.pem "\$GITHUB_INSTALLATION_ID"
EOF
