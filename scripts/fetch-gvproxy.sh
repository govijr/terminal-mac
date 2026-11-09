#!/bin/bash
# Downloads the gvproxy release that build.sh bundles for `--network user` (user-space DHCP, DNS and NAT).
# gvproxy is part of containers/gvisor-tap-vsock (Apache-2.0). The download is checked against a pinned SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${GVPROXY_VERSION:-v0.9.0}"
sha256="${GVPROXY_SHA256:-e2a6825ba789fe588828b418c09aaf16525dec6d8cb2d16c94e72535dd4606be}"
url="https://github.com/containers/gvisor-tap-vsock/releases/download/$version/gvproxy-darwin"
mkdir -p vendor/gvproxy
download="$(mktemp vendor/gvproxy/.download.XXXXXX)"
trap 'rm -f "$download"' EXIT
echo "Downloading gvproxy $version…" >&2
curl -fsSL --retry 3 -o "$download" "$url"
if ! echo "$sha256  $download" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "Checksum mismatch for $url; not installing it." >&2
  exit 1
fi
# The release is a universal binary; terminal-mac only runs on Apple silicon.
lipo -thin arm64 "$download" -output vendor/gvproxy/gvproxy
chmod 755 vendor/gvproxy/gvproxy
echo "$version" > vendor/gvproxy/VERSION
echo "Fetched gvproxy $version into vendor/gvproxy/gvproxy. Rebuild with scripts/build.sh." >&2
