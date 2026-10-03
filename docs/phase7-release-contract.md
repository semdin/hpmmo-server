# HPMMO client release contract (plan.md Phase 7)

**Status:** implemented and rehearsed locally (`server/tests/release_pipeline_test.py`, `RELEASE RESULT: N checks, M failures`).
The launcher (separate workstream, `client/launcher_cpp/`) is written against the document below; the
publishing half (this repository's `deploy/` plus `client/tools/release/`) produces exactly these bytes.

Owner split:

| Concern | Owner |
| --- | --- |
| `manifest.json` schema, version fields, gating rules | this document |
| Signing, packaging, publishing, CI | `client/tools/release/`, `client/.github/workflows/client-release.yml` |
| Serving the manifest and artifacts over HTTPS | `server/deploy/hpmmo_status.py`, `server/deploy/tls/make_cert.sh` |
| Consuming the manifest, download/stage/activate/repair | launcher workstream (`client/launcher_cpp/`) |

---

## 1. The manifest

Detached-signed, served read-only, **never modified in place**: a change to any field means a new
manifest (new signature) even when the artifact bytes are identical.

```json
{ "channel": "dev|beta|release", "client_version": "0.7.0", "min_launcher_version": "0.7.0",
  "protocol_version": 4, "protocol_min": 4, "protocol_max": 4,
  "content_version": "2026.10.04-1", "content_sha256": "<hex>",
  "server_version": "0.7.0", "schema_version": 4, "platform": "windows-x86_64",
  "published_at": "<ISO8601Z>", "release_notes": "...",
  "artifacts": [ { "kind": "full", "from_version": null, "url": "https://<host>/releases/<file>.zip",
                   "size": 12345, "sha256": "<hex>" } ] }
```

Encoding: UTF-8, two-space indent, ASCII-escaped, **one trailing newline** (`release_common.json_bytes`).
The signature covers these exact bytes, so the encoding is part of the contract, not a formatting preference.
`gen_manifest.py --verify` re-derives and checks all of it, and `client-release.yml` runs that verification
on every build and again before publishing.

### 1.1 Which field gates what

The point of separate version fields is that a **server-only patch must not force a client download**.
The reference implementation of these rules is `gen_manifest.py --gate`; the launcher must implement the
same rules and must not invent others.

| Field | What it gates | Forces a client download? |
| --- | --- | --- |
| `client_version` | the version of the game build in this artifact. The launcher compares it with the installed version. | **Yes** — installed `<` offered means download-and-activate; installed `>` offered (channel switch backwards) means keep the installed build and say so. |
| `min_launcher_version` | the oldest launcher allowed to install this release. | No — it gates the **launcher** (self-update first). Below it, the launcher must refuse to install and explain why. |
| `protocol_version` | the wire protocol the client in this artifact speaks. | Indirectly: it must satisfy `protocol_min <= protocol_version <= protocol_max` or the build cannot go online at all. A protocol bump therefore implies a client release. |
| `protocol_min` / `protocol_max` | the range the **server** currently accepts (compatibility window). | No by itself — raising the floor forces a client update only because the old client's `protocol_version` falls out of range. |
| `content_version` | the game content shipped inside the artifact (maps, zone data, data tables). | No by itself. If the client is current but its content version differs, that is a **broken/half-applied install → repair**, not a version mismatch. |
| `content_sha256` | proves which content the artifact actually carries (rule in §3.4). | No — it is a verification input for the repair path. |
| `server_version` | which server release this manifest is advertised against. Display, support, and the deployment record. | **No.** A server-only bump republishes the manifest with a new `server_version` and identical `client_version`, `content_version` and artifact hashes: launchers see "up to date" and download nothing. |
| `schema_version` | database schema level the server is at, surfaced in the launcher's status line and in support reports. | **No.** Never a gate. |
| `channel` | which publishing channel this manifest coordinates. | No — but the launcher must fetch the manifest for the channel the player selected. |

`--gate` output (also used by `release_pipeline_test.py` to prove the rules):

```json
{ "client_update": "none|required", "launcher_update": "none|required",
  "content_status": "current|updated_with_client|repair_required|unknown",
  "protocol_compatible": true, "protocol_effective": 4, "protocol_range": [4, 4],
  "playable_online": true, "offered": {...}, "reasons": ["..."] }
```

---

## 2. Signature and key custody

* **Algorithm:** Ed25519 over the exact `manifest.json` bytes. No Python crypto dependency:
  signing and verification use the OpenSSL CLI (`openssl pkeyutl -sign/-verify -rawin`).
* **Signature file:** `manifest.json.sig` — one line of base64 containing the **raw 64-byte** signature,
  LF-terminated. Nothing else is ever appended to that line.
* **Key id:** `manifest.json.keyid`, a small JSON sidecar
  (`{"key_id": "<hex>", "algorithm": "ed25519", "sig_file": "manifest.json.sig"}`), because the key id has
  to travel *with* the signature while the `.sig` file itself stays byte-exact. `key_id` is
  `sha256(DER SubjectPublicKeyInfo)` — the same value `deploy/tls/make_cert.sh` prints for the TLS pin, so
  one convention covers both keys.
* **Pinning:** the launcher embeds the public key. It derives `key_id` from that pinned key and refuses any
  manifest whose key id differs — a manifest cannot introduce its own key.
  The launcher's pin is the **base64 of the raw 32-byte Ed25519 public key** (its own key id is local); the
  `.keyid` sidecar is what the publishing side uses to prove which key signed a manifest and to make a
  rotation auditable. Both describe the same key, and both are derivable from the private key:

  ```sh
  openssl pkey -in release.key.pem -pubout -outform DER | tail -c 32 | base64 -w0   # launcher pin
  openssl pkey -in release.key.pem -pubout -outform DER | openssl dgst -sha256      # key_id
  ```
* **TLS pin format:** lowercase hex SPKI sha256 — the same value `make_cert.sh` prints, `/tls/spki` serves,
  and the launcher accepts as `--pinned-spki` / `pinned_spki_sha256`.
* **Custody:** the private key never lives in a repository. `gen_manifest.py` refuses to sign with a key
  found inside a git working tree; CI reads it from the `HPMMO_CLIENT_SIGNING_KEY` secret, writes it to
  `$RUNNER_TEMP` with mode 600, and **fails closed at its first step** when the secret is absent.
  `client/tools/release/keys/README.md` holds the rotation procedure.

Commands the contract fixes (do not substitute a different construction):

```sh
openssl genpkey -algorithm ed25519 -out release.key.pem
openssl pkey -in release.key.pem -pubout -out release.pub.pem
openssl pkeyutl -sign   -rawin -inkey release.key.pem -in manifest.json -out sig.bin
openssl pkeyutl -verify -rawin -pubin -inkey release.pub.pem -in manifest.json -sigfile sig.bin
```

---

## 3. Packaging and publication

### 3.1 Artifact

`package_client.py` builds `hpmmo-client-<client_version>-<platform>.zip` from a build directory that
contains exactly `client/` (Godot export: `hpmmo.exe` + `hpmmo.pck`) and optionally `launcher/`
(the native launcher and its assets, for launcher self-update). Anything else at the top level is refused.

Layout inside the zip — the game payload is **flat at the archive root**, because the launcher extracts a
package straight into its versioned install directory and resolves the executable as
`<versionDir>/HPMMO.exe` (with a configurable override and a short candidate list). A wrapper directory
would install a build the launcher could not launch:

```
HPMMO.exe                     the game payload, flat
HPMMO.pck
launcher/HPMMO_Launcher.exe   the launcher payload, in a directory of its own so it can
launcher/assets/hpmmo_banner.jpg   never collide with a game file name
release.json
```

`release.json` records `format`, `client_version`, `content_version`, `platform`, `version_dir`, and for
every file its `path` (the archive path), `role` (`game` for the payload, `launcher` for the launcher
payload), `size` and `sha256`. `gen_manifest.py` refuses to describe a package whose `release.json`
disagrees with the manifest it is about to sign.

**Deterministic:** entries are sorted by path and stamped 1980-01-01, so the same input tree produces the
same zip bytes — which is what makes "immutable artifact, hash recorded in the signed manifest" true.

**Refused, fail closed** (`release_common.path_refusal`): user data (`settings/`, `keybinds/`, `logs/`,
`screenshots/`, `saves/`, `client_config.json`, `*.log`, `save*.json`, …), editor/VCS caches (`.godot/`,
`.git/`, `__pycache__/`, `*.pyc`, `*.uid`), and secrets — both by name (`*.pem`, `*.key`, `id_ed25519`,
`.env`, `credentials*`, `known_hosts`) and by content (private-key headers, `HPMMO_SERVICE_TOKEN=`,
`HPMMO_DB_PASSWORD=`, `PGPASSWORD=`, `DATABASE_URL=postgres`).

**Artifact kinds.** `full` (published, `from_version: null`) and `delta`
(`from_version: "<installed version>"`, accepted by the tooling, not published yet). The launcher's selector
skips any entry of kind `launcher` when choosing what to install and matches a delta only on an exact
`from_version`, falling back to the full package — so `full` + `from_version: null` is always installable.
`launcher` is the reserved kind for the launcher self-update payload (gated by `min_launcher_version`);
this pipeline does not publish it yet.

### 3.2 Release root (what `/releases/` serves)

```
/srv/hpmmo/client-releases/                        -> https://<host>/releases/
  hpmmo-client-0.7.0-windows-x86_64.zip            immutable, never overwritten
  hpmmo-client-0.7.0-windows-x86_64.zip.sha256
  channels/<channel>/manifest.json                 the channel pointer
  channels/<channel>/manifest.json.sig
  channels/<channel>/manifest.json.keyid
  channels/<channel>/SHA256SUMS
```

`SHA256SUMS` covers the manifest set in its own directory (artifact digests are recorded in the manifest
itself and beside each artifact in its `.sha256` file). Flipping a channel = writing that channel's
manifest set; that is the only operation that redirects launchers to a different build, and in CI it is
the step behind the `client-release` environment approval.

### 3.3 Version directory naming

| Thing | Name |
| --- | --- |
| version directory (inside the zip and on disk after activation) | `hpmmo-client-<client_version>-<platform>` |
| full artifact | `hpmmo-client-<client_version>-<platform>.zip` |
| delta artifact (not published yet) | `hpmmo-client-<client_version>-from-<from_version>-<platform>.zip` |
| launcher install root (launcher's choice, not ours) | `.../versions/<client_version>/` with an atomic `current` switch |

### 3.4 `content_sha256` rule

sha256 over the UTF-8 lines `"<sha256>  <path>\n"`, LF line endings, sorted by `path`, for every entry of
the package's `release.json` whose `role` is `game` — i.e. the game payload, never the launcher binaries
or the manifest metadata. It is computed by the signer (`gen_manifest.py`) from the package itself, so it
cannot drift from the artifact it describes.

---

## 4. HTTPS endpoint

`server/deploy/hpmmo_status.py` serves the status document and the release root from one listener.
`server/tls` is not a thing; the certificate lives on the box, never in a repository.

| Path | Content |
| --- | --- |
| `GET /status` | deployment state (`ONLINE`, `ANNOUNCING`, `DRAINING`, `SAVING`, `DISCONNECTING`, `MAINTENANCE`, `APPLYING`, `VERIFYING`), active and previous release, timestamp, message |
| `GET /health` | liveness, plus whether this listener is serving TLS |
| `GET /tls/spki` | the SPKI sha256 the launcher must pin (so an operator can confirm the pin from the running service) |
| `GET /releases/<file>` | read-only download root; `HEAD` supported (size/resume/disk-space checks) |
| `GET /releases/channels/<channel>/manifest.json` (+`.sig`, `.keyid`) | the channel manifest |

Rules:

* **TLS with a pinned certificate.** `deploy/tls/make_cert.sh` generates a self-signed certificate,
  ~825 days, SAN naming the exact host (IP hosts go in as `IP:`, names as `DNS:`), and prints the
  **SPKI sha256** the launcher embeds. Self-signed is deliberate and documented: the launcher pins the key,
  so there is no CA to trust and no hostname dependency. `--print-pin` recomputes the pin from a running
  installation, and `/tls/spki` reports it over the wire.
* **Cleartext release downloads are refused** for non-loopback peers (403). An artifact fetched over plain
  HTTP is one an attacker on the path can replace; the manifest signature protects the *metadata*, not the
  transport. Loopback cleartext stays available for operator debugging.
* **Path safety:** no directory traversal, no dotfiles, no directory listings, nothing that resolves
  outside the release root; everything else is 404.
* **Caching:** artifacts are `immutable, max-age=31536000`; manifests are `no-store`.
* **Non-loopback binds require both** `HPMMO_STATUS_ALLOW_NONLOOPBACK=1` *and* a TLS certificate/key.
  A public status listener without TLS is refused at startup.

### 4.1 The exact change needed to expose this on the live box

**Not applied in this task** — the service is implemented and rehearsed on loopback only. To expose it
(volumes assume the layout `/opt/hpmmo/bin/hpmmo_status.py`, `deploy/install_layout.sh`):

```sh
# 1. certificate (as root, on the box; the key stays on the box, mode 600)
install -d -m 750 /etc/hpmmo/tls
deploy/tls/make_cert.sh --host 213.250.145.75 --san DNS:<any-internal-name> \
    --out /etc/hpmmo/tls                 # prints SPKI sha256 -> pin it in the launcher
chmod 600 /etc/hpmmo/tls/release-key.pem && chown <status-user>: /etc/hpmmo/tls/*

# 2. release root the ssh publish user can write and the service can only read
install -d -m 755 /srv/hpmmo/client-releases/channels/{dev,beta,release}

# 3. unit: deploy/systemd/hpmmo-status.service gains
Environment=HPMMO_STATUS_HOST=0.0.0.0
Environment=HPMMO_STATUS_PORT=8443
Environment=HPMMO_STATUS_ALLOW_NONLOOPBACK=1
Environment=HPMMO_STATUS_RELEASES_ROOT=/srv/hpmmo/client-releases
Environment=HPMMO_STATUS_TLS_CERT=/etc/hpmmo/tls/release-cert.pem
Environment=HPMMO_STATUS_TLS_KEY=/etc/hpmmo/tls/release-key.pem

# 4. firewall + cloud security group
ufw allow 8443/tcp

# 5. apply and verify
systemctl daemon-reload && systemctl restart hpmmo-status
curl -fsS https://127.0.0.1:8443/status
python3 /opt/hpmmo/bin/hpmmo_status.py --print-pin --tls-cert /etc/hpmmo/tls/release-cert.pem
```

The deployment state stays loopback-only on 8083 for the controller's own use; 8443 is the only new public
port, it serves nothing but `/status`, `/health`, `/tls/spki` and read-only files, and it must not be added
before the certificate exists (the service refuses the bind otherwise). Closing the Phase 6 item
(the API exposed on 8081) remains a separate, prerequisite change.

---

## 5. What the client pipeline publishes, and what it deliberately does not

Implemented: full packages, deterministic zip, signed manifest, channel pointer, immutability check on
publish, HTTPS serving, fail-closed CI key handling, and the manual channel gate.

Not implemented yet (Phase 7 remainder, tracked against the plan):

* **delta artifacts** — the contract reserves `kind: "delta"` + `from_version`, and `gen_manifest.py`
  accepts them, but the pipeline publishes `full` until full updates and recovery are proven on real
  machines (the plan's stated order).
* **launcher self-update bootstrap** — the package carries `launcher/`, and `min_launcher_version` gates
  it, but the small verified helper that swaps a running launcher is launcher-workstream code.
* **the VPS secrets** (`HPMMO_CLIENT_SIGNING_KEY`, `HPMMO_DEPLOY_SSH_KEY`, `HPMMO_DEPLOY_KNOWN_HOSTS`,
  `HPMMO_DEPLOY_USER`, `HPMMO_DEPLOY_HOST`) and the `client-release` environment approval exist only as
  required CI inputs; they are repository configuration, not code, and must be created before the first
  publish.
