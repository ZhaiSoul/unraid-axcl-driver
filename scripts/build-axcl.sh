#!/bin/bash
set -e

# ============================================================
# AXCL Driver Build Script (runs inside ghcr container)
# ============================================================
# Expected env vars:
#   KERNEL_VERSION  e.g. "6.18.35-Unraid"
#   AXCL_DEB_URL    e.g. "https://huggingface.co/..."
# ============================================================

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION required}"
AXCL_DEB_URL="${AXCL_DEB_URL:-https://huggingface.co/AXERA-TECH/AXCL/resolve/main/v3.10.2/axcl_host_x86_64_V3.10.2_20251111020143_NO5046.deb}"
WORKDIR="${GITHUB_WORKSPACE:-/workspace}"
BUILD_DIR="/tmp/axcl-build"
KERNEL_SRC="${BUILD_DIR}/linux-${KERNEL_VERSION}"
AXCL_SRC="${BUILD_DIR}/axcl_source"
OUT_DIR="${WORKDIR}/packages"

echo "=============================================="
echo " AXCL Driver Builder"
echo " Kernel: ${KERNEL_VERSION}"
echo "=============================================="

# Step 1: Download kernel source
echo ""
echo "[1/6] Downloading kernel source..."
mkdir -p "${BUILD_DIR}"

KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://github.com/ich777/unraid_kernel/releases/download/${KERNEL_VERSION}/${KERNEL_TARBALL}"

if ! wget -q --show-progress -O "${BUILD_DIR}/${KERNEL_TARBALL}" "${KERNEL_URL}"; then
    echo "ERROR: Failed to download kernel source from ${KERNEL_URL}"
    exit 1
fi

echo "  Extracting kernel source..."
mkdir -p "${KERNEL_SRC}"
# The tarball may or may not have a top-level directory, handle both
tar xf "${BUILD_DIR}/${KERNEL_TARBALL}" -C "${KERNEL_SRC}" --strip-components=1 2>/dev/null || \
tar xf "${BUILD_DIR}/${KERNEL_TARBALL}" -C "${KERNEL_SRC}"
rm -f "${BUILD_DIR}/${KERNEL_TARBALL}"

if [ ! -f "${KERNEL_SRC}/.config" ]; then
    echo "ERROR: .config not found in kernel source!"
    exit 1
fi

# Step 2: Setup kernel source symlinks for module building
echo ""
echo "[2/6] Preparing kernel source..."
HOST_KERNEL=$(uname -r)
mkdir -p /lib/modules/${HOST_KERNEL}
ln -sf "${KERNEL_SRC}" /lib/modules/${HOST_KERNEL}/build
ln -sf "${KERNEL_SRC}" /lib/modules/${HOST_KERNEL}/source

if [ ! -f "${KERNEL_SRC}/include/generated/autoconf.h" ]; then
    echo "  Running modules_prepare..."
    cd "${KERNEL_SRC}"
    make ARCH=x86 modules_prepare -j$(nproc) 2>&1 | tail -3
else
    echo "  Kernel source already prepared."
fi

# Step 3: Download and extract AXCL driver
echo ""
echo "[3/6] Downloading AXCL driver..."
cd "${BUILD_DIR}"
wget -q --show-progress -O axcl_host.deb "${AXCL_DEB_URL}"

echo "  Extracting AXCL driver..."
rm -rf "${AXCL_SRC}"
mkdir -p "${AXCL_SRC}"
cd "${AXCL_SRC}"
ar x "${BUILD_DIR}/axcl_host.deb"
tar xf data.tar.* -C .

# Step 4: Apply build patches
echo ""
echo "[4/6] Applying build patches..."

KRULES_MAK="${AXCL_SRC}/usr/src/axcl/build/projects/axcl_linux_x86_krules.mak"

# Patch 1: Fix hostname command not found in Slackware
sed -i 's#$(shell hostname)#$(shell hostname 2>/dev/null || echo unknown)#g' "${KRULES_MAK}"

# Patch 2: Suppress date-time warnings that become errors with GCC 15 + CONFIG_WERROR
sed -i 's#KCFLAGS\s*+=\s*-DIS_THIRD_PARTY_PLATFORM#KCFLAGS += -DIS_THIRD_PARTY_PLATFORM -Wno-error=date-time -Wno-date-time#' "${KRULES_MAK}"

echo "  Patches applied successfully."

# Step 5: Build driver modules
echo ""
echo "[5/6] Building AXCL driver modules..."
DRV_PATH="${AXCL_SRC}/usr/src/axcl/drv/pcie/driver"
cd "${DRV_PATH}"

# Clean first
make host=x86 clean 2>/dev/null || true

# Serial build to avoid Module.symvers races
if make host=x86 all -j1 2>&1; then
    echo ""
    echo "  Build SUCCESS!"
else
    echo ""
    echo "  Build FAILED!"
    exit 1
fi

# Run install to collect .ko files to standard location
make host=x86 install -j1 2>&1 | tail -3

# Step 6: Create package
echo ""
echo "[6/6] Creating driver package..."
PKG_NAME="axcl-driver-${KERNEL_VERSION}"
PKG_DIR="${BUILD_DIR}/${PKG_NAME}"
rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}"

# Copy kernel modules
KO_SRC="${AXCL_SRC}/usr/src/axcl/out/axcl_linux_x86/ko"
BUILD_KO_SRC="${AXCL_SRC}/usr/src/axcl/build/out/axcl_linux_x86/objs"
mkdir -p "${PKG_DIR}/lib/modules/${KERNEL_VERSION}/extra"

# First try standard install path
if ls "${KO_SRC}"/*.ko 2>/dev/null; then
    cp -v "${KO_SRC}"/*.ko "${PKG_DIR}/lib/modules/${KERNEL_VERSION}/extra/"
else
    # Fallback: collect from build output dirs
    for subdir in host_dev msg mmb axcl_host p2p_rc; do
        find "${BUILD_KO_SRC}/drv/pcie/driver/${subdir}" -name "*.ko" -exec cp -v {} "${PKG_DIR}/lib/modules/${KERNEL_VERSION}/extra/" \; 2>/dev/null || true
    done
    # Also net module
    find "${BUILD_KO_SRC}/drv/pcie/driver/net" -name "*.ko" -exec cp -v {} "${PKG_DIR}/lib/modules/${KERNEL_VERSION}/extra/" \; 2>/dev/null || true
fi

# Copy userspace files from .deb
cp -a "${AXCL_SRC}/etc" "${PKG_DIR}/"
cp -a "${AXCL_SRC}/lib/firmware" "${PKG_DIR}/lib/" 2>/dev/null || mkdir -p "${PKG_DIR}/lib" && cp -a "${AXCL_SRC}/lib/firmware" "${PKG_DIR}/lib/"
mkdir -p "${PKG_DIR}/usr"
cp -a "${AXCL_SRC}/usr/bin" "${PKG_DIR}/usr/" 2>/dev/null || true
cp -a "${AXCL_SRC}/usr/lib" "${PKG_DIR}/usr/" 2>/dev/null || true
cp -a "${AXCL_SRC}/usr/include" "${PKG_DIR}/usr/" 2>/dev/null || true
mkdir -p "${PKG_DIR}/usr/src/axcl"
cp -a "${AXCL_SRC}/usr/src/axcl/drv" "${PKG_DIR}/usr/src/axcl/" 2>/dev/null || true

echo ""
echo "  Package contents:"
echo "    Modules:"
ls -lh "${PKG_DIR}/lib/modules/${KERNEL_VERSION}/extra/"*.ko 2>/dev/null || echo "    WARNING: No .ko files!"
echo "    Config files:"
find "${PKG_DIR}/etc" -type f 2>/dev/null
echo "    Binaries: $(find "${PKG_DIR}/usr/bin" -type f 2>/dev/null | wc -l) files"
echo "    Libraries: $(find "${PKG_DIR}/usr/lib" -type f 2>/dev/null | wc -l) files"

# Create tarball
mkdir -p "${OUT_DIR}"
cd "${PKG_DIR}"
tar czf "${OUT_DIR}/${PKG_NAME}.tgz" .

# Generate MD5
cd "${OUT_DIR}"
md5sum "${PKG_NAME}.tgz" | awk '{print $1}' > "${PKG_NAME}.tgz.md5"
MD5_VAL=$(cat "${PKG_NAME}.tgz.md5")

echo ""
echo "=============================================="
echo " Build Complete!"
echo " Package: packages/${PKG_NAME}.tgz"
echo " Size:    $(du -h ${OUT_DIR}/${PKG_NAME}.tgz | cut -f1)"
echo " MD5:     ${MD5_VAL}"
echo "=============================================="

# Verify minimum .ko count
KO_COUNT=$(ls "${PKG_DIR}/lib/modules/${KERNEL_VERSION}/extra/"*.ko 2>/dev/null | wc -l)
if [ "${KO_COUNT}" -lt 5 ]; then
    echo "ERROR: Expected >=5 .ko files, found ${KO_COUNT}"
    exit 1
fi