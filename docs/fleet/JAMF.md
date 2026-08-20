# Deploying zcode via Jamf Pro

Target: macOS 13+ managed by Jamf Pro.

## 1. Package the binary

Wrap the notarized zcode binary as a signed `.pkg` using
`productbuild` or Composer. Payload layout:

```
/usr/local/bin/zcode                    (mode 0755, owner root:wheel)
/Library/Application Support/zcode/     (mode 0755)
/Library/Application Support/zcode/managed.d/ (mode 0755)
```

Use the air-gapped bundle output directly for the payload if you want
each install to run cosign + slsa-verifier verification at install
time.

## 2. Managed config profile

Create a Configuration Profile with a **Custom Settings** payload that
writes `managed.toml`. Jamf can ship a file via a script policy, so
wrap this in a shell script and set it as a **Before** trigger on the
same policy that installs the .pkg:

```sh
#!/bin/sh
dir="/Library/Application Support/zcode"
mkdir -p "$dir/managed.d"
cat > "$dir/managed.toml" <<'EOF'
privacy_redact_prompt_bodies = true
session_encryption_enabled = true
session_retention_days = 180
audit_retention_days = 180
cloud_telemetry_opt_in = false
egress_allowlist = "api.openai.com,api.anthropic.com,*.company.internal,zcode.internal.example.com"
egress_allow_private_network_plaintext = false
control_plane_url = "https://zcode.internal.example.com"
control_plane_policy_sync = true
EOF
cat > "$dir/managed.d/20-security.toml" <<'EOF'
approval_mode = "strict"
sandbox = "workspace-write"
update_require_signature = true
update_pinned_version = "0.10.337"
EOF
chown root:wheel "$dir/managed.toml"
chown -R root:wheel "$dir/managed.d"
chmod 0644 "$dir/managed.toml"
chmod 0755 "$dir/managed.d"
chmod 0644 "$dir/managed.d/"*.toml
```

Do not set `api_auth_required` for the default local CLI deployment.
Add bearer/OIDC settings only if Jamf also exposes zcode's API, IDE bridge,
or daemon-like surfaces beyond the local user boundary.

## 3. Environment variables

Push machine-scoped env via `launchd.conf` or a `launchd` plist in
`/Library/LaunchDaemons/com.zcode.env.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.zcode.env</string>
  <key>RunAtLoad</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string>
    <string>setenv</string>
    <string>ZCODE_UPDATE_PINNED_VERSION</string>
    <string>0.10.337</string>
  </array>
</dict>
</plist>
```

Owner root:wheel, mode 0644. Issue `launchctl load /Library/LaunchDaemons/com.zcode.env.plist` via a Jamf policy.

## 4. Verify

On a managed Mac:

```sh
zcode --version
cat "/Library/Application Support/zcode/managed.toml"
zcode doctor enterprise --json
zcode audit verify
```

Expected: the managed keys are active, and the audit log chain
validates clean.

## 5. Removal

Jamf policy to uninstall:

```sh
rm -f /usr/local/bin/zcode
rm -rf "/Library/Application Support/zcode"
launchctl unload -w /Library/LaunchDaemons/com.zcode.env.plist
rm -f /Library/LaunchDaemons/com.zcode.env.plist
```
