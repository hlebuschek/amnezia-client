#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build_wireguard_go_macos.sh
#
# Build a universal (arm64 + x86_64) "wireguard-go" executable for the
# standard macOS daemon-based build of AmneziaVPN.
#
# The executable is the AmneziaWG fork of wireguard-go that understands the
# obfuscation UAPI extensions (jc, jmin, jmax, s1–s4, h1–h4).  It is launched
# at runtime by WireguardUtilsMacos::addInterface() as a child process.
#
# Usage:
#   bash deploy/build_wireguard_go_macos.sh [output_dir]
#
# If output_dir is not specified the binary is placed in
#   deploy/data/deploy-prebuilt/macos/
# which is the directory that build_macos.sh copies into the app bundle.
#
# Prerequisites:
#   • Go 1.21 or later  (brew install go)
#   • Xcode Command Line Tools
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="${1:-$SCRIPT_DIR/data/deploy-prebuilt/macos}"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Source repository for the AmneziaWG Go daemon.
# This is the CLI wireguard-go-compatible process that exposes a UAPI socket
# and supports the AmneziaWG obfuscation parameters.
# ---------------------------------------------------------------------------
AMNEZIAWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"
AMNEZIAWG_GO_DIR="$SCRIPT_DIR/build/amneziawg-go-src"

echo "==> Building universal wireguard-go for macOS (arm64 + x86_64)"
echo "    Output: $OUTPUT_DIR/wireguard-go"

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
if ! command -v go &>/dev/null; then
    echo "ERROR: 'go' not found. Install Go 1.21+ (brew install go)." >&2
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
GO_MAJOR=$(echo "$GO_VERSION" | cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | cut -d. -f2)
if [ "$GO_MAJOR" -lt 1 ] || { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 21 ]; }; then
    echo "ERROR: Go 1.21+ required, found $GO_VERSION" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Fetch amneziawg-go source
# ---------------------------------------------------------------------------
if [ -d "$AMNEZIAWG_GO_DIR/.git" ]; then
    echo "==> Updating amneziawg-go sources..."
    git -C "$AMNEZIAWG_GO_DIR" fetch --depth=1 origin
    git -C "$AMNEZIAWG_GO_DIR" reset --hard origin/HEAD
else
    echo "==> Cloning amneziawg-go..."
    mkdir -p "$(dirname "$AMNEZIAWG_GO_DIR")"
    git clone --depth=1 "$AMNEZIAWG_GO_REPO" "$AMNEZIAWG_GO_DIR"
fi

# ---------------------------------------------------------------------------
# Build arm64 and amd64 slices
# ---------------------------------------------------------------------------
BUILD_TMP="$SCRIPT_DIR/build/wireguard-go-universal"
mkdir -p "$BUILD_TMP"

echo "==> Building arm64 slice..."
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
    go build -C "$AMNEZIAWG_GO_DIR" \
    -trimpath \
    -ldflags="-s -w" \
    -o "$BUILD_TMP/wireguard-go-arm64" \
    .

echo "==> Building amd64 (x86_64) slice..."
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 \
    go build -C "$AMNEZIAWG_GO_DIR" \
    -trimpath \
    -ldflags="-s -w" \
    -o "$BUILD_TMP/wireguard-go-amd64" \
    .

# ---------------------------------------------------------------------------
# Merge into a universal binary with lipo
# ---------------------------------------------------------------------------
echo "==> Creating universal binary with lipo..."
lipo -create \
    "$BUILD_TMP/wireguard-go-arm64" \
    "$BUILD_TMP/wireguard-go-amd64" \
    -output "$BUILD_TMP/wireguard-go"

# Verify
echo "==> Verifying universal binary:"
lipo -info "$BUILD_TMP/wireguard-go"
file "$BUILD_TMP/wireguard-go"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
cp "$BUILD_TMP/wireguard-go" "$OUTPUT_DIR/wireguard-go"
chmod +x "$OUTPUT_DIR/wireguard-go"

echo ""
echo "✓ wireguard-go universal binary ready at: $OUTPUT_DIR/wireguard-go"
