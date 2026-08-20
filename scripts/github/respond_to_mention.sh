#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

BIN="${ZCODE_BIN:-./zig-out/bin/zcode}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
REPO_FULL="${GITHUB_REPOSITORY:-}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
DRY_RUN="${ZCODE_GITHUB_DRY_RUN:-}"

if [[ ! -x "${BIN}" ]]; then
  zig build -Doptimize=ReleaseSafe
fi

if [[ -z "${EVENT_PATH}" || ! -f "${EVENT_PATH}" ]]; then
  echo "GITHUB_EVENT_PATH is required" >&2
  exit 1
fi

if [[ -z "${EVENT_NAME}" ]]; then
  echo "GITHUB_EVENT_NAME is required" >&2
  exit 1
fi

if [[ -z "${REPO_FULL}" ]]; then
  echo "GITHUB_REPOSITORY is required" >&2
  exit 1
fi

eval "$(python3 - "${EVENT_PATH}" "${EVENT_NAME}" "${REPO_FULL}" <<'PY'
import json, re, shlex, sys

path, event_name, repo_full = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

comment = data.get("comment", {}) or {}
issue = data.get("issue", {}) or {}
pull_request = data.get("pull_request", {}) or {}
comment_body = comment.get("body", "") or ""
comment_author = ((comment.get("user") or {}).get("login", "")) or ""
issue_title = issue.get("title", "") or ""
issue_body = issue.get("body", "") or ""
issue_number = str(issue.get("number", "") or "")
comment_id = str(comment.get("id", "") or "")
pr_number = str((pull_request.get("number") or issue.get("number") or "")) or ""
base_ref = pull_request.get("base", {}).get("ref", "") or ""
head_ref = pull_request.get("head", {}).get("ref", "") or ""

triggered = bool(re.search(r"(^|\s)(@zcode|/zcode)\b", comment_body, flags=re.IGNORECASE))
if comment_author in {"github-actions[bot]", "dependabot[bot]"}:
    triggered = False

clean = re.sub(r"(^|\s)(@zcode|/zcode)\b[: ]*", " ", comment_body, flags=re.IGNORECASE)
clean = re.sub(r"\n{3,}", "\n\n", clean).strip()
if not clean:
    clean = "Respond to the latest GitHub comment with the most helpful next step for this repository."

is_pr_issue_comment = bool(issue.get("pull_request"))
is_review_comment = event_name == "pull_request_review_comment"
reply_mode = "review_comment" if is_review_comment else "issue_comment"

if is_review_comment:
    prompt = f"""You are zcode responding to a GitHub pull request review comment.

Keep the reply concise, direct, and actionable.
If the comment asks for a code change, explain the concrete fix or next step.
If more context is needed, say exactly what is missing.

Repository: {repo_full}
Pull request: #{pr_number}
Base branch: {base_ref or "unknown"}
Head branch: {head_ref or "unknown"}
Comment author: @{comment_author}

Reviewer comment:
{clean}
"""
elif is_pr_issue_comment:
    prompt = f"""You are zcode responding to a GitHub pull request conversation comment.

Keep the reply concise, direct, and actionable.
Use the checked-out repository context when relevant.

Repository: {repo_full}
Pull request: #{issue_number}
Comment author: @{comment_author}

Comment:
{clean}
"""
else:
    prompt = f"""You are zcode responding to a GitHub issue comment.

Keep the reply concise, direct, and actionable.
If the issue is missing information, call that out explicitly.

Repository: {repo_full}
Issue: #{issue_number} {issue_title}
Comment author: @{comment_author}

Issue body:
{issue_body}

Comment:
{clean}
"""

def emit(name: str, value: str) -> None:
    print(f"{name}={shlex.quote(value)}")

emit("ZCODE_TRIGGERED", "1" if triggered else "0")
emit("ZCODE_COMMENT_AUTHOR", comment_author)
emit("ZCODE_REPLY_MODE", reply_mode)
emit("ZCODE_PROMPT", prompt)
emit("ZCODE_ISSUE_NUMBER", issue_number)
emit("ZCODE_PR_NUMBER", pr_number)
emit("ZCODE_COMMENT_ID", comment_id)
PY
)"

if [[ "${ZCODE_TRIGGERED}" != "1" ]]; then
  echo "No @zcode or /zcode trigger found; nothing to do."
  exit 0
fi

if [[ -z "${ZCODE_COMMENT_AUTHOR}" ]]; then
  echo "Comment author is required" >&2
  exit 1
fi

cmd=("${BIN}")
if [[ -n "${ZCODE_PROVIDER:-}" ]]; then
  cmd+=(--provider "${ZCODE_PROVIDER}")
fi
if [[ -n "${ZCODE_MODEL:-}" ]]; then
  cmd+=(--model "${ZCODE_MODEL}")
fi
if [[ -n "${ZCODE_AGENT:-}" ]]; then
  cmd+=(--agent "${ZCODE_AGENT}")
fi

response="$("${cmd[@]}" run "${ZCODE_PROMPT}")"
reply_body="<!-- zcode-mention -->"$'\n'"@${ZCODE_COMMENT_AUTHOR}"$'\n\n'"${response}"

if [[ -n "${DRY_RUN}" ]]; then
  printf '%s\n' "${reply_body}"
  exit 0
fi

if [[ -z "${GH_TOKEN}" ]]; then
  echo "GH_TOKEN or GITHUB_TOKEN is required" >&2
  exit 1
fi

owner="${REPO_FULL%%/*}"
repo="${REPO_FULL#*/}"

if [[ "${ZCODE_REPLY_MODE}" == "review_comment" ]]; then
  gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    "repos/${owner}/${repo}/pulls/${ZCODE_PR_NUMBER}/comments/${ZCODE_COMMENT_ID}/replies" \
    -f body="${reply_body}" >/dev/null
else
  gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    "repos/${owner}/${repo}/issues/${ZCODE_ISSUE_NUMBER}/comments" \
    -f body="${reply_body}" >/dev/null
fi

printf 'Posted zcode reply for %s by @%s\n' "${ZCODE_REPLY_MODE}" "${ZCODE_COMMENT_AUTHOR}"
