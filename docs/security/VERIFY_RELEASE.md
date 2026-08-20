# Verifying a zcode release

Every tagged zcode release ships with two independent supply-chain
proofs. Enterprise deployments should verify both before installing.

## Artifacts attached to each release

| File | Purpose |
|---|---|
| `zcode-<os>-<arch>` | macOS/Linux release binary |
| `zcode-<os>-<arch>.sig` | cosign ed25519 signature of the binary |
| `zcode-<os>-<arch>.pem` | Fulcio-issued ephemeral cert binding the signature to the GitHub Actions OIDC identity |
| `zcode-<os>-<arch>.bundle` | Sigstore bundle containing signature, cert, and transparency-log proof for offline verification |
| `zcode.intoto.jsonl` | SLSA v1.0 level 3 provenance attestation covering all binaries |
| `sbom.cdx.json` | CycloneDX SBOM |
| `sbom.cdx.json.sig`, `sbom.cdx.json.pem`, `sbom.cdx.json.bundle` | cosign signature, cert, and Sigstore bundle for the SBOM |
| `SHA256SUMS` | SHA-256 of binaries, signatures/certs/bundles, provenance, and SBOM artifacts |

## 1. Verify the binary signature (cosign / Sigstore)

Install cosign (2.0+) and verify:

```sh
cosign verify-blob \
  --bundle zcode-linux-x86_64.bundle \
  --certificate-identity-regexp '^https://github.com/Softorize/zcode/.github/workflows/release.yml@refs/tags/v.*$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  zcode-linux-x86_64
```

Expected output: `Verified OK`.

The `--certificate-identity-regexp` anchors the signature to **this**
repository and **this** workflow, so a stolen Fulcio token from a
different GitHub project cannot be used to forge a zcode release.

## 2. Verify SLSA3 provenance

Install
[`slsa-verifier`](https://github.com/slsa-framework/slsa-verifier) and
run:

```sh
slsa-verifier verify-artifact \
  --provenance-path zcode.intoto.jsonl \
  --source-uri github.com/Softorize/zcode \
  --source-tag v<VERSION> \
  zcode-linux-x86_64
```

Expected output:
`PASSED: SLSA verification passed`.

This check proves the binary was built by the expected GitHub Actions
workflow from the expected source tag, on hosted runners, with no
manual tampering.

## 3. Verify the SBOM signature

```sh
cosign verify-blob \
  --bundle sbom.cdx.json.bundle \
  --certificate-identity-regexp '^https://github.com/Softorize/zcode/.github/workflows/release.yml@refs/tags/v.*$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  sbom.cdx.json
```

## 4. Cross-check with SHA256SUMS

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

## Air-gapped bundles

Air-gapped bundles produced by `scripts/release/airgap_bundle.sh` include
the binary, binary signature/cert, SLSA provenance, SBOM, SBOM
signature/cert/bundle, and a bundle-local `SHA256SUMS`. The bundled
`install.sh` refuses to install unless checksum, cosign, and SLSA
verification complete successfully.

For emergency break-glass installs only, operators can set
`ZCODE_AIRGAP_ALLOW_UNVERIFIED=1` to skip missing verifier tools. Do not
use that path for standard enterprise deployment.

## What verification proves

- **Origin**: binary came from Softorize/zcode's release workflow.
- **Integrity**: binary bits match what the workflow produced.
- **Non-repudiation**: OIDC identity signed into the cert means no
  later tampering of the signature or provenance without detection by
  Sigstore's Rekor transparency log.
- **Build hygiene**: SLSA3 guarantees a hosted, isolated build on
  GitHub-managed runners (not a developer laptop).

## Failure modes that verification catches

| Attack | Caught by |
|---|---|
| Swapped binary on a mirror | cosign + SHA256SUMS |
| Rebuilt by a different workflow | SLSA provenance identity check |
| Signed by a stolen Fulcio token from a different repo | `--certificate-identity-regexp` mismatch |
| Provenance forged post-hoc | Rekor transparency log entry missing |
| Forked repo publishing a release that looks like ours | `--source-uri` mismatch |

## Reporting a verification failure

Do not install a binary that fails any of the above checks. Report
via the disclosure channel in `SECURITY.md`.
