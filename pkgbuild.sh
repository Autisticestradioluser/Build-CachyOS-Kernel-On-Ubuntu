#!/bin/bash
# CachyOS style Kernel Build Script for Ubuntu Noble 24.04
# Properly handles modern Ubuntu's merged-usr filesystem structure
# Outputs split Arch (.pkg.tar.zst) and Debian (.deb) packages for image & headers
set -eo pipefail

# ======================== COLOR & UTILS ========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
print_step()    { echo -e "\n${GREEN}==>${NC} ${YELLOW}$1${NC}"; }

# ======================== BUILD CONFIGURATION ========================
# All options can be overridden via environment variables: _var=value ./script.sh
_cachy_config=${_cachy_config:-yes}
_cpusched=${_cpusched:-bore}             # bore, bmq, hardened, cachyos, eevdf, rt, rt-bore
_makenconfig=${_makenconfig:-no}
_makexconfig=${_makexconfig:-no}
_localmodcfg=${_localmodcfg:-no}
_localmodcfg_path=${_localmodcfg_path:-"$HOME/.config/modprobed.db"}
_use_current=${_use_current:-no}
_cc_harder=${_cc_harder:-yes}
# Default CPU governor: performance, powersave, or schedutil (upstream CachyOS default)
_default_gov=${_default_gov:-performance}
_tcp_bbr3=${_tcp_bbr3:-yes}
_HZ_ticks=${_HZ_ticks:-500}
_tickrate=${_tickrate:-full}
_preempt=${_preempt:-full}
_hugepage=${_hugepage:-always}
_processor_opt=${_processor_opt:-native}
_use_llvm_lto=${_use_llvm_lto:-full}     # none, thin, full, thin-dist
_use_lto_suffix=${_use_lto_suffix:-yes}
_use_gcc_suffix=${_use_gcc_suffix:-no}
_use_kcfi=${_use_kcfi:-no}
_build_zfs=${_build_zfs:-no}
_build_debug=${_build_debug:-no}         # yes = build & package headers
_autofdo=${_autofdo:-no}
_autofdo_profile_name=${_autofdo_profile_name:-}
_propeller=${_propeller:-no}
_propeller_profiles=${_propeller_profiles:-no}
_build_r8125=${_build_r8125:-yes}

# Package targets (replaces _build_mkinitcpiod_preset)
_build_archpkg=${_build_archpkg:-yes}    # yes = build Arch .pkg.tar.zst + mkinitcpio preset
_build_deb=${_build_deb:-yes}            # yes = build Debian .deb

# Kernel version info
_major=6.18
_minor=42
_tagrel=1
pkgver=${_major}.${_minor}
_stable=${_major}.${_minor}
pkgrel=1
_srcver=${_major}.${_minor}-${_tagrel}
_srcname=cachyos-${_srcver}

# Checksums (Update per release)
_kernel_b2sum=${_kernel_b2sum:-e322057f183bf666741ec12d2d64f681d9ba7bc4e4326354656ca23be5ecfb5ab3ab2ef494ddb54605f4ff1d5bba5a08493760eea9a36860080eafdb369a0321}
_config_b2sum=${_config_b2sum:-81fafd3adcaf3b690d8d4791693e68c7ae921d103ebfd70e8d0ae15cd05ecde5e6672ae43c3a7875686d883c1f5b82d2c8b37b40aee8dcb0563913f9dd6469b6}

# GPG keys for signature verification
_validpgpkeys=(
    E18447AC260021D31F3FF6C4C8A2A4774B8B63C4  # Eric Naim <dnaim@cachyos.org>
    E8B9AA39F054E30E8290D492C3C4820857F654FE  # Peter Jung <admin@ptr1337.dev>
)

_patchsource="https://raw.githubusercontent.com/cachyos/kernel-patches/master/${_major}"
BUILD_DIR="${PWD}/linux-cachyos-${_cpusched}-${_stable}-lts-${pkgrel}-${_processor_opt}"
SRC_DIR="${BUILD_DIR}/src"
DOWNLOAD_DIR="${BUILD_DIR}/downloads"

# Prevent sourcing
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]:-${0}}")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]:-${0}}")"
SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH" 2>/dev/null || realpath "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")"
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    print_error "This script is being sourced. Please run it, don't source it:"
    echo "  bash ${SCRIPT_PATH}"
    return 1 2>/dev/null || exit 1
fi

# ======================== PRE-CHECKS & DEPS ========================
print_step "Step 1: Checking Ubuntu Noble System and usr-merge status"
if ! command -v lsb_release >/dev/null 2>&1 || ! lsb_release -cs 2>/dev/null | grep -q "noble"; then
    print_warning "This script is optimized for Ubuntu Noble 24.04. Current system: $(lsb_release -cs 2>/dev/null || echo 'Unknown')"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

print_info "Checking usr-merge status..."
USR_MERGED=false
if [ -L "/lib" ] && [ "$(readlink -f /lib)" = "/usr/lib" ]; then
    USR_MERGED=true
    print_success "System is using merged-usr layout (modern Ubuntu)"
else
    print_warning "System appears to NOT be using merged-usr layout"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

print_step "Step 2: Dependency Check"
REQUIRED_PACKAGES=(
    build-essential libncurses-dev libelf-dev libssl-dev flex bison
    cpio gettext python3 perl zstd wget curl git pkg-config kmod fakeroot dwarves bc
)
if [ "$_cpusched" != "rt" ] && [ "$_cpusched" != "rt-bore" ]; then
    REQUIRED_PACKAGES+=(rustc rust-src bindgen)
fi
if [[ "$_use_llvm_lto" == "thin" || "$_use_llvm_lto" == "full" || "$_use_llvm_lto" == "thin-dist" ]]; then
    REQUIRED_PACKAGES+=(clang-21 llvm-21 lld-21 libclang-21-dev)
fi
[[ "$_build_archpkg" == "yes" ]] && REQUIRED_PACKAGES+=(libarchive-tools)
[[ "$_build_deb" == "yes" ]] && REQUIRED_PACKAGES+=(dpkg-dev)

MISSING_PACKAGES=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || MISSING_PACKAGES+=("$pkg")
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    print_warning "Missing packages detected!"
    print_info "Please run: sudo apt update && sudo apt install -y ${MISSING_PACKAGES[*]}"
    read -p "Continue without installing? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Robust fakeroot restart
if [[ $EUID -ne 0 && -z "$FAKEROOTKEY" ]]; then
    print_warning "Script not running under fakeroot."
    if command -v fakeroot >/dev/null 2>&1; then
        if [ ! -x "$SCRIPT_PATH" ]; then
            print_info "Fixing execute permission and restarting under fakeroot..."
            chmod +x "$SCRIPT_PATH"
        fi
        exec fakeroot bash "$SCRIPT_PATH"
    else
        print_error "fakeroot is not installed!"
        exit 1
    fi
fi

# ======================== PREPARE & DOWNLOAD ========================
print_step "Step 3: Creating Build Directory Structure"
mkdir -p "${SRC_DIR}" "${DOWNLOAD_DIR}"
cd "${BUILD_DIR}"

print_step "Step 4: Downloading Kernel Sources and Patches"
# Import GPG keys
print_info "Importing CachyOS kernel signing keys..."
for key in "${_validpgpkeys[@]}"; do
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key" 2>/dev/null || \
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key" 2>/dev/null || true
done

if [ ! -f "${DOWNLOAD_DIR}/${_srcname}.tar.gz" ]; then
    print_info "Downloading kernel..."
    wget -P "${DOWNLOAD_DIR}" "https://github.com/CachyOS/linux/releases/download/${_srcname}/${_srcname}.tar.gz"
fi
[[ "$(b2sum "${DOWNLOAD_DIR}/${_srcname}.tar.gz" | cut -d' ' -f1)" == "$_kernel_b2sum" ]] || print_error "Kernel b2sum mismatch"

# Download and verify kernel signature
if [ ! -f "${DOWNLOAD_DIR}/${_srcname}.tar.gz.asc" ]; then
    print_info "Downloading kernel signature..."
    wget -P "${DOWNLOAD_DIR}" "https://github.com/CachyOS/linux/releases/download/${_srcname}/${_srcname}.tar.gz.asc"
fi
print_info "Verifying kernel signature..."
gpg --batch --verify "${DOWNLOAD_DIR}/${_srcname}.tar.gz.asc" "${DOWNLOAD_DIR}/${_srcname}.tar.gz" || print_error "Kernel signature verification failed!"

if [ ! -f "${DOWNLOAD_DIR}/config" ]; then
    wget -O "${DOWNLOAD_DIR}/config" "https://raw.githubusercontent.com/CachyOS/linux-cachyos/refs/heads/master/linux-cachyos-lts/config"
fi
[[ "$(b2sum "${DOWNLOAD_DIR}/config" | cut -d' ' -f1)" == "$_config_b2sum" ]] || print_error "Config b2sum mismatch"

case "$_cpusched" in
    cachyos|bore|rt-bore|hardened)
        [ ! -f "${DOWNLOAD_DIR}/0001-bore-cachy.patch" ] && wget -P "${DOWNLOAD_DIR}" "${_patchsource}/sched/0001-bore-cachy.patch" ;;
    bmq)
        [ ! -f "${DOWNLOAD_DIR}/0001-prjc-cachy.patch" ] && wget -P "${DOWNLOAD_DIR}" "${_patchsource}/sched/0001-prjc-cachy.patch" ;;
esac
[ "$_cpusched" = "hardened" ] && wget -q -N -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/0001-hardened.patch"
[[ "$_cpusched" == "rt" || "$_cpusched" == "rt-bore" ]] && wget -q -N -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/0001-rt-i915.patch"
[[ "$_use_llvm_lto" != "none" ]] && [ ! -f "${DOWNLOAD_DIR}/dkms-clang.patch" ] && wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/dkms-clang.patch"
[ "$_build_zfs" = "yes" ] && [ ! -d "${SRC_DIR}/zfs" ] && git clone --revision=6330a45b06d20125de679aae5f63ba14082671ef --depth=1 https://github.com/cachyos/zfs.git "${SRC_DIR}/zfs"
[ "$_build_r8125" = "yes" ] && [ ! -d "${SRC_DIR}/r8125" ] && git clone --branch=rtl8125bp-fix-v5-guard-eee --depth=1 https://github.com/Autisticestradioluser/r8125.git "${SRC_DIR}/r8125"

# ======================== EXTRACT & CONFIGURE ========================
print_step "Step 5: Extracting and Preparing Sources"
cd "${SRC_DIR}"
tar -xf "${DOWNLOAD_DIR}/${_srcname}.tar.gz"
cd "${_srcname}"

echo "-$pkgrel" > localversion.10-pkgrel
echo "-cachyos-${_cpusched}" > localversion.20-pkgname

print_step "Step 6: Applying Patches"
[[ "$_use_llvm_lto" != "none" ]] && patch -Np1 < "${DOWNLOAD_DIR}/dkms-clang.patch"
case "$_cpusched" in
    cachyos|bore|rt-bore|hardened) patch -Np1 < "${DOWNLOAD_DIR}/0001-bore-cachy.patch" ;;
    bmq) patch -Np1 < "${DOWNLOAD_DIR}/0001-prjc-cachy.patch" ;;
esac
[ "$_cpusched" = "hardened" ] && patch -Np1 < "${DOWNLOAD_DIR}/0001-hardened.patch"
[[ "$_cpusched" == "rt" || "$_cpusched" == "rt-bore" ]] && patch -Np1 < "${DOWNLOAD_DIR}/0001-rt-i915.patch"

print_step "Step 7: Configuring Kernel"
cp "${DOWNLOAD_DIR}/config" .config
BUILD_FLAGS=()
[[ "$_use_llvm_lto" != "none" ]] && BUILD_FLAGS=(CC=clang-21 LD=ld.lld-21 LLVM=-21 LLVM_IAS=1)

[ -n "$_processor_opt" ] && MARCH="${_processor_opt^^}" && case "$MARCH" in
    GENERIC_V[1-4]) scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU --set-val X86_64_VERSION "${MARCH//GENERIC_V}" ;;
    ZEN4) scripts/config -d GENERIC_CPU -e MZEN4 -d X86_NATIVE_CPU ;;
    NATIVE) scripts/config -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU ;;
esac

[ "$_cachy_config" = "yes" ] && scripts/config -e CACHY

case "$_cpusched" in
    cachyos|bore|hardened) scripts/config -e SCHED_BORE ;;
    bmq) scripts/config -e SCHED_ALT -e SCHED_BMQ ;;
    rt) scripts/config -e PREEMPT_RT ;;
    rt-bore) scripts/config -e SCHED_BORE -e PREEMPT_RT ;;
esac

[ "$_use_kcfi" = "yes" ] && scripts/config -e ARCH_SUPPORTS_CFI_CLANG -e CFI_CLANG -e CFI_AUTO_DEFAULT

case "$_use_llvm_lto" in
    thin) scripts/config -e LTO_CLANG_THIN ;; thin-dist) scripts/config -e LTO_CLANG_THIN_DIST ;;
    full) scripts/config -e LTO_CLANG_FULL ;; none) scripts/config -e LTO_NONE ;;
esac

scripts/config -d HZ_300 -e "HZ_${_HZ_ticks}" --set-val HZ "${_HZ_ticks}"
# Backward compat: _per_gov=yes → performance, _per_gov=no → schedutil
if [ -n "${_per_gov:-}" ]; then
    if [ "$_per_gov" = "yes" ]; then _default_gov=performance; else _default_gov=schedutil; fi
fi

case "$_default_gov" in
    performance)
        print_info "Setting performance governor as default..."
        scripts/config -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL -e CPU_FREQ_DEFAULT_GOV_PERFORMANCE
        ;;
    powersave)
        print_info "Setting powersave governor as default..."
        scripts/config -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL -d CPU_FREQ_DEFAULT_GOV_PERFORMANCE -e CPU_FREQ_DEFAULT_GOV_POWERSAVE
        ;;
    schedutil)
        print_info "Using schedutil governor as default (upstream CachyOS default)..."
        scripts/config -d CPU_FREQ_DEFAULT_GOV_PERFORMANCE -d CPU_FREQ_DEFAULT_GOV_POWERSAVE -e CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
        ;;
    *)
        print_error "Invalid _default_gov: '$_default_gov'. Use: performance, powersave, or schedutil"
        ;;
esac

case "$_tickrate" in
    periodic) scripts/config -d NO_HZ_IDLE -d NO_HZ_FULL -d NO_HZ -d NO_HZ_COMMON -e HZ_PERIODIC ;;
    idle) scripts/config -d HZ_PERIODIC -d NO_HZ_FULL -e NO_HZ_IDLE -e NO_HZ -e NO_HZ_COMMON ;;
    full) scripts/config -d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE -e NO_HZ_FULL_NODEF -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON -e CONTEXT_TRACKING ;;
esac

[[ "$_cpusched" != "rt" && "$_cpusched" != "rt-bore" ]] && case "$_preempt" in
    full) scripts/config -e PREEMPT_DYNAMIC -e PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE ;;
    lazy) scripts/config -e PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -e PREEMPT_LAZY -d PREEMPT_NONE ;;
    voluntary) scripts/config -d PREEMPT_DYNAMIC -d PREEMPT -e PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE ;;
    none) scripts/config -d PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -e PREEMPT_NONE ;;
esac

[ "$_cc_harder" = "yes" ] && scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_PERFORMANCE_O3
[ "$_tcp_bbr3" = "yes" ] && scripts/config -m TCP_CONG_CUBIC -d DEFAULT_CUBIC -e TCP_CONG_BBR -e DEFAULT_BBR --set-str DEFAULT_TCP_CONG bbr -m NET_SCH_FQ_CODEL -e NET_SCH_FQ -d CONFIG_DEFAULT_FQ_CODEL -e CONFIG_DEFAULT_FQ

case "$_hugepage" in
    always) scripts/config -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS ;;
    madvise) scripts/config -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE ;;
esac

scripts/config -e USER_NS
[ "$_use_current" = "yes" ] && [ -f /proc/config.gz ] && zcat /proc/config.gz > .config
[ "$_localmodcfg" = "yes" ] && [ -e "$_localmodcfg_path" ] && make "${BUILD_FLAGS[@]}" LSMOD="${_localmodcfg_path}" localmodconfig

make "${BUILD_FLAGS[@]}" olddefconfig
make -s kernelrelease > version
KERNEL_VERSION=$(cat version)
print_success "Prepared kernel version: ${KERNEL_VERSION}"

[ "$_makenconfig" = "yes" ] && make "${BUILD_FLAGS[@]}" nconfig
[ "$_makexconfig" = "yes" ] && make "${BUILD_FLAGS[@]}" xconfig

cp .config "${BUILD_DIR}/config-${KERNEL_VERSION}"

# ======================== BUILD ========================
print_step "Step 8: Building Kernel"
cd "${SRC_DIR}/${_srcname}"
make "${BUILD_FLAGS[@]}" -j"$(nproc)" all
make -C tools/bpf/bpftool vmlinux.h feature-clang-bpf-co-re=1

[ "$_build_zfs" = "yes" ] && {
    cd "${SRC_DIR}/zfs"
    CONFIGURE_FLAGS=()
    [[ "$_use_llvm_lto" != "none" ]] && CONFIGURE_FLAGS+=("KERNEL_LLVM=1")
    ./autogen.sh && sed -i "s|\$(uname -r)|${KERNEL_VERSION}|g" configure
    ./configure "${CONFIGURE_FLAGS[@]}" --prefix=/usr --sysconfdir=/etc --sbindir=/usr/bin --libdir=/usr/lib --datadir=/usr/share --includedir=/usr/include --with-udevdir=/lib/udev --libexecdir=/usr/lib/zfs --with-config=kernel --with-linux="${SRC_DIR}/${_srcname}"
    make "${BUILD_FLAGS[@]}"
    cd "${SRC_DIR}/${_srcname}"
}

[ "$_build_r8125" = "yes" ] && {
    cd "${SRC_DIR}/r8125"
    make "${BUILD_FLAGS[@]}" KERNELDIR="${SRC_DIR}/${_srcname}" modules
    cd "${SRC_DIR}/${_srcname}"
}

# ======================== STAGING ========================
print_step "Step 9: Preparing Installation Archive - USR-MERGE AWARE VERSION"
INSTALL_DIR="${BUILD_DIR}/install"
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/boot"

if [ "$USR_MERGED" = true ]; then
    MODULES_BASE_DIR="${INSTALL_DIR}/usr/lib/modules"
else
    MODULES_BASE_DIR="${INSTALL_DIR}/lib/modules"
fi
mkdir -p "${MODULES_BASE_DIR}/${KERNEL_VERSION}"

cd "${SRC_DIR}/${_srcname}"
install -Dm644 "$(make -s image_name)" "${INSTALL_DIR}/boot/vmlinuz-${KERNEL_VERSION}"
install -Dm644 System.map "${INSTALL_DIR}/boot/System.map-${KERNEL_VERSION}"
install -Dm644 .config "${INSTALL_DIR}/boot/config-${KERNEL_VERSION}"

if [ "$USR_MERGED" = true ]; then
    make INSTALL_MOD_PATH="${INSTALL_DIR}/usr" INSTALL_MOD_STRIP=1 modules_install
else
    make INSTALL_MOD_PATH="${INSTALL_DIR}" INSTALL_MOD_STRIP=1 modules_install
fi

sign_modules() {
    local moduledir="$1"
    if grep -q "CONFIG_MODULE_SIG=y" .config; then
        print_info "Signing kernel modules..."
        local sign_script="${SRC_DIR}/${_srcname}/scripts/sign-file"
        local sign_key="$(grep -Po 'CONFIG_MODULE_SIG_KEY="\K[^"]*' .config)"
        [[ ! "$sign_key" =~ ^/ ]] && sign_key="${SRC_DIR}/${_srcname}/${sign_key}"
        local sign_cert="${SRC_DIR}/${_srcname}/certs/signing_key.x509"
        local hash_algo="$(grep -Po 'CONFIG_MODULE_SIG_HASH="\K[^"]*' .config)"
        if [ -f "$sign_script" ] && [ -f "$sign_key" ] && [ -f "$sign_cert" ]; then
            find "$moduledir" -type f -name '*.ko' -print -exec "${sign_script}" "${hash_algo}" "${sign_key}" "${sign_cert}" '{}' \;
        fi
    fi
}

[ "$_build_zfs" = "yes" ] && {
    ZFS_DIR="${MODULES_BASE_DIR}/${KERNEL_VERSION}/kernel/extra"
    mkdir -p "${ZFS_DIR}"
    find "${SRC_DIR}/zfs/module" -name "*.ko" -exec cp {} "${ZFS_DIR}/" \;
    sign_modules "${ZFS_DIR}"
}

[ "$_build_r8125" = "yes" ] && {
    print_info "Installing r8125 module"
    r8125_DIR="${MODULES_BASE_DIR}/${KERNEL_VERSION}/kernel/extra"
    mkdir -p "${r8125_DIR}"
    cp "${SRC_DIR}/r8125/src"/*.ko "$r8125_DIR/"
    sign_modules "${r8125_DIR}"
}

print_info "Compressing kernel modules with zstd..."
find "${MODULES_BASE_DIR}/${KERNEL_VERSION}" -type f -name '*.ko' | while read -r module; do
    zstd --rm -T0 -19 "$module"
done

if [ "$USR_MERGED" = true ]; then
    depmod -b "${INSTALL_DIR}/usr" "${KERNEL_VERSION}"
else
    depmod -b "${INSTALL_DIR}" "${KERNEL_VERSION}"
fi
[ ! -f "${MODULES_BASE_DIR}/${KERNEL_VERSION}/modules.builtin" ] && cp "${SRC_DIR}/${_srcname}/modules.builtin" "${MODULES_BASE_DIR}/${KERNEL_VERSION}/" 2>/dev/null || true

# Headers staging
if [ "$_build_debug" = "yes" ]; then
    print_info "Installing kernel headers..."
    HEADERS_DIR="${INSTALL_DIR}/usr/src/linux-headers-${KERNEL_VERSION}"
    mkdir -p "${HEADERS_DIR}/include" "${HEADERS_DIR}/arch"
    cp -r "${SRC_DIR}/${_srcname}/include/config" "${HEADERS_DIR}/include"
    cp -r "${SRC_DIR}/${_srcname}/include/generated" "${HEADERS_DIR}/include"
    cp -r "${SRC_DIR}/${_srcname}/scripts" "${HEADERS_DIR}/"
    cp -r "${SRC_DIR}/${_srcname}/arch/x86" "${HEADERS_DIR}/arch/"
    cp -r "${SRC_DIR}/${_srcname}/tools" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/vmlinux" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/Module.symvers" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/.config" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/Makefile" "${HEADERS_DIR}/"
    echo "${KERNEL_VERSION}" > "${HEADERS_DIR}/version"
fi

fix_permissions() {
    local root="${INSTALL_DIR}"
    print_info "=== Fixing permissions for ${root} ==="
    find "${root}" -type d -exec chmod 0755 {} +
    find "${root}" -type f -exec chmod 0644 {} +
    find "${root}" -perm -g=w -exec chmod g-w {} +
}
fix_permissions

# ======================== PACKAGING ========================
print_step "Step 10: Packaging"

# Generate dynamic description
DESC="Linux ${KERNEL_VERSION} CachyOS kernel [${_cpusched^^} sched] [${_preempt} preempt] [${_HZ_ticks}Hz] [BBRv3]"
[[ "$_use_llvm_lto" != "none" ]] && DESC+=" [Clang-${_use_llvm_lto^^} LTO]" || DESC+=" [GCC]"
[[ "$_cc_harder" == "yes" ]] && DESC+=" [-O3]"
[[ "$_hugepage" == "always" ]] && DESC+=" [THP=always]"
[[ "$_build_zfs" == "yes" ]] && DESC+=" [ZFS]"
[[ "$_build_r8125" == "yes" ]] && DESC+=" [r8125]"

# --- ARCH PACKAGING ---
if [[ "$_build_archpkg" == "yes" ]]; then
    print_info "Building Arch packages..."
    ARCH_IMG="${BUILD_DIR}/pkg-arch-img"
    ARCH_HDR="${BUILD_DIR}/pkg-arch-hdr"
    rm -rf "${ARCH_IMG}" "${ARCH_HDR}"
    mkdir -p "${ARCH_IMG}" "${ARCH_HDR}"

    # Image tree
    cp -a "${INSTALL_DIR}/boot" "${ARCH_IMG}/"
    mkdir -p "${ARCH_IMG}/usr/lib"
    
    # Strict Arch Filesystem Layout: Always use /usr/lib/modules regardless of host USR_MERGED status
    if [ "$USR_MERGED" = true ]; then
        cp -a "${INSTALL_DIR}/usr/lib/modules" "${ARCH_IMG}/usr/lib/"
    else
        mkdir -p "${ARCH_IMG}/usr/lib/modules"
        cp -a "${INSTALL_DIR}/lib/modules/${KERNEL_VERSION}" "${ARCH_IMG}/usr/lib/modules/"
    fi
    cp -a "${INSTALL_DIR}/etc" "${ARCH_IMG}/" 2>/dev/null || true

    # mkinitcpio preset
    mkdir -p "${ARCH_IMG}/etc/mkinitcpio.d"
    cat > "${ARCH_IMG}/etc/mkinitcpio.d/kernel-${KERNEL_VERSION}.preset" << EOF
ALL_kver="/boot/vmlinuz-${KERNEL_VERSION}"
PRESETS=('default' 'fallback')
default_image="/boot/initramfs-${KERNEL_VERSION}.img"
fallback_image="/boot/initramfs-${KERNEL_VERSION}-fallback.img"
fallback_options="-S autodetect"
EOF

    # Implement the .INSTALL Script (Arch standard name: .INSTALL with leading dot)
    cat > "${ARCH_IMG}/.INSTALL" << EOF
post_install() {
    depmod ${KERNEL_VERSION}
}
post_upgrade() {
    depmod ${KERNEL_VERSION}
}
post_remove() {
    depmod ${KERNEL_VERSION}
}
EOF

    # Arch pkgver: hyphens become dots, pkgrel appended after final hyphen
    PACMAN_PKGVER="${KERNEL_VERSION//-/.}-${pkgrel}"
    PKG_IMG_FILENAME="linux-cachyos-${_cpusched}-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"

    # Calculate size for .PKGINFO (installed size only, excluding metadata files)
    PKG_SIZE=$(find "${ARCH_IMG}" -mindepth 1 -maxdepth 1 \
        ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' \
        -exec du -sb {} + | awk '{sum+=$1} END {print sum+0}')

    # Strict Arch PKGINFO format
    cat > "${ARCH_IMG}/.PKGINFO" << EOF
pkgname = linux-cachyos-${_cpusched}
pkgbase = linux-cachyos
pkgver = ${PACMAN_PKGVER}
pkgdesc = ${DESC}
url = https://github.com/CachyOS/linux-cachyos
builddate = $(date +%s)
packager = GitHub User
size = ${PKG_SIZE}
arch = x86_64
license = GPL-2.0-only
depends = coreutils
depends = kmod
install = .INSTALL
EOF

    cat > "${ARCH_IMG}/.BUILDINFO" << EOF
format = 1
pkgname = linux-cachyos-${_cpusched}
pkgver = ${PACMAN_PKGVER}
EOF

    # Correct .MTREE Generation (exclude all metadata files)
    cd "${ARCH_IMG}"
    find . -mindepth 1 -maxdepth 1 ! -name '.MTREE' ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.INSTALL' -print0 | \
        bsdtar -czf .MTREE --format=mtree --options='!gname,!uname' --null -T -
    cd - >/dev/null

    # Enforce Archive Ordering using piped zstd (bsdtar --zstd not supported on Ubuntu)
    # Order: .PKGINFO, .MTREE, .BUILDINFO, .INSTALL, then directories/files
    # Root ownership is handled by fakeroot wrapper
    cd "${ARCH_IMG}"
    bsdtar -cf - \
        .PKGINFO .MTREE .BUILDINFO .INSTALL \
        $(find . -mindepth 1 -maxdepth 1 -type d | sort) \
        $(find . -mindepth 1 -maxdepth 1 -type f ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' | sort) | \
        zstd -19 -T0 -o "${BUILD_DIR}/${PKG_IMG_FILENAME}"
    cd - >/dev/null

    # Final Validation Step
    if ! bsdtar -tf "${BUILD_DIR}/${PKG_IMG_FILENAME}" | head -n 1 | grep -q "^\.PKGINFO$"; then
        print_error "Arch package validation failed: .PKGINFO is not the first file in the archive."
    fi
    print_success "Arch image: ${BUILD_DIR}/${PKG_IMG_FILENAME}"

    # Headers tree
    if [ "$_build_debug" = "yes" ]; then
        mkdir -p "${ARCH_HDR}/usr/src" "${ARCH_HDR}/usr/lib/modules/${KERNEL_VERSION}"
        cp -a "${INSTALL_DIR}/usr/src/linux-headers-${KERNEL_VERSION}" "${ARCH_HDR}/usr/src/"
        ln -srf "${ARCH_HDR}/usr/src/linux-headers-${KERNEL_VERSION}" "${ARCH_HDR}/usr/lib/modules/${KERNEL_VERSION}/build"

        PKG_HDR_FILENAME="linux-cachyos-${_cpusched}-headers-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"

        # Create .INSTALL script for headers (runs depmod on install/upgrade/remove)
        cat > "${ARCH_HDR}/.INSTALL" << EOF
post_install() {
    depmod ${KERNEL_VERSION}
}
post_upgrade() {
    depmod ${KERNEL_VERSION}
}
post_remove() {
    depmod ${KERNEL_VERSION}
}
EOF

        # Calculate size for headers .PKGINFO (exclude metadata files)
        cd "${ARCH_HDR}"
        HDR_PKG_SIZE=$(find . -mindepth 1 -maxdepth 1 ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' -print0 | \
            xargs -0 du -sb 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        cd - >/dev/null

        cat > "${ARCH_HDR}/.PKGINFO" << EOF
pkgname = linux-cachyos-${_cpusched}-headers
pkgbase = linux-cachyos
pkgver = ${PACMAN_PKGVER}
pkgdesc = Headers for ${DESC}
url = https://github.com/CachyOS/linux-cachyos
builddate = $(date +%s)
packager = GitHub User
size = ${HDR_PKG_SIZE}
arch = x86_64
license = GPL-2.0-only
depends = binutils
depends = glibc
depends = libelf
depends = libgcc
depends = openssl
depends = pahole
depends = xxhash
depends = zlib
depends = zstd
depends = linux-cachyos-${_cpusched}=${PACMAN_PKGVER}
install = .INSTALL
EOF

        cat > "${ARCH_HDR}/.BUILDINFO" << EOF
format = 1
pkgname = linux-cachyos-${_cpusched}-headers
pkgver = ${PACMAN_PKGVER}
EOF

        # Correct .MTREE Generation for headers (exclude ALL metadata files)
        cd "${ARCH_HDR}"
        find . -mindepth 1 -maxdepth 1 ! -name '.MTREE' ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.INSTALL' -print0 | \
            bsdtar -czf .MTREE --format=mtree --options='!gname,!uname' --null -T -
        cd - >/dev/null

        # Create package using tar | zstd pipeline (replaces unsupported bsdtar --zstd flags)
        # Order: .PKGINFO first, then .MTREE, .BUILDINFO, .INSTALL, then directories/files
        # Root ownership is handled by fakeroot wrapper
        cd "${ARCH_HDR}"
        tar -cf - \
            .PKGINFO .MTREE .BUILDINFO .INSTALL \
            $(find . -mindepth 1 -maxdepth 1 -type d | sort) \
            $(find . -mindepth 1 -maxdepth 1 -type f ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' | sort) | \
            zstd -19 -T0 -o "${BUILD_DIR}/${PKG_HDR_FILENAME}"
        cd - >/dev/null

        # Final Validation Step for headers
        if ! bsdtar -tf "${BUILD_DIR}/${PKG_HDR_FILENAME}" | head -n 1 | grep -q "^\.PKGINFO$"; then
            print_error "Arch headers package validation failed: .PKGINFO is not the first file in the archive."
        fi
        print_success "Arch headers: ${BUILD_DIR}/${PKG_HDR_FILENAME}"
    fi
fi

# --- DEBIAN PACKAGING ---
if [[ "$_build_deb" == "yes" ]]; then
    print_info "Building Debian packages..."
    
    # Debian Policy compliance: Version strings cannot have hyphens in the debian_revision.
    # We replace hyphens in KERNEL_VERSION with '+' to ensure a valid, single-component version string.
    DEB_VERSION="${KERNEL_VERSION//-/+}"
    
    # Co-installable package names (include kernel version to allow side-by-side installations)
    DEB_IMG_PKG="linux-image-${KERNEL_VERSION}"
    DEB_HDR_PKG="linux-headers-${KERNEL_VERSION}"
    
    DEB_IMG="${BUILD_DIR}/pkg-deb-img"
    DEB_HDR="${BUILD_DIR}/pkg-deb-hdr"
    rm -rf "${DEB_IMG}" "${DEB_HDR}"
    
    # --- IMAGE PACKAGE ---
    mkdir -p "${DEB_IMG}/DEBIAN" "${DEB_IMG}/boot"
    
    # Determine correct module path based on usr-merge status
    if [ "$USR_MERGED" = true ]; then
        MODULES_PATH="usr/lib/modules"
        mkdir -p "${DEB_IMG}/usr/lib/modules"
        cp -a "${INSTALL_DIR}/usr/lib/modules/${KERNEL_VERSION}" "${DEB_IMG}/usr/lib/modules/"
    else
        MODULES_PATH="lib/modules"
        mkdir -p "${DEB_IMG}/lib/modules"
        cp -a "${INSTALL_DIR}/lib/modules/${KERNEL_VERSION}" "${DEB_IMG}/lib/modules/"
    fi
    
    cp -a "${INSTALL_DIR}/boot/"* "${DEB_IMG}/boot/"
    
    cat > "${DEB_IMG}/DEBIAN/control" << EOF
Package: ${DEB_IMG_PKG}
Version: ${DEB_VERSION}
Section: kernel
Priority: optional
Maintainer: GitHub User <github@example.com>
Architecture: amd64
Depends: initramfs-tools (>= 0.125) | linux-initramfs-tool, kmod, linux-base (>= 4.0~)
Recommends: dkms
Description: ${DESC}
 CachyOS-patched Linux kernel for Debian/Ubuntu. Includes zstd modules,
 BBRv3, and optimized scheduling/preemption.
EOF
    [[ "$_build_r8125" == "yes" ]] && echo "Conflicts: r8169-dkms" >> "${DEB_IMG}/DEBIAN/control"
    
    # preinst
    cat > "${DEB_IMG}/DEBIAN/preinst" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'
image_path='/boot/vmlinuz-${KERNEL_VERSION}'

if [ "\$1" = abort-upgrade ] || [ "\$1" = abort-deconfigure ]; then exit 0; fi

# Handle usr-merge dynamically
if [ -L /lib ] && [ "\$(readlink -f /lib)" = "/usr/lib" ]; then
    moddir="/usr/lib/modules/\$version"
else
    moddir="/lib/modules/\$version"
fi

if [ "\$1" = install ] || [ "\$1" = upgrade ]; then
    mkdir -p "\$moddir"
fi

if [ -d /etc/kernel/preinst.d ]; then
    DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version --arg=\$image_path /etc/kernel/preinst.d || true
fi
exit 0
EOF
    chmod +x "${DEB_IMG}/DEBIAN/preinst"
    
    # postinst (Debian Policy §10.3)
    cat > "${DEB_IMG}/DEBIAN/postinst" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'
image_path='/boot/vmlinuz-${KERNEL_VERSION}'

if [ "\$1" != configure ]; then exit 0; fi

# Handle usr-merge dynamically
if [ -L /lib ] && [ "\$(readlink -f /lib)" = "/usr/lib" ]; then
    moddir="/usr/lib/modules/\$version"
else
    moddir="/lib/modules/\$version"
fi

if [ -d "\$moddir" ]; then
    depmod "\$version" || true
fi

# Regenerate initramfs
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -c -k "\$version" 2>/dev/null || update-initramfs -u -k "\$version" || true
fi

# Rebuild DKMS modules if dkms is installed
if command -v dkms >/dev/null 2>&1; then
    dkms autoinstall -k "\$version" 2>/dev/null || true
fi

# Update bootloader
if command -v update-grub >/dev/null 2>&1; then
    update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg || true
fi

if [ -d /etc/kernel/postinst.d ]; then
    DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version --arg=\$image_path /etc/kernel/postinst.d || true
fi

exit 0
EOF
    chmod +x "${DEB_IMG}/DEBIAN/postinst"
    
    # prerm (Debian Policy §10.3)
    cat > "${DEB_IMG}/DEBIAN/prerm" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'
image_path='/boot/vmlinuz-${KERNEL_VERSION}'

if [ "\$1" != remove ] && [ "\$1" != purge ]; then exit 0; fi

if command -v linux-check-removal >/dev/null 2>&1; then
    linux-check-removal "\$version" || true
fi

# Remove initramfs
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -d -k "\$version" 2>/dev/null || true
fi

if [ -d /etc/kernel/prerm.d ]; then
    DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version --arg=\$image_path /etc/kernel/prerm.d || true
fi

exit 0
EOF
    chmod +x "${DEB_IMG}/DEBIAN/prerm"
    
    # postrm (Debian Policy §10.3) - Use rm -rf on purge to prevent "Directory not empty"
    cat > "${DEB_IMG}/DEBIAN/postrm" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'
image_path='/boot/vmlinuz-${KERNEL_VERSION}'

if [ "\$1" = purge ]; then
    # Aggressively clean up module directories to prevent "Directory not empty" errors
    # caused by leftover DKMS or external modules.
    rm -rf "/lib/modules/\$version" 2>/dev/null || true
    rm -rf "/usr/lib/modules/\$version" 2>/dev/null || true
    
    # Remove any dangling symlinks in /lib/modules that point to this version
    if [ -d /lib/modules ]; then
        find /lib/modules -maxdepth 1 -type l -lname "*\$version*" -delete 2>/dev/null || true
    fi

    # Update bootloader after complete removal
    if command -v update-grub >/dev/null 2>&1; then
        update-grub || true
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg || true
    fi
fi

if [ "\$1" = disappear ] || [ "\$1" = purge ] || [ "\$1" = remove ]; then
    if [ -d /etc/kernel/postrm.d ]; then
        DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version --arg=\$image_path /etc/kernel/postrm.d || true
    fi
fi

exit 0
EOF
    chmod +x "${DEB_IMG}/DEBIAN/postrm"
    
    # Build image package
    DEB_IMG_FILE="${BUILD_DIR}/${DEB_IMG_PKG}_${DEB_VERSION}_amd64.deb"
    dpkg-deb --root-owner-group -b "${DEB_IMG}" "${DEB_IMG_FILE}"
    print_success "Debian image: ${DEB_IMG_FILE}"
    
    # --- HEADERS PACKAGE ---
    if [ "$_build_debug" = "yes" ]; then
        mkdir -p "${DEB_HDR}/DEBIAN" "${DEB_HDR}/usr/src"
        
        # Determine correct module path for headers symlink
        if [ "$USR_MERGED" = true ]; then
            mkdir -p "${DEB_HDR}/usr/lib/modules/${KERNEL_VERSION}"
            ln -srf "${DEB_HDR}/usr/src/linux-headers-${KERNEL_VERSION}" "${DEB_HDR}/usr/lib/modules/${KERNEL_VERSION}/build"
        else
            mkdir -p "${DEB_HDR}/lib/modules/${KERNEL_VERSION}"
            ln -srf "${DEB_HDR}/usr/src/linux-headers-${KERNEL_VERSION}" "${DEB_HDR}/lib/modules/${KERNEL_VERSION}/build"
        fi
        
        cp -a "${INSTALL_DIR}/usr/src/linux-headers-${KERNEL_VERSION}" "${DEB_HDR}/usr/src/"
        
        cat > "${DEB_HDR}/DEBIAN/control" << EOF
Package: ${DEB_HDR_PKG}
Version: ${DEB_VERSION}
Section: kernel
Priority: optional
Maintainer: GitHub User <github@example.com>
Architecture: amd64
Depends: make, gcc, libc6-dev, binutils, ${DEB_IMG_PKG} (= ${DEB_VERSION})
Description: Headers for ${DESC}
 Required for building external kernel modules (DKMS).
EOF
        
        # Headers postinst to ensure DKMS can find the build symlink
        cat > "${DEB_HDR}/DEBIAN/postinst" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'

if [ "\$1" = configure ]; then
    # Handle usr-merge dynamically
    if [ -L /lib ] && [ "\$(readlink -f /lib)" = "/usr/lib" ]; then
        moddir="/usr/lib/modules/\$version"
    else
        moddir="/lib/modules/\$version"
    fi
    
    # Ensure the build symlink exists and points to the correct location
    if [ -d "/usr/src/linux-headers-\$version" ] && [ ! -e "\$moddir/build" ]; then
        mkdir -p "\$moddir"
        ln -sf "/usr/src/linux-headers-\$version" "\$moddir/build"
    fi
    
    # Trigger DKMS to build for this kernel now that headers are installed
    if command -v dkms >/dev/null 2>&1; then
        dkms autoinstall -k "\$version" 2>/dev/null || true
    fi
fi
exit 0
EOF
        chmod +x "${DEB_HDR}/DEBIAN/postinst"
        
        # Headers postrm to clean up symlinks
        cat > "${DEB_HDR}/DEBIAN/postrm" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'

if [ "\$1" = purge ]; then
    if [ -L /lib ] && [ "\$(readlink -f /lib)" = "/usr/lib" ]; then
        moddir="/usr/lib/modules/\$version"
    else
        moddir="/lib/modules/\$version"
    fi
    
    # Remove the build symlink
    if [ -L "\$moddir/build" ]; then
        rm -f "\$moddir/build"
    fi
    
    # Try to remove the module directory if it's empty
    rmdir "\$moddir" 2>/dev/null || true
fi
exit 0
EOF
        chmod +x "${DEB_HDR}/DEBIAN/postrm"
        
        DEB_HDR_FILE="${BUILD_DIR}/${DEB_HDR_PKG}_${DEB_VERSION}_amd64.deb"
        dpkg-deb --root-owner-group -b "${DEB_HDR}" "${DEB_HDR_FILE}"
        print_success "Debian headers: ${DEB_HDR_FILE}"
    fi
fi

# ======================== SUMMARY ========================
print_step "Step 11: Verification & Summary"
print_warning "The kernel has been built successfully!"
echo "=========================================="
if [[ "$_build_archpkg" == "yes" ]]; then
    PACMAN_PKGVER="${KERNEL_VERSION//-/.}-${pkgrel}"
    echo " Arch Image:   sudo pacman -U ${BUILD_DIR}/linux-cachyos-${_cpusched}-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"
    [[ "$_build_debug" == "yes" ]] && echo " Arch Headers: sudo pacman -U ${BUILD_DIR}/linux-cachyos-${_cpusched}-headers-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"
fi
if [[ "$_build_deb" == "yes" ]]; then
    echo " Debian Image: sudo dpkg -i ${DEB_IMG_FILE}"
    [[ "$_build_debug" == "yes" ]] && echo " Debian Hdrs:  sudo dpkg -i ${DEB_HDR_FILE}"
fi
echo "=========================================="
if [ "$USR_MERGED" = true ]; then
    print_success "Your system uses usr-merged filesystem layout"
    print_info "Modules will be installed to /usr/lib/modules/ (accessed via /lib/modules symlink)"
else
    print_warning "Your system uses traditional filesystem layout"
    print_info "Modules will be installed to /lib/modules/"
fi
echo
print_info "Post-install steps:"
echo "sudo depmod -a ${KERNEL_VERSION}"
echo "sudo update-initramfs -c -k ${KERNEL_VERSION}"
echo "sudo update-grub"
echo
print_info "Build directory preserved at: ${BUILD_DIR}"
print_info "Config saved at: ${BUILD_DIR}/config-${KERNEL_VERSION}"
print_info "To clean up: rm -rf ${BUILD_DIR}/src"
print_success "Build process completed successfully!"
