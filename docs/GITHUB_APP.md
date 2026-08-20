# zcode GitHub App

`zcode` now ships GitHub App scaffolding so you can move from comment-triggered Actions to an installed App identity.

Included assets:

- manifest template: `.github/github-app-manifest.json`
- manifest renderer: `scripts/github_app/render_manifest.sh`
- onboarding helper: `scripts/github_app/onboard.sh`
- JWT helper: `scripts/github_app/generate_jwt.sh`
- installation token helper: `scripts/github_app/get_installation_token.sh`
- branch push helper: `scripts/github_app/push_branch_with_app.sh`
- PR creation helper: `scripts/github_app/create_pr_with_app.sh`

## Bootstrap flow

1. Render a manifest with your actual web base URL:

```bash
scripts/github_app/render_manifest.sh https://zcode.example.com > /tmp/zcode-github-app.json
```

Or use the guided helper:

```bash
scripts/github_app/onboard.sh https://zcode.example.com
```

2. Create the App from the rendered manifest JSON
3. Download the App private key PEM
4. Generate a JWT:

```bash
scripts/github_app/generate_jwt.sh "$GITHUB_APP_ID" path/to/private-key.pem
```

5. Exchange for an installation token:

```bash
scripts/github_app/get_installation_token.sh "$GITHUB_APP_ID" path/to/private-key.pem "$GITHUB_INSTALLATION_ID"
```

6. Export the token and use the branch/PR helpers:

```bash
export GITHUB_TOKEN=...
scripts/github_app/push_branch_with_app.sh Softorize/zcode my-branch
scripts/github_app/create_pr_with_app.sh Softorize/zcode my-branch main "zcode update" "Automated change from zcode"
```

## Notes

- The helpers are intentionally plain shell so they work in CI, local ops, and container jobs.
- `push_branch_with_app.sh` pushes directly to the authenticated HTTPS URL and does not rewrite your local git remotes.
