#!/usr/bin/env bash
set -euo pipefail

repo="${1:-Softorize/zcode}"
visibility="$(gh api "repos/${repo}" --jq .visibility)"
if [[ "${visibility}" != "public" ]]; then
  echo "Refusing to configure public-only protections: ${repo} is ${visibility}." >&2
  exit 2
fi

gh api --method PUT "repos/${repo}/private-vulnerability-reporting" >/dev/null

gh api --method PATCH "repos/${repo}" --input - >/dev/null <<'JSON'
{
  "delete_branch_on_merge": true,
  "security_and_analysis": {
    "secret_scanning": {"status": "enabled"},
    "secret_scanning_push_protection": {"status": "enabled"}
  }
}
JSON

existing="$(gh api "repos/${repo}/rulesets" --jq '.[] | select(.name == "Protect main") | .id' | head -1)"
if [[ -z "${existing}" ]]; then
  gh api --method POST "repos/${repo}/rulesets" --input - >/dev/null <<'JSON'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true
      }
    }
  ],
  "bypass_actors": []
}
JSON
fi

echo "Configured public OSS protections for ${repo}."
