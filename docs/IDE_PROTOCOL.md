# zcode IDE / API Protocol

`zcode api serve` exposes a lightweight JSON-lines protocol over stdio.

Each request is a single JSON object on one line:

```json
{"id":"1","method":"status","params":{}}
```

When API auth is enabled, include an auth object or an Authorization-style
field on each request:

```json
{"id":"1","method":"status","auth":{"bearer":"<token>"},"params":{}}
{"id":"2","method":"run","auth":{"id_token":"<hs256-or-rs256-jwt>"},"params":{"prompt":"summarize repo"}}
```

Each response is a single JSON object on one line:

```json
{"id":"1","ok":true,"result":{"cwd":"/repo","provider":"openai","model":"gpt-4.1"}}
```

## Transport

- command: `zcode api serve`
- encoding: UTF-8 JSON
- framing: one JSON request/response per line
- trust boundary: local child process owned by the editor or wrapper

## Capability Profiles

`ZCODE_API_PROFILE` constrains which methods the stdio server accepts:

- `read-only`: status, registry lists, and session list only.
- `editor`: default for the VS Code extension; enables prompt execution, review, patch apply, and session handoff/import but blocks raw session export.
- `full`: all protocol methods; default when `zcode api serve` is launched directly without an explicit profile.

Integrations should choose the narrowest profile they need and avoid logging raw request or response bodies unless a user explicitly enables debug logging.

`ZCODE_API_ROLE` or `api_role` can further restrict methods by RBAC role:

- `viewer`: status, list, and review-style reads.
- `auditor`: viewer plus raw session export.
- `editor`: prompt execution, patch apply, session import/share/handoff.
- `owner`: all known methods.

Managed config can set `api_profile`, `api_role`, `api_auth_required`,
`api_bearer_token`, and the `api_oidc_*` settings. HS256 uses
`api_oidc_hs256_secret`; RS256 uses a pinned JWKS from
`api_oidc_jwks_json`, `api_oidc_jwks_file`, or `api_oidc_jwks_url`
with a local cache. Environment fallbacks
exist for wrappers: `ZCODE_API_AUTH_REQUIRED`,
`ZCODE_API_BEARER_TOKEN`, `ZCODE_API_OIDC_ISSUER`,
`ZCODE_API_OIDC_AUDIENCE`, `ZCODE_API_OIDC_HS256_SECRET`,
`ZCODE_API_OIDC_JWKS_JSON`, `ZCODE_API_OIDC_JWKS_FILE`, and
`ZCODE_API_OIDC_JWKS_URL`.

## Methods

- `status`
- `run`
- `review`
- `diff.apply`
- `agents.list`
- `plugins.list`
- `commands.list`
- `session.list`
- `session.export`
- `session.share`
- `session.import`
- `session.handoff`

Use `zcode api schema` to print the machine-readable method list.

## Example

```bash
printf '%s\n' \
  '{"id":"1","method":"status","params":{}}' \
  '{"id":"2","method":"run","params":{"prompt":"summarize repo"}}' |
zcode api serve
```

## Intended integrations

- editor extensions
- local desktop wrappers
- CI or daemon-side orchestration
- inline review tools that need `review` output without screen scraping

## Notes

- `session.list` returns both a rendered `output` string and a structured `sessions` array with `id` and `updated_ts`.
- `diff.apply` accepts a unified diff in `params.patch` and routes it through the same git apply path used by the CLI.
