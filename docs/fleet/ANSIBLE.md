# Deploying zcode via Ansible

Target: Linux (Debian / Ubuntu / RHEL / Fedora) managed by Ansible.

## Role layout

```
roles/zcode/
  tasks/main.yml
  files/managed.toml
  files/managed.d/20-security.toml
  defaults/main.yml
```

## `defaults/main.yml`

```yaml
zcode_version: "0.10.337"
zcode_arch: x86_64
zcode_install_dir: /usr/local/bin
zcode_managed_dir: /etc/zcode
zcode_update_pinned: "0.10.337"
zcode_require_signature: true
```

## `files/managed.toml`

```toml
privacy_redact_prompt_bodies = true
session_encryption_enabled = true
session_retention_days = 180
audit_retention_days = 180
cloud_telemetry_opt_in = false
egress_allowlist = "api.openai.com,api.anthropic.com,*.company.internal,zcode.internal.example.com"
egress_allow_private_network_plaintext = false
```

Additional managed policy can be layered through sorted drop-ins:

```toml
# files/managed.d/20-security.toml
approval_mode = "strict"
sandbox = "workspace-write"
update_require_signature = true
update_pinned_version = "0.10.337"
```

Do not set `api_auth_required` for the default local CLI deployment.
Add bearer/OIDC settings only if Ansible also exposes zcode's API, IDE bridge,
or daemon-like surfaces beyond the local user boundary.

## `tasks/main.yml`

```yaml
- name: Download air-gapped bundle
  get_url:
    url: "https://github.com/Softorize/zcode/releases/download/v{{ zcode_version }}/zcode-{{ zcode_version }}-linux-{{ zcode_arch }}-airgap.tar.gz"
    dest: "/tmp/zcode-airgap.tar.gz"
    mode: "0644"

- name: Extract
  unarchive:
    src: "/tmp/zcode-airgap.tar.gz"
    dest: "/tmp"
    remote_src: yes

- name: Run verifying installer
  command: >
    /tmp/zcode-{{ zcode_version }}-linux-{{ zcode_arch }}-airgap/install.sh
  environment:
    ZCODE_INSTALL_DIR: "{{ zcode_install_dir }}"

- name: Ensure managed config dir
  file:
    path: "{{ zcode_managed_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Ensure managed drop-in dir
  file:
    path: "{{ zcode_managed_dir }}/managed.d"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Deploy managed.toml
  copy:
    src: managed.toml
    dest: "{{ zcode_managed_dir }}/managed.toml"
    owner: root
    group: root
    mode: "0644"

- name: Deploy managed drop-ins
  copy:
    src: managed.d/
    dest: "{{ zcode_managed_dir }}/managed.d/"
    owner: root
    group: root
    mode: "0644"

- name: Env vars in /etc/profile.d
  copy:
    dest: /etc/profile.d/zcode.sh
    owner: root
    group: root
    mode: "0644"
    content: |
      export ZCODE_UPDATE_PINNED_VERSION="{{ zcode_update_pinned }}"
      {% if zcode_require_signature %}
      export ZCODE_UPDATE_REQUIRE_SIGNATURE=1
      {% endif %}
```

## Verify

```sh
ansible all -m shell -a 'zcode --version && zcode doctor enterprise --json && zcode audit verify'
```

## Notes

- The `install.sh` inside the air-gapped bundle runs checksum, cosign,
  SBOM signature, and SLSA verification before copying the binary, so
  deployment fails closed if a tampered or incomplete bundle is shipped.
- On locked-down hosts without outbound HTTPS, mirror the bundle on
  an internal artifact store and change the `get_url` step.
- Combine with `/etc/zcode/policy.toml` for tool-level policy (see
  the main README).
