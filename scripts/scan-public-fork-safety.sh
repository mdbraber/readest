#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

python3 - <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path.cwd()
tracked_files = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def read_text(path: str) -> str:
    full_path = ROOT / path
    if not full_path.is_file():
        return ""
    try:
        return full_path.read_text(encoding="utf-8", errors="ignore")
    except FileNotFoundError:
        return ""


allowed_env_files = {
    "apps/readest-app/.env",
    "apps/readest-app/.env.tauri",
    "apps/readest-app/.env.web",
    "apps/readest-app/.env.local.example",
    "apps/readest-app/.env.tauri.example",
    "apps/readest-app/.env.web.example",
    "docker/.env.example",
}

secret_suffixes = (
    ".pem",
    ".key",
    ".p8",
    ".p12",
    ".jks",
    ".keystore",
    ".mobileprovision",
)

for path in tracked_files:
    name = Path(path).name
    lower = path.lower()
    if name.startswith(".env") and path not in allowed_env_files:
        fail(f"tracked env file is not allowed: {path}")
    if lower.endswith(secret_suffixes):
        fail(f"tracked signing/key material is not allowed: {path}")

selfhost_paths = [
    "apps/readest-app/src/services/customServerConfig.ts",
    "apps/readest-app/src/__tests__/services/customServerConfig.test.ts",
    "apps/readest-app/src-tauri/tauri.conf.json",
    "apps/readest-app/scripts/patch-tauri-selfhost.mjs",
    "docs/selfhost-client.md",
    ".github/workflows/build-selfhost.yml",
    ".github/workflows/release-selfhost.yml",
    ".github/workflows/sync-upstream.yml",
    ".github/workflows/selfhost-safety.yml",
]
selfhost_paths = [path for path in selfhost_paths if (ROOT / path).exists()]

official_updater_patterns = [
    "https://download.readest.com/releases/latest.json",
    "https://github.com/readest/readest/releases/latest/download/latest.json",
]

for path in selfhost_paths:
    text = read_text(path)
    for pattern in official_updater_patterns:
        if pattern in text:
            fail(f"official updater endpoint found in {path}: {pattern}")

tauri_config_path = ROOT / "apps/readest-app/src-tauri/tauri.conf.json"
if tauri_config_path.exists():
    config = json.loads(tauri_config_path.read_text(encoding="utf-8"))
    updater = config.get("plugins", {}).get("updater", {})
    endpoints = updater.get("endpoints", [])
    if not updater.get("pubkey"):
        fail("Tauri updater public key is missing")
    if not endpoints:
        fail("Tauri updater endpoint is missing")
    for endpoint in endpoints:
        if "github.com/readest/readest/" in endpoint or "download.readest.com/releases" in endpoint:
            fail(f"Tauri updater endpoint points to official Readest: {endpoint}")

url_scan_paths = [
    "apps/readest-app/src/services/customServerConfig.ts",
    "apps/readest-app/src/__tests__/services/customServerConfig.test.ts",
    "apps/readest-app/scripts/patch-tauri-selfhost.mjs",
    "docs/selfhost-client.md",
    ".github/workflows/build-selfhost.yml",
    ".github/workflows/release-selfhost.yml",
    ".github/workflows/sync-upstream.yml",
    ".github/workflows/selfhost-safety.yml",
]
url_re = re.compile(r"https?://[^\s\"'<>)]*")


def allowed_host(host: str) -> bool:
    host = host.lower().strip("[]")
    if not host:
        return True
    if host in {"localhost", "127.0.0.1", "::1"}:
        return True
    if re.match(r"^(10|127|0)\.\d{1,3}\.\d{1,3}\.\d{1,3}$", host):
        return True
    if re.match(r"^172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}$", host):
        return True
    if re.match(r"^192\.168\.\d{1,3}\.\d{1,3}$", host):
        return True
    allowed_exact = {"github.com", "readest.com", "example.com", "example.invalid"}
    if host in allowed_exact:
        return True
    allowed_suffixes = (
        ".github.com",
        ".readest.com",
        ".example.com",
        ".example.invalid",
        ".localhost",
    )
    return host.endswith(allowed_suffixes)


for path in url_scan_paths:
    if not (ROOT / path).exists():
        continue
    for match in url_re.finditer(read_text(path)):
        url = match.group(0).rstrip(".,")
        if "${{" in url:
            continue
        host = urlparse(url).hostname or ""
        if not allowed_host(host):
            fail(f"unexpected hardcoded URL host in {path}: {url}")

dangerous_fields = re.compile(
    r"\b(service_role|jwt_secret|postgres_password|database_url|s3_secret|aws_secret_access_key)\b",
    re.IGNORECASE,
)
dangerous_scan_paths = [
    "apps/readest-app/scripts/patch-tauri-selfhost.mjs",
    ".github/workflows/build-selfhost.yml",
    ".github/workflows/release-selfhost.yml",
    ".github/workflows/sync-upstream.yml",
    ".github/workflows/selfhost-safety.yml",
]
allowed_dangerous_field_mentions = {"scripts/scan-public-fork-safety.sh"}

for path in dangerous_scan_paths:
    if not (ROOT / path).exists() or path in allowed_dangerous_field_mentions:
        continue
    text = read_text(path)
    match = dangerous_fields.search(text)
    if match:
        fail(f"dangerous server secret field mention in {path}: {match.group(1)}")

private_material_patterns = [
    re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
    re.compile(r"untrusted comment:\s*minisign secret key", re.IGNORECASE),
]

for path in tracked_files:
    if path == "scripts/scan-public-fork-safety.sh":
        continue
    text = read_text(path)
    for pattern in private_material_patterns:
        if pattern.search(text):
            fail(f"private key material pattern found in {path}")

if failures:
    print("Public fork safety scan failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("Public fork safety scan passed.")
PY
