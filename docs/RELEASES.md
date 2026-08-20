# Release Packaging

`zcode` release packaging is driven from the repository itself.

## What Ships

- Per-platform release binaries:
  - `zcode-linux-x86_64`
  - `zcode-linux-aarch64`
  - `zcode-macos-x86_64`
  - `zcode-macos-aarch64`
- VS Code extension bundle:
  - `zcode-vscode-vX.Y.Z.vsix`
- `SHA256SUMS`
- `update.json`
- `zcode.rb` Homebrew formula artifact
- `install.sh`
- `zcode.intoto.jsonl` SLSA provenance
- `sbom.cdx.json` plus cosign signature/certificate/bundle
- Air-gapped tarballs with fail-closed verification installers
- GitHub artifact attestations for release binaries

## Workflow

- Tag a release as `vX.Y.Z`
- GitHub Actions runs [.github/workflows/release.yml](../.github/workflows/release.yml)
- Matrix builds the release binaries with a plain semantic version via `-Dapp_version_override`
- macOS runners can sign and notarize release binaries when Apple Developer ID and notary secrets are configured
- Release jobs generate GitHub artifact attestations for the shipped binaries
- SBOM generation and signing happen before metadata generation, so
  `SHA256SUMS` covers binaries, binary signatures/certs/bundles,
  provenance, and SBOM artifacts
- Metadata generation writes the manifest consumed by `zcode update` and
  the Homebrew formula consumed by the tap sync step
- Release artifact audit fails the workflow if required signatures,
  provenance, SBOM files, or checksum entries are missing

## Updater

`zcode update` now prefers the stable manifest URL:

- `https://github.com/Softorize/zcode/releases/latest/download/update.json`

You can override this for staging or private mirrors with:

- `ZCODE_UPDATE_MANIFEST_URL`

## Curl Install

Install the latest release with:

```bash
curl -fsSL https://raw.githubusercontent.com/Softorize/zcode/main/install.sh | sh
```

Pin a specific version with:

```bash
ZCODE_VERSION=0.6.37 curl -fsSL https://raw.githubusercontent.com/Softorize/zcode/main/install.sh | sh
```

Enterprise bootstrap can require Sigstore bundle verification during
install:

```bash
curl -fsSL https://raw.githubusercontent.com/Softorize/zcode/main/install.sh \
  | ZCODE_INSTALL_REQUIRE_SIGNATURE=1 sh
```

Without `ZCODE_INSTALL_REQUIRE_SIGNATURE=1`, the installer still verifies
`SHA256SUMS` and opportunistically verifies the Sigstore bundle when
`cosign` is available.

## Homebrew

The release workflow generates `zcode.rb` and can optionally push it to a tap repo when `HOMEBREW_TAP_TOKEN` is configured.

Default tap target:

- `Softorize/homebrew-zcode`

## Provenance Verification

GitHub artifact attestations can be verified with the GitHub CLI:

```bash
gh attestation verify zcode-macos-aarch64 --repo Softorize/zcode
```
