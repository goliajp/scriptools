# scriptools

A collection of standalone shell utilities. Each tool is a single,
self-contained script with its version pinned inside the file
(`PATCH_VERSION="..."` near the top). No release tags, no packaging
manifests — read the file to know the version.

## Tools

- [`rebuild-tun-from-mainline.sh`](./rebuild-tun-from-mainline.sh) —
  repair broken vendor-shipped `tun.ko` on Firefly / Rockchip / Radxa
  aarch64 SDK images by rebuilding it from upstream Linux source.

  ```bash
  curl -fsSL https://raw.githubusercontent.com/<owner>/scriptools/master/rebuild-tun-from-mainline.sh \
    -o /tmp/rebuild-tun-from-mainline.sh
  sudo bash /tmp/rebuild-tun-from-mainline.sh        # interactive
  sudo bash /tmp/rebuild-tun-from-mainline.sh -y     # silent install (idempotent)
  ```

## Layout

- One script per file at the repo root, kebab-case name, `.sh` suffix.
- Each script must:
  - declare `PATCH_VERSION="x.y.z"` near the top
  - support `--help`
  - work standalone (no sibling-file imports — copy/paste-able)

## Branching

git-flow-avh: production = `master`, integration = `develop`,
features off `develop`. New tools land on `develop` first.
