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
| deploy rights | `/etc/sudoers.d/90-hpmmo-ci`: NOPASSWD for `/opt/hpmmo/bin/hpmmo_deploy.sh` only |
| Godot | `/opt/hpmmo-ci/godot/godot` (4.7.2), export templates in `~ghrunner/.local/share/godot/export_templates/` |
| server artifacts | `/var/lib/hpmmo-ci/artifacts` (newest 3) |
| toolchain | apt: git-lfs, cmake, ninja, clang, libpq-dev, mingw-w64, gh, jq, xxd, python3-cryptography, python3-numpy |

## Registering / re-registering a runner
1. GitHub → repo → Settings → Actions → Runners → **New self-hosted runner** → copy the token
   (valid ~1 hour).
2. On the host as root: `/opt/hpmmo-ci/register_runner.sh server <token>` (or `client`).

## Rules
- Never add a `pull_request` trigger to a workflow that runs here: the runner is the
  production host. Keep fork-PR workflows requiring approval (repo Settings → Actions).
- Upgrading Godot: replace `/opt/hpmmo-ci/godot/godot` and the export templates, then bump
  `GODOT_VERSION` in both workflows. The checks in the workflows fail if they disagree.
