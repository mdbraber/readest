#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/prepare-selfhost-backport.sh <upstream-tag>

Creates a selfhost backport branch and tag from an upstream Readest release tag.
The selfhost patch must apply cleanly to the upstream tag; conflicts fail fast so
historical releases are not silently repackaged from the wrong source revision.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

upstream_tag="${1:-}"
if [ -z "$upstream_tag" ]; then
  usage >&2
  exit 2
fi
if ! [[ "$upstream_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid upstream tag: $upstream_tag" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
current_ref="$(git rev-parse --abbrev-ref HEAD)"
selfhost_tag="selfhost-${upstream_tag}"
selfhost_branch="selfhost/backport/${upstream_tag#v}"
version="${upstream_tag#v}"
patch_file="$(mktemp)"
cleanup() {
  rm -f "$patch_file"
}
trap cleanup EXIT

cd "$repo_root"

if ! git rev-parse -q --verify "refs/tags/$upstream_tag" >/dev/null; then
  echo "Upstream tag was not found locally: $upstream_tag" >&2
  exit 1
fi

git diff --binary "upstream/main..$current_ref" -- \
  .github/workflows/build-selfhost.yml \
  .github/workflows/release-selfhost.yml \
  apps/readest-app/scripts/patch-tauri-selfhost.mjs \
  apps/readest-app/src-tauri/tauri.conf.json \
  apps/readest-app/src/app/auth/page.tsx \
  apps/readest-app/src/app/opds/utils/opdsReq.ts \
  apps/readest-app/src/app/user/subscription/success/page.tsx \
  apps/readest-app/src/components/UpdaterWindow.tsx \
  apps/readest-app/src/components/settings/ServerSettingsPanel.tsx \
  apps/readest-app/src/components/settings/SettingsDialog.tsx \
  apps/readest-app/src/context/AuthContext.tsx \
  apps/readest-app/src/helpers/androidUpdatePlatform.ts \
  apps/readest-app/src/helpers/auth.ts \
  apps/readest-app/src/helpers/updater.ts \
  apps/readest-app/src/libs/metadata.ts \
  apps/readest-app/src/libs/payment/stripe/client.ts \
  apps/readest-app/src/libs/share.ts \
  apps/readest-app/src/libs/storage.ts \
  apps/readest-app/src/libs/sync.ts \
  apps/readest-app/src/libs/user.ts \
  apps/readest-app/src/services/commandRegistry.ts \
  apps/readest-app/src/services/customServerConfig.ts \
  apps/readest-app/src/services/runtimeConfig.ts \
  apps/readest-app/src/services/translators/providers/deepl.ts \
  apps/readest-app/src/utils/supabase.ts \
  docs/selfhost-client.md \
  scripts/scan-public-fork-safety.sh \
  > "$patch_file"

git checkout -B "$selfhost_branch" "$upstream_tag"
if ! git apply --3way "$patch_file"; then
  echo "::error::Selfhost patch does not apply cleanly to $upstream_tag" >&2
  exit 1
fi

node - "$version" <<'NODE'
const fs = require('node:fs');
const version = process.argv[2];
const path = 'apps/readest-app/package.json';
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
pkg.version = version;
fs.writeFileSync(path, `${JSON.stringify(pkg, null, 2)}\n`);
NODE

git add \
  .github/workflows/build-selfhost.yml \
  .github/workflows/release-selfhost.yml \
  apps/readest-app \
  docs/selfhost-client.md \
  scripts/scan-public-fork-safety.sh
git commit -m "selfhost: backport client release ${version}"
git tag -f "$selfhost_tag"

echo "Prepared $selfhost_tag on $selfhost_branch"
