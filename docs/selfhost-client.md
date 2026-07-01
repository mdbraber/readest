# Readest Self-host Client Configuration

Readest desktop and mobile clients can be pointed at a compatible self-hosted backend by entering one public server base URL in the client.

The client does not contain a private backend URL. Each user supplies their own server URL at runtime.

## Server URL

In the desktop or mobile app, open the login page or Settings -> Server, then enter a server base URL such as:

```text
https://your-readest-server.example.com
```

The client normalizes the URL before saving it:

- leading and trailing whitespace is removed
- trailing slashes are removed
- only `http` and `https` URLs are accepted
- production builds require `https`
- development builds may use `http` for localhost, loopback, or local network testing

## Public Runtime Config Endpoint

A self-hosted server should expose one of these public endpoints:

```text
GET /.well-known/readest-client-config.json
```

or:

```text
GET /api/public/runtime-config
```

The `.well-known` endpoint is tried first. If that request fails, the client tries `/api/public/runtime-config`.

Example response:

```json
{
  "apiBaseUrl": "https://your-readest-server.example.com",
  "supabaseUrl": "https://your-supabase-public.example.com",
  "supabaseAnonKey": "your-public-anon-key"
}
```

Fields:

- `apiBaseUrl`: public base URL for Readest API requests. If omitted, the entered server base URL is used.
- `supabaseUrl`: public Supabase project URL used by the client for authentication and sync.
- `supabaseAnonKey`: Supabase public anon key. This is not the service role key.

Current Readest authentication and sync flows require Supabase client config, so `supabaseUrl` and `supabaseAnonKey` must be present for a saved custom server.

## Public Config Is Not Secret Config

The runtime config endpoint is public client configuration. It must only return values that are safe for an installed app or browser client to see.

Never return server-side secrets from this endpoint, including:

- Supabase `service_role` keys
- JWT signing secrets
- database URLs or database passwords
- S3 or object storage secrets
- AWS secret access keys
- Tauri updater private keys
- Android keystores or signing passwords
- SSH keys or other private keys

The client rejects runtime config responses that contain common dangerous secret field names.

## Manual Configuration

The recommended setup is to expose one of the public runtime config endpoints and ask users to enter only the server base URL.

If a deployment cannot expose that endpoint, an advanced manual mode may be added later for entering `apiBaseUrl`, `supabaseUrl`, and `supabaseAnonKey` directly. The default client flow intentionally avoids asking users to handle multiple backend values.

## Session Handling

When the saved server changes, the client clears local authentication session data and requires the user to sign in again. This prevents a session from one server from being reused against another server.

## Public Fork Boundary

For public forks and GitHub Actions:

- do not commit real deployment URLs, service keys, database credentials, signing keys, Android keystores, or private updater keys
- keep Tauri updater private keys in GitHub Actions secrets only
- keep Android signing material in GitHub Actions secrets only
- use the fork's public GitHub Releases `latest.json` for updater metadata, not the official Readest updater endpoint

## GitHub Secrets

The self-hosted build and release workflows expect these repository secrets:

- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
- `TAURI_UPDATER_PUBKEY`
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Generate the Tauri updater key pair with the Tauri signer, store the private key and password as secrets, and store only the public key in `TAURI_UPDATER_PUBKEY`.

For Android, base64-encode the keystore file and store that encoded value in `ANDROID_KEYSTORE_BASE64`. The keystore file itself must not be committed.

## Releasing a Self-host Client

Use one of the self-host tag patterns:

```text
v0.11.4-selfhost
selfhost-v0.11.4
```

Pushing one of those tags triggers the self-host build and release workflows. The release uploads the Windows x64 installer, Android APK, updater signatures, and `latest.json`.

The default updater URL points at this fork's public GitHub Release metadata:

```text
https://github.com/<fork-owner>/<fork-repo>/releases/latest/download/latest.json
```

Android APKs are published by the workflow. Platform-level automatic app update behavior for sideloaded Android APKs may vary by installation source, so distribute the release URL or APK directly when needed.

## Syncing Upstream

The `sync-upstream.yml` workflow rebases `selfhost-main` on `readest/readest` `main`.

If the rebase has conflicts, the workflow fails and leaves the fork unchanged. Resolve the conflict locally on `selfhost-main`, run the focused self-host tests and safety scan, then push the resolved branch.

The workflow intentionally uses `git rebase upstream/main`; it does not force-overwrite downstream changes.
