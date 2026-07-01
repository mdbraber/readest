# Building Readest for iOS (Local)

Personal build instructions for installing Readest on iPhone 17 via direct device install.

## Prerequisites

```bash
# Node + pnpm
nvm install v24 && nvm use v24
npm install -g pnpm

# iOS Rust targets
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

Xcode must be installed with the iOS SDK. Developer Mode must be enabled on the device:
**Settings → Privacy & Security → Developer Mode → On**

---

## One-time setup (after cloning)

```bash
cd readest
git submodule update --init --recursive
pnpm install
pnpm --filter @readest/readest-app setup-vendors
```

Fix the assets symlink (must point at Next.js output, not be an empty directory):

```bash
cd apps/readest-app
rm -rf src-tauri/gen/apple/assets
ln -s ../../../out src-tauri/gen/apple/assets
```

Create `apps/readest-app/.env.local` with personal backend URLs:

```
NEXT_PUBLIC_SUPABASE_URL=https://readest-supabase.example.com
NEXT_PUBLIC_SUPABASE_ANON_KEY=<your-supabase-anon-key>
NEXT_PUBLIC_API_BASE_URL=https://readest.example.com
SUPABASE_ADMIN_KEY=<your-supabase-service-role-key>
NEXT_PUBLIC_OBJECT_STORAGE_TYPE=s3
S3_ENDPOINT=https://readest-minio-api.example.com
S3_ACCESS_KEY_ID=<your-s3-access-key>
S3_SECRET_ACCESS_KEY=<your-s3-secret>
S3_BUCKET_NAME=readest-files
S3_REGION=us-east-1
```

Initialize the Xcode project and clear the `com.apple.provenance` extended attribute
that xcodegen adds (required once after cloning, and again after any upstream iOS config change):

```bash
cd apps/readest-app
pnpm tauri ios init
xattr -cr src-tauri/gen/apple/
```

---

## Build

```bash
cd apps/readest-app
pnpm tauri ios build
```

This runs `pnpm build` (Next.js, picking up `.env.local`) then the Xcode archive + export.
Output: `src-tauri/gen/apple/build/arm64/Readest.ipa`
Archive: `src-tauri/gen/apple/build/Readest_iOS.xcarchive`

---

## Install on iPhone 17

Connect the phone via USB, unlock it, then:

```bash
xcrun devicectl device install app \
  --device <your-device-udid> \
  "src-tauri/gen/apple/build/Readest_iOS.xcarchive/Products/Applications/Readest Selfhost.app"
```

The signing certificate is valid until **2027-06-26** (renewed annually by Xcode).

---

## When to re-run `tauri ios init`

Only needed after pulling upstream changes that touch iOS project configuration:
- `src-tauri/tauri.conf.json`
- `src-tauri/gen/apple/project.yml`
- `src-tauri/tauri.ios.conf.json`

```bash
pnpm tauri ios init
xattr -cr src-tauri/gen/apple/
pnpm tauri ios build
```

---

## What differs from upstream

This local branch changes the upstream Readest defaults to build under a personal Apple Developer account:

| File | Change |
|------|--------|
| `src-tauri/tauri.conf.json` | Bundle ID → `com.mdbraber.readest`, team → `D3S5M885YQ` |
| `src-tauri/gen/apple/project.yml` | Same IDs + team, added `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| `src-tauri/gen/apple/Readest_iOS/Readest_iOS.entitlements` | Removed `associated-domains` + `applesignin` (require paid account), app group → `group.com.mdbraber.readest` |
| `src-tauri/gen/apple/Readest_iOS/Info.plist` | Hand-tuned plist (was missing from repo); adds `UILaunchStoryboardName`, `CFBundlePackageType`, `CFBundleVersion` |
| `src-tauri/Info-ios.plist` | Added `UILaunchStoryboardName`, `CFBundlePackageType`, `CFBundleVersion` |
| `src-tauri/tauri.ios.conf.json` | Disables `appLink` so Tauri doesn't inject `associated-domains` on every init |
