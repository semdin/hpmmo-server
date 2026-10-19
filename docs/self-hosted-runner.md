# Self-hosted CI runner (game host 185.118.141.74)

Both release workflows run on the game host since 2026-10-19 (label `hpmmo-server`
for this repo, `hpmmo-client` for hpmmo-client). Reason: GitHub-hosted runners
pulled the whole Git LFS tree on every push, and LFS bandwidth was the bill.
A persistent workspace fetches only changed objects.

## Host layout
| What | Where |
|---|---|
| runner user | `ghrunner` (no login password) |
| runners | `/opt/actions-runner-server`, `/opt/actions-runner-client` (systemd `actions.runner.*`) |
| resource cap | `hpmmo-ci.slice`: CPUQuota=200%, MemoryMax=5G, low CPU/IO weight; runner units `Nice=10` |
| root rights | `/etc/sudoers.d/90-hpmmo-ci`: NOPASSWD for `/opt/hpmmo/bin/hpmmo_deploy.sh` and `/opt/hpmmo-ci/build_linux_launcher.sh` only |
| Linux launcher build | `/opt/hpmmo-ci/build_linux_launcher.sh` (root-owned copy of `client/launcher_cpp/packaging/linux/ci_build_launcher.sh`): Docker image `hpmmo-launcher-build:22.04` from the checked-out Dockerfile, AppImage built in a throwaway container. Reinstall the copy when that script changes: `install -o root -g root -m 0755 <checkout>/launcher_cpp/packaging/linux/ci_build_launcher.sh /opt/hpmmo-ci/build_linux_launcher.sh` |
| Godot | `/opt/hpmmo-ci/godot/godot` (4.7.2), export templates in `~ghrunner/.local/share/godot/export_templates/` |
| server artifacts | `/var/lib/hpmmo-ci/artifacts` (newest 3) |
| toolchain | apt: git-lfs, cmake, ninja, clang, libpq-dev, mingw-w64, gh, jq, xxd, python3-cryptography, python3-numpy, docker.io, libcurl4-openssl-dev, SDL3 build deps (X11/Wayland dev headers) |

## Registering / re-registering a runner
1. GitHub → repo → Settings → Actions → Runners → **New self-hosted runner** → copy the token
   (valid ~1 hour).
2. On the host as root: `/opt/hpmmo-ci/register_runner.sh server <token>` (or `client`).

## Rules
- Never add a `pull_request` trigger to a workflow that runs here: the runner is the
  production host. Keep fork-PR workflows requiring approval (repo Settings → Actions).
- Upgrading Godot: replace `/opt/hpmmo-ci/godot/godot` and the export templates, then bump
  `GODOT_VERSION` in both workflows. The checks in the workflows fail if they disagree.

## Git LFS server (since 2026-10-19)
Git LFS no longer uses GitHub. `.lfsconfig` in both repos points at
`https://lfs.agsilvery.com/api/semdin/hpmmo-<repo>`:
- `hpmmo-lfs.service`: rudolfs 0.3.8 (Docker, pinned) on 127.0.0.1:8085, S3 backend =
  Cloudflare R2 bucket `hpmmo-lfs` (prefix `lfs/`), 20 GiB local cache in
  `/var/cache/hpmmo-lfs`, no rudolfs encryption key (nothing to lose; the bucket is private).
  Env: `/etc/hpmmo/lfs.env` (generated from `/etc/hpmmo/r2.env`).
- Caddy (`/etc/caddy/Caddyfile`): TLS via Let's Encrypt, HTTP basic auth on everything.
  The credentials are in `/etc/hpmmo/lfs-auth.env` (user `hpmmo`). The runner user has
  them in `~ghrunner/.git-credentials`; a developer machine stores them once with
  `git credential approve` (Windows: Git Credential Manager).
- DNS: `lfs.agsilvery.com` A record -> 185.118.141.74, DNS only (not proxied).
- Workflows pull LFS in their own step after checkout (not `checkout lfs: true`),
  so git-lfs reads `.lfsconfig` from the tree.
