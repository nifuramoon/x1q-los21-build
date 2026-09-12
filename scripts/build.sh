#!/usr/bin/env bash
# Build LineageOS 21 for x1q (Galaxy S20 5G Snapdragon / SCG01)
set -euo pipefail

LOS_DIR="${LOS_DIR:-/mnt/build/los21}"
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}"
export LC_ALL=C
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
ccache -M 50G || true

cd "$LOS_DIR"

# local manifest
mkdir -p .repo/local_manifests
cp "$BUILD_DIR/local_manifests/x1q.xml" .repo/local_manifests/

# sync
repo sync -c -j"$(nproc)" --force-sync --no-clone-bundle

# vendor blobs (端末接続時に抽出)
if [ -x device/samsung/x1q/extract-files.sh ] && [ "${EXTRACT_BLOBS:-0}" = "1" ]; then
    (cd device/samsung/x1q && ./extract-files.sh)
fi

# patches
shopt -s nullglob
for p in "$BUILD_DIR"/patches/*.patch; do
    echo "applying $p"
    git apply "$p" || patch -p1 < "$p"
done
shopt -u nullglob

# build
source build/envsetup.sh
breakfast x1q
mka bacon -j"$(nproc)"
