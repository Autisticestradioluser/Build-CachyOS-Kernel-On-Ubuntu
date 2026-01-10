#!/bin/bash
# CachyOS style Kernel Build Script for Ubuntu Noble 24.04 - USR-MERGE FIXED VERSION
# Properly handles modern Ubuntu's merged-usr filesystem structure

set -e

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "\n${GREEN}==>${NC} ${YELLOW}$1${NC}"; }

# Build configuration - matching PKGBUILD defaults
_cachy_config=${_cachy_config:-yes}
# CPU scheduler: bore, bmq, hardened, cachyos, eevdf, rt, rt-bore
# bore is better for interactive apps but is an unfair scheduler which can introduce instability for VMs hosted with BORE on the host (BORE on VMs seems okay)
# use EEVDF for VM hosts
_cpusched=${_cpusched:-bore}
# Tweak config with nconfig/xconfig
_makenconfig=${_makenconfig:-no}
_makexconfig=${_makexconfig:-no}
# Build only used modules (requires modprobed.db)
_localmodcfg=${_localmodcfg:-no}
_localmodcfg_path=${_localmodcfg_path:-"$HOME/.config/modprobed.db"}
# Use current kernel config
_use_current=${_use_current:-no}
# Compiler optimizations: -O3
_cc_harder=${_cc_harder:-yes}
# Default performance governor
_per_gov=${_per_gov:-yes}
# Enable TCP_CONG_BBR3 for bbrv3
_tcp_bbr3=${_tcp_bbr3:-yes}
# 100, 250, 300, 500, 600, 750, 1000
_HZ_ticks=${_HZ_ticks:-1000}
# periodic, idle, full
_tickrate=${_tickrate:-full}
# Preempt: full, lazy, voluntary, none
_preempt=${_preempt:-full}
# Transparent Hugepages: always, madvise
_hugepage=${_hugepage:-always}
# CPU optimization: native, zen4, generic_v[1-4]
_processor_opt=${_processor_opt:-native}
# LLVM LTO: none, thin, full, thin-dist
# use zram-generator and make a zstd zram device with zram = ram * 4 if you have at least 8 GB RAM to build with full LTO
_use_llvm_lto=${_use_llvm_lto:-full}
# Use -lto suffix
_use_lto_suffix=${_use_lto_suffix:-yes}
# Use -gcc suffix
_use_gcc_suffix=${_use_gcc_suffix:-no}
# Enable KCFI
_use_kcfi=${_use_kcfi:-no}
# Build ZFS module (NOT compatible with RT schedulers)
_build_zfs=${_build_zfs:-no}
# Build proprietary NVIDIA module (REPLACES nvidia-dkms)
_build_nvidia=${_build_nvidia:-no}
# Build proprietary NVIDIA modules but no kernel headers
_build_nvidia_min=${_build_nvidia_min:-no}
# Build open NVIDIA module (Turing+ only)
_build_nvidia_open=${_build_nvidia_open:-no}
# Build open NVIDIA module (Turing+) but no kernel headers
_build_nvidia_open_min=${_build_nvidia_open_min:-no}
# build with headers (without requiring nvidia)
_build_debug=${_build_debug:-no}
# AutoFDO
_autofdo=${_autofdo:-no}
_autofdo_profile_name=${_autofdo_profile_name:-}
# Propeller
_propeller=${_propeller:-no}
_propeller_profiles=${_propeller_profiles:-no}
# build mkinitcpio.d preset for arch users, valid opts: 'no', 'yes', 'ext': yes (included in package for distros that use mkinitcpio such as Arch), or 'ext' external (placed inside build dir where the resulting .tar.zst for kernel will be so you can use it on Arch too)
# WORK IN PROGRESS: 'yes' here should build you a package to install on Arch, but we don't currently make metadata to do this
_build_mkinitcpiod_preset=${_build_mkinitcpiod_preset:-yes}
# Build deb package for debian/ubuntu
_build_deb=${_build_deb:-yes}

# Kernel version info
_major=6.18
_minor=4
#_rcver=rc7
pkgver=${_major}.${_minor}
#pkgver=${_major}.${_rcver}
#_stable=${_major}-${_rcver}
#_stable=${_major}
_stable=${_major}.${_minor}
_srcname=linux-${_stable}
# Put a verison in here that is higher than your previous one
pkgrel=1

# NVIDIA driver version, 580.119.02 is latest for maxwell-pascal vs 590.44.01 beta is turing+ but nvidia-open is better for that while maxwell-pascal need 580-series proprietary drivers
_nv_ver=580.119.02
_nv_pkg="NVIDIA-Linux-x86_64-${_nv_ver}"
_nv_open_ver=590.48.01
_nv_open_pkg="NVIDIA-kernel-module-source-${_nv_open_ver}"

# b2sums, expected to change with each release, current 6.18.3 b2sums
_kernel_b2sum=3cb595f16f164583bdc80022d3f011f683d0b31b618b005bbc85a77005406f45ec9a6a8941976926dbdb79e0f392cc1b70ce2a48fd7d8fa44f131f937f2d38b4
_config_b2sum=81fafd3adcaf3b690d8d4791693e68c7ae921d103ebfd70e8d0ae15cd05ecde5e6672ae43c3a7875686d883c1f5b82d2c8b37b40aee8dcb0563913f9dd6469b6
_cachy_base_patch_b2sum=38d1c42193033ce306d45ad4f8e3116fd1714ffdab1d5b2af94cd87d3b4078ca50fbdf56f155a60f86ddbace6824d1fa3c87e60e5b1b1bea1e9e14fc636841cf
_dkms_clang_patch_b2sum=c7294a689f70b2a44b0c4e9f00c61dbd59dd7063ecbe18655c4e7f12e21ed7c5bb4f5169f5aa8623b1c59de7b2667facb024913ecb9f4c650dabce4e8a7e5452


# Patches source
_patchsource="https://raw.githubusercontent.com/cachyos/kernel-patches/master/${_major}"

# Build directory
BUILD_DIR="${PWD}/linux-cachyos-${_cpusched}-${_stable}-${pkgrel}-${_processor_opt}"
SRC_DIR="${BUILD_DIR}/src"
DOWNLOAD_DIR="${BUILD_DIR}/downloads"

# prevent sourcing
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]:-${0}}")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]:-${0}}")"
SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH" 2>/dev/null || realpath "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")"
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    print_error "This script is being sourced. Please run it, don't source it:"
    echo "  bash ${SCRIPT_PATH}"
    return 1 2>/dev/null || exit 1
fi

print_step "Step 1: Checking Ubuntu Noble System and usr-merge status"
if ! lsb_release -cs | grep -q "noble"; then
    print_warning "This script is optimized for Ubuntu Noble 24.04. Current system: $(lsb_release -cs)"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for usr-merge status
print_info "Checking usr-merge status..."
USR_MERGED=false
if [ -L "/lib" ] && [ "$(readlink -f /lib)" = "/usr/lib" ]; then
    USR_MERGED=true
    print_success "System is using merged-usr layout (modern Ubuntu)"
    print_info "/lib -> /usr/lib symlink detected"
else
    print_warning "System appears to NOT be using merged-usr layout"
    print_info "This is unusual for Ubuntu Noble. Modules will be installed to traditional /lib/modules"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

print_step "Step 2: Dependency Check"
print_info "Checking for required packages in Ubuntu Noble and LLVM repositories..."
print_info "In case you haven't got clang-21 already"
print_info "wget https://apt.llvm.org/llvm.sh"
print_info "chmod +x llvm.sh"
print_info "sudo ./llvm.sh 21"

# Ubuntu Noble package names (pending research)
REQUIRED_PACKAGES=(
    "build-essential"      # bc, make, gcc
    "libncurses-dev"      # for menuconfig
    "libelf-dev"          # kernel build
    "libssl-dev"          # kernel build
    "flex"                # kernel build
    "bison"               # kernel build
    "cpio"                # initramfs
    "gettext"             # localization
    "python3"             # kernel scripts
    "perl"                # kernel scripts
    "zstd"                # compression
    "wget"                # downloads
    "curl"                # downloads
    "git"                 # for zfs if needed
    "pkg-config"          # build system
    "kmod"                # for depmod
    "fakeroot"            # for proper module installation
    "dwarves"             # for something
)

# Add Rust packages for Ubuntu Noble
if [ "$_cpusched" != "rt" ] && [ "$_cpusched" != "rt-bore" ]; then
    REQUIRED_PACKAGES+=(
        "rustc"               # Rust compiler
        "rust-src"            # Rust source
        "bindgen"        # Rust bindgen for kernel
    )
fi

# Add LLVM/Clang packages if using LTO
if [[ "$_use_llvm_lto" == "thin" || "$_use_llvm_lto" == "full" || "$_use_llvm_lto" == "thin-dist" ]]; then
    REQUIRED_PACKAGES+=(
        "clang-21"               # LLVM C compiler use 21 in Noble via llvm repos
        "llvm-21"                # LLVM toolchain use 21 in Noble
        "lld-21"                 # LLVM linker use 21 in Noble
        "libclang-21-dev"        # for bindgen
    )
fi

if [ "$_build_deb" = "yes" ]; then
    REQUIRED_PACKAGES+=(
    "dpkg-dev"            # for deb building
    )
fi


print_info "Required packages for build:"
MISSING_PACKAGES=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        echo "  ✓ $pkg (installed)"
    else
        echo "  ✗ $pkg (missing)"
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    print_warning "Missing packages detected!"
    print_info "Please run the following command as root to install dependencies:"
    echo
    echo "sudo apt update && sudo apt install -y ${MISSING_PACKAGES[*]}"
    echo
    read -p "Continue without installing? Build will fail if dependencies are missing (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

if [[ $EUID -ne 0 && -z "$FAKEROOTKEY" ]]; then
    print_warning "Script not running under fakeroot."
    if command -v fakeroot >/dev/null 2>&1; then
        # Check if the script has executable permission
        if [ ! -x "$SCRIPT_PATH" ]; then
            print_info "Script lacks execute permission. Fixing that for you... Start it again if it doesn't automatically, hey?"
            chmod +x "$SCRIPT_PATH"
            print_info "Automatically restarting script under fakeroot..."
            exec fakeroot "$SCRIPT_PATH"
        else
            print_info "Automatically restarting script under fakeroot..."
            exec fakeroot "$SCRIPT_PATH"
        fi
    else
        print_error "fakeroot is not installed!"
        print_info "Please install it: sudo apt install fakeroot"
        exit 1
    fi
fi

print_step "Step 3: Creating Build Directory Structure"
print_info "Creating directory: ${BUILD_DIR}"
mkdir -p "${SRC_DIR}"
mkdir -p "${DOWNLOAD_DIR}"
cd "${BUILD_DIR}"

print_step "Step 4: Downloading Kernel Sources and Patches"
print_info "Downloading Linux kernel ${_stable}..."
    if [[ -n "$_rcver" || "$_minor" = "0" ]]; then
        if [ ! -f "${DOWNLOAD_DIR}/v${_stable}.tar.gz" ]; then
        print_info "Downloading a kernel from github"
        wget -P "${DOWNLOAD_DIR}" "https://github.com/torvalds/linux/archive/refs/tags/v${_stable}.tar.gz"
        else
        print_info "Kernel source already downloaded"
        fi
    fi
    if [[ "$_minor" -gt 0 ]]; then
        if [ ! -f "${DOWNLOAD_DIR}/${_srcname}.tar.xz" ]; then
        print_info "Downloading a stable kernel from the Linux Foundation CDN"
        wget -P "${DOWNLOAD_DIR}" "https://cdn.kernel.org/pub/linux/kernel/v${pkgver%%.*}.x/${_srcname}.tar.xz"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/${_srcname}.tar.xz | cut -d' ' -f1)" == $_kernel_b2sum ]]; then
        echo "✅  Kernel b2sum matches"
        else
        echo "❌  Kernel b2sum mismatch"
        exit 1
        fi
        else
        print_info "Kernel source already downloaded"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/${_srcname}.tar.xz | cut -d' ' -f1)" == $_kernel_b2sum ]]; then
        echo "✅  Kernel b2sum matches"
        else
        echo "❌  Kernel b2sum mismatch"
        exit 1
        fi
    fi
fi

# Check and download CachyOS config
if [ ! -f "${DOWNLOAD_DIR}/config" ]; then
    print_info "Downloading CachyOS config..."
    wget -O "${DOWNLOAD_DIR}/config" "https://raw.githubusercontent.com/CachyOS/linux-cachyos/refs/heads/master/linux-cachyos/config"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/config | cut -d' ' -f1)" == $_config_b2sum ]]; then
        echo "✅  Config b2sum matches"
        else
        echo "❌  Config b2sum mismatch"
        exit 1
        fi
    else
    echo "Config already downloaded"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/config | cut -d' ' -f1)" == $_config_b2sum ]]; then
        echo "✅  Config b2sum matches"
        else
        echo "❌  Config b2sum mismatch"
        exit 1
        fi
fi

# Check and download CachyOS base patches
if [ ! -f "${DOWNLOAD_DIR}/0001-cachyos-base-all.patch" ]; then
    print_info "Downloading CachyOS base patches..."
    wget -P "${DOWNLOAD_DIR}" "${_patchsource}/all/0001-cachyos-base-all.patch"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/0001-cachyos-base-all.patch | cut -d' ' -f1)" == $_cachy_base_patch_b2sum ]]; then
        echo "✅  CachyOS base patch b2sum matches"
        else
        echo "❌  CachyOS base patch b2sum mismatch"
        exit 1
        fi
    else
    echo "Already download CachyOS base patch"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/0001-cachyos-base-all.patch | cut -d' ' -f1)" == $_cachy_base_patch_b2sum ]]; then
        echo "✅  CachyOS base patch b2sum matches"
        else
        echo "❌  CachyOS base patch b2sum mismatch"
        exit 1
        fi
fi

# Download scheduler patches
case "$_cpusched" in
    cachyos|bore|rt-bore|hardened)
        if [ ! -f "${DOWNLOAD_DIR}/0001-bore-cachy.patch" ]; then
            print_info "Downloading BORE scheduler patch..."
            wget -P "${DOWNLOAD_DIR}" "${_patchsource}/sched/0001-bore-cachy.patch"
        fi
        ;;
    bmq)
        if [ ! -f "${DOWNLOAD_DIR}/0001-prjc-cachy.patch" ]; then
            print_info "Downloading BMQ scheduler patch..."
            wget -P "${DOWNLOAD_DIR}" "${_patchsource}/sched/0001-prjc-cachy.patch"
        fi
        ;;
esac

# Download additional patches based on configuration
if [ "$_cpusched" = "hardened" ]; then
    wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/0001-hardened.patch"
fi

if [[ "$_cpusched" == "rt" || "$_cpusched" == "rt-bore" ]]; then
    wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/0001-rt-i915.patch"
fi

# Download LLVM DKMS patch if using LTO
if [[ "$_use_llvm_lto" == "thin" || "$_use_llvm_lto" == "full" || "$_use_llvm_lto" == "thin-dist" ]]; then
    if [ ! -f "${DOWNLOAD_DIR}/dkms-clang.patch" ]; then
        print_info "Downloading LLVM DKMS patch..."
        wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/dkms-clang.patch"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/dkms-clang.patch | cut -d' ' -f1)" == $_dkms_clang_patch_b2sum ]]; then
        echo "✅  dkms clang patch b2sum matches"
        else
        echo "❌  dkms clang patch b2sum mismatch"
        exit 1
        fi
    else
    echo "Already downloaded dkms clang patch"
        if [[ "$(b2sum ${DOWNLOAD_DIR}/dkms-clang.patch | cut -d' ' -f1)" == $_dkms_clang_patch_b2sum ]]; then
        echo "✅  dkms clang patch b2sum matches"
        else
        echo "❌  dkms clang patch b2sum mismatch"
        exit 1
        fi
    fi
fi

# Download NVIDIA driver if needed
if [[ "$_build_nvidia" == "yes" || "$_build_nvidia_min" == "yes" ]]; then
    print_info "Downloading NVIDIA driver ${_nv_ver}..."
    if [ ! -f "${DOWNLOAD_DIR}/${_nv_pkg}.run" ]; then
        wget -P "${DOWNLOAD_DIR}" "https://us.download.nvidia.com/XFree86/Linux-x86_64/${_nv_ver}/${_nv_pkg}.run"
    fi
    # Check if patch file exists before downloading
    if [ ! -f "${DOWNLOAD_DIR}/0001-Enable-atomic-kernel-modesetting-by-default.patch" ]; then
        wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/nvidia/0001-Enable-atomic-kernel-modesetting-by-default.patch"
    fi
fi

if [[ "$_build_nvidia_open" == "yes" || "$_build_nvidia_open_min" == "yes" ]]; then
    print_info "Downloading NVIDIA open driver ${_nv_open_ver}..."
    if [ ! -f "${DOWNLOAD_DIR}/${_nv_open_pkg}.tar.xz" ]; then
        wget -P "${DOWNLOAD_DIR}" "https://download.nvidia.com/XFree86/${_nv_open_pkg%"-$_nv_open_ver"}/${_nv_open_pkg}.tar.xz"
    fi

    # Patch 1
    if [ ! -f "${DOWNLOAD_DIR}/0001-Enable-atomic-kernel-modesetting-by-default.patch" ]; then
        print_info "Downloading NVIDIA open driver patch: Enable atomic kernel modesetting by default"
        wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/nvidia/0001-Enable-atomic-kernel-modesetting-by-default.patch"
    fi

    # Patch 2
    if [ ! -f "${DOWNLOAD_DIR}/0002-Add-IBT-support.patch" ]; then
        print_info "Downloading NVIDIA open driver patch: Add IBT support"
        wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/nvidia/0002-Add-IBT-support.patch"
    fi
fi
# Clone ZFS if needed
if [ "$_build_zfs" = "yes" ]; then
    print_info "Cloning ZFS repository..."
    if [ ! -d "${SRC_DIR}/zfs" ]; then
        git clone --revision=743334913e5a5f60baf287bcc6d8a23515b02ac5 --depth=1 https://github.com/cachyos/zfs.git "${SRC_DIR}/zfs"
        cd "${BUILD_DIR}"
    fi
fi

print_step "Step 5: Extracting and Preparing Sources"
print_info "Extracting kernel source..."
cd "${SRC_DIR}"
if [[ -n "$_rcver" ]]; then
    tar -xf "${DOWNLOAD_DIR}/v${_stable}.tar.gz"
else
    tar -xf "${DOWNLOAD_DIR}/linux-${_stable}.tar.xz"
fi
cd "${_srcname}"

print_info "Setting kernel version..."
echo "-$pkgrel" > localversion.10-pkgrel
echo "-cachyos" > localversion.20-pkgname

print_step "Step 6: Applying Patches"
print_info "Applying CachyOS base patches..."
patch -Np1 < "${DOWNLOAD_DIR}/0001-cachyos-base-all.patch"

# Apply DKMS clang patch if using LTO
if [[ "$_use_llvm_lto" == "thin" || "$_use_llvm_lto" == "full" || "$_use_llvm_lto" == "thin-dist" ]]; then
    print_info "Applying DKMS Clang patch..."
    patch -Np1 < "${DOWNLOAD_DIR}/dkms-clang.patch"
fi

# Apply scheduler patches
case "$_cpusched" in
    cachyos|bore|rt-bore|hardened)
        print_info "Applying BORE scheduler patch..."
        patch -Np1 < "${DOWNLOAD_DIR}/0001-bore-cachy.patch"
        ;;
    bmq)
        print_info "Applying BMQ scheduler patch..."
        patch -Np1 < "${DOWNLOAD_DIR}/0001-prjc-cachy.patch"
        ;;
esac

if [ "$_cpusched" = "hardened" ]; then
    print_info "Applying hardened patches..."
    patch -Np1 < "${DOWNLOAD_DIR}/0001-hardened.patch"
fi

if [[ "$_cpusched" == "rt" || "$_cpusched" == "rt-bore" ]]; then
    print_info "Applying RT patches..."
    patch -Np1 < "${DOWNLOAD_DIR}/0001-rt-i915.patch"
fi

print_step "Step 7: Configuring Kernel"
print_info "Copying CachyOS config..."
cp "${DOWNLOAD_DIR}/config" .config

print_info "Applying configuration options..."

# Set up build flags for LLVM if needed
BUILD_FLAGS=()
if [[ "$_use_llvm_lto" == "thin" || "$_use_llvm_lto" == "full" || "$_use_llvm_lto" == "thin-dist" ]]; then
    BUILD_FLAGS=(
        CC=clang-21
        LD=ld.lld-21
        LLVM=-21
        LLVM_IAS=1
    )
    print_info "Using LLVM/Clang toolchain"
fi

# Apply all configuration options (following PKGBUILD logic)
print_info "Setting CPU optimization to ${_processor_opt}..."
if [ -n "$_processor_opt" ]; then
    MARCH="${_processor_opt^^}"
    case "$MARCH" in
        GENERIC_V[1-4])
            scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU \
                --set-val X86_64_VERSION "${MARCH//GENERIC_V}"
            ;;
        ZEN4)
            scripts/config -d GENERIC_CPU -e MZEN4 -d X86_NATIVE_CPU
            ;;
        NATIVE)
            scripts/config -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU
            ;;
    esac
fi

if [ "$_cachy_config" = "yes" ]; then
    print_info "Enabling CachyOS config..."
    scripts/config -e CACHY
fi

print_info "Configuring CPU scheduler: ${_cpusched}..."
case "$_cpusched" in
    cachyos|bore|hardened)
        scripts/config -e SCHED_BORE
        ;;
    bmq)
        scripts/config -e SCHED_ALT -e SCHED_BMQ
        ;;
    eevdf)
        # Default scheduler
        ;;
    rt)
        scripts/config -e PREEMPT_RT
        ;;
    rt-bore)
        scripts/config -e SCHED_BORE -e PREEMPT_RT
        ;;
esac

if [ "$_use_kcfi" = "yes" ]; then
    print_info "Enabling kCFI..."
    scripts/config -e ARCH_SUPPORTS_CFI_CLANG -e CFI_CLANG -e CFI_AUTO_DEFAULT
fi

print_info "Configuring LLVM LTO: ${_use_llvm_lto}..."
case "$_use_llvm_lto" in
    thin)
        scripts/config -e LTO_CLANG_THIN
        ;;
    thin-dist)
        scripts/config -e LTO_CLANG_THIN_DIST
        ;;
    full)
        scripts/config -e LTO_CLANG_FULL
        ;;
    none)
        scripts/config -e LTO_NONE
        ;;
esac

print_info "Setting tick rate to ${_HZ_ticks}Hz..."
case "$_HZ_ticks" in
    100|250|500|600|750|1000)
        scripts/config -d HZ_300 -e "HZ_${_HZ_ticks}" --set-val HZ "${_HZ_ticks}"
        ;;
    300)
        scripts/config -e HZ_300 --set-val HZ 300
        ;;
esac

if [ "$_per_gov" = "yes" ]; then
    print_info "Setting performance governor..."
    scripts/config -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL -e CPU_FREQ_DEFAULT_GOV_PERFORMANCE
fi

print_info "Configuring tick type: ${_tickrate}..."
case "$_tickrate" in
    perodic)
        scripts/config -d NO_HZ_IDLE -d NO_HZ_FULL -d NO_HZ -d NO_HZ_COMMON -e HZ_PERIODIC
        ;;
    idle)
        scripts/config -d HZ_PERIODIC -d NO_HZ_FULL -e NO_HZ_IDLE -e NO_HZ -e NO_HZ_COMMON
        ;;
    full)
        scripts/config -d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE -e NO_HZ_FULL_NODEF -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON -e CONTEXT_TRACKING
        ;;
esac

if [[ "$_cpusched" != "rt" && "$_cpusched" != "rt-bore" ]]; then
    print_info "Configuring preemption: ${_preempt}..."
    case "$_preempt" in
        full)
            scripts/config -e PREEMPT_DYNAMIC -e PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE
            ;;
        lazy)
            scripts/config -e PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -e PREEMPT_LAZY -d PREEMPT_NONE
            ;;
        voluntary)
            scripts/config -d PREEMPT_DYNAMIC -d PREEMPT -e PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE
            ;;
        none)
            scripts/config -d PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -e PREEMPT_NONE
            ;;
    esac
fi

if [ "$_cc_harder" = "yes" ]; then
    print_info "Enabling -O3 optimization..."
    scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_PERFORMANCE_O3
fi

if [ "$_tcp_bbr3" = "yes" ]; then
    print_info "Enabling TCP BBR3..."
    scripts/config -m TCP_CONG_CUBIC -d DEFAULT_CUBIC -e TCP_CONG_BBR -e DEFAULT_BBR \
        --set-str DEFAULT_TCP_CONG bbr -m NET_SCH_FQ_CODEL -e NET_SCH_FQ -d CONFIG_DEFAULT_FQ_CODEL -e CONFIG_DEFAULT_FQ
fi

print_info "Configuring Transparent Hugepages: ${_hugepage}..."
case "$_hugepage" in
    always)
        scripts/config -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS
        ;;
    madvise)
        scripts/config -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE
        ;;
esac

print_info "Enabling USER_NS_UNPRIVILEGED..."
scripts/config -e USER_NS

# Use current config if requested
if [ "$_use_current" = "yes" ]; then
    if [ -f /proc/config.gz ]; then
        print_info "Using current kernel config from /proc/config.gz..."
        zcat /proc/config.gz > .config
    else
        print_warning "Current kernel config not available at /proc/config.gz"
    fi
fi

# Local mod config
if [ "$_localmodcfg" = "yes" ]; then
    if [ -e "$_localmodcfg_path" ]; then
        print_info "Running make localmodconfig..."
        make "${BUILD_FLAGS[@]}" LSMOD="${_localmodcfg_path}" localmodconfig
    else
        print_warning "modprobed.db not found at $_localmodcfg_path"
    fi
fi

# Prepare config
print_info "Preparing kernel configuration..."
make "${BUILD_FLAGS[@]}" olddefconfig

# Save kernel version
make -s kernelrelease > version
KERNEL_VERSION=$(cat version)
print_success "Prepared kernel version: ${KERNEL_VERSION}"

# Interactive config if requested
if [ "$_makenconfig" = "yes" ]; then
    print_info "Running make nconfig..."
    make "${BUILD_FLAGS[@]}" nconfig
fi

if [ "$_makexconfig" = "yes" ]; then
    print_info "Running make xconfig..."
    make "${BUILD_FLAGS[@]}" xconfig
fi

# Save config
cp .config "${BUILD_DIR}/config-${KERNEL_VERSION}"

# Extract NVIDIA driver if needed
if [[ "$_build_nvidia" == "yes" || "$_build_nvidia_min" == "yes" ]]; then
    print_info "Extracting NVIDIA driver..."
    cd "${SRC_DIR}"
    sh "${DOWNLOAD_DIR}/${_nv_pkg}.run" --extract-only
    cd "${SRC_DIR}/${_nv_pkg}/kernel"
    patch -Np1 -i "${DOWNLOAD_DIR}/0001-Enable-atomic-kernel-modesetting-by-default.patch"
    cd "${SRC_DIR}/${_srcname}"
fi

if [[ "$_build_nvidia_open" == "yes" || "$_build_nvidia_open_min" == "yes" ]]; then
    print_info "Extracting and patching NVIDIA open driver..."
    cd "${SRC_DIR}"
    tar -xf "${DOWNLOAD_DIR}/${_nv_open_pkg}.tar.xz"
    cd "${SRC_DIR}/${_nv_open_pkg}/kernel-open"
    patch -Np1 -i "${DOWNLOAD_DIR}/0001-Enable-atomic-kernel-modesetting-by-default.patch"
    cd "${SRC_DIR}/${_nv_open_pkg}"
    patch -Np1 -i "${DOWNLOAD_DIR}/0002-Add-IBT-support.patch"
    cd "${SRC_DIR}/${_srcname}"
fi

print_step "Step 8: Building Kernel"
print_info "Starting kernel build (this will take a while)..."
print_info "Using $(nproc) CPU cores for compilation"

cd "${SRC_DIR}/${_srcname}"
make "${BUILD_FLAGS[@]}" -j"$(nproc)" all

# Build BPF tool
make -C tools/bpf/bpftool vmlinux.h feature-clang-bpf-co-re=1

# Build NVIDIA modules if requested
if [[ "$_build_nvidia" == "yes" || "$_build_nvidia_min" == "yes" ]]; then
    print_info "Building NVIDIA kernel modules..."
    MODULE_FLAGS=(
        KERNEL_UNAME="${KERNEL_VERSION}"
        IGNORE_PREEMPT_RT_PRESENCE=1
        SYSSRC="${SRC_DIR}/${_srcname}"
        SYSOUT="${SRC_DIR}/${_srcname}"
        NV_EXCLUDE_BUILD_MODULES='__EXCLUDE_MODULES'
    )
    cd "${SRC_DIR}/${_nv_pkg}/kernel"
    make "${BUILD_FLAGS[@]}" "${MODULE_FLAGS[@]}" -j"$(nproc)" modules
    cd "${SRC_DIR}/${_srcname}"
fi

if [[ "$_build_nvidia_open" == "yes" || "$_build_nvidia_open_min" == "yes" ]]; then
    print_info "Building NVIDIA open kernel modules..."
    MODULE_FLAGS=(
        KERNEL_UNAME="${KERNEL_VERSION}"
        IGNORE_PREEMPT_RT_PRESENCE=1
        SYSSRC="${SRC_DIR}/${_srcname}"
        SYSOUT="${SRC_DIR}/${_srcname}"
        IGNORE_CC_MISMATCH=yes
    )
    cd "${SRC_DIR}/${_nv_open_pkg}"
    CFLAGS= CXXFLAGS= LDFLAGS= make "${BUILD_FLAGS[@]}" "${MODULE_FLAGS[@]}" -j"$(nproc)" modules
    cd "${SRC_DIR}/${_srcname}"
fi

# Build ZFS if requested
if [ "$_build_zfs" = "yes" ]; then
    print_info "Building ZFS modules..."
    cd "${SRC_DIR}/zfs"
    CONFIGURE_FLAGS=()
    if [[ "$_use_llvm_lto" != "none" ]]; then
        CONFIGURE_FLAGS+=("KERNEL_LLVM=1")
    fi
    ./autogen.sh
    sed -i "s|\$(uname -r)|${KERNEL_VERSION}|g" configure
    ./configure "${CONFIGURE_FLAGS[@]}" --prefix=/usr --sysconfdir=/etc --sbindir=/usr/bin \
        --libdir=/usr/lib --datadir=/usr/share --includedir=/usr/include \
        --with-udevdir=/lib/udev --libexecdir=/usr/lib/zfs --with-config=kernel \
        --with-linux="${SRC_DIR}/${_srcname}"
    make "${BUILD_FLAGS[@]}"
    cd "${SRC_DIR}/${_srcname}"
fi

print_step "Step 9: Preparing Installation Archive - USR-MERGE AWARE VERSION"
print_info "Creating installation directory structure..."

INSTALL_DIR="${BUILD_DIR}/install"
rm -rf "${INSTALL_DIR}"  # Clean previous attempts
mkdir -p "${INSTALL_DIR}/boot"

# Determine module install path based on usr-merge status
if [ "$USR_MERGED" = true ]; then
    print_info "Using usr-merged paths (/usr/lib/modules)..."
    MODULES_BASE_DIR="${INSTALL_DIR}/usr/lib/modules"
    mkdir -p "${MODULES_BASE_DIR}/${KERNEL_VERSION}"
else
    print_info "Using traditional paths (/lib/modules)..."
    MODULES_BASE_DIR="${INSTALL_DIR}/lib/modules"
    mkdir -p "${MODULES_BASE_DIR}/${KERNEL_VERSION}"
fi

cd "${SRC_DIR}/${_srcname}"

# Copy kernel image
print_info "Copying kernel image..."
# Install kernel image/System.map/config with explicit modes
install -Dm644 "$(make -s image_name)" "${INSTALL_DIR}/boot/vmlinuz-${KERNEL_VERSION}"
install -Dm644 System.map "${INSTALL_DIR}/boot/System.map-${KERNEL_VERSION}"
install -Dm644 .config "${INSTALL_DIR}/boot/config-${KERNEL_VERSION}"

# Install modules with proper stripping
print_info "Installing kernel modules with proper stripping..."
if [ "$USR_MERGED" = true ]; then
    # For usr-merged systems, install directly to /usr/lib/modules
    make INSTALL_MOD_PATH="${INSTALL_DIR}/usr" INSTALL_MOD_STRIP=1 modules_install
else
    # For traditional systems, install to /lib/modules
    make INSTALL_MOD_PATH="${INSTALL_DIR}" INSTALL_MOD_STRIP=1 modules_install
fi

# Sign modules function (if needed)
sign_modules() {
    local moduledir="$1"
    if grep -q "CONFIG_MODULE_SIG=y" .config; then
        print_info "Signing kernel modules..."
        local sign_script="${SRC_DIR}/${_srcname}/scripts/sign-file"
        local sign_key="$(grep -Po 'CONFIG_MODULE_SIG_KEY="\K[^"]*' .config)"
        if [[ ! "$sign_key" =~ ^/ ]]; then
            sign_key="${SRC_DIR}/${_srcname}/${sign_key}"
        fi
        local sign_cert="${SRC_DIR}/${_srcname}/certs/signing_key.x509"
        local hash_algo="$(grep -Po 'CONFIG_MODULE_SIG_HASH="\K[^"]*' .config)"

        if [ -f "$sign_script" ] && [ -f "$sign_key" ] && [ -f "$sign_cert" ]; then
            find "$moduledir" -type f -name '*.ko' -print -exec \
                "${sign_script}" "${hash_algo}" "${sign_key}" "${sign_cert}" '{}' \;
        fi
    fi
}

# Install NVIDIA modules if built
if [[ "$_build_nvidia" == "yes" || "$_build_nvidia_min" == "yes" ]]; then
    print_info "Installing NVIDIA modules..."
    NVIDIA_DIR="${MODULES_BASE_DIR}/${KERNEL_VERSION}/kernel/drivers/video"
    mkdir -p "${NVIDIA_DIR}"
    cp "${SRC_DIR}/${_nv_pkg}/kernel/"*.ko "${NVIDIA_DIR}/"
    sign_modules "${NVIDIA_DIR}"
fi

if [[ "$_build_nvidia_open" == "yes" || "$_build_nvidia_open_min" == "yes" ]]; then
    print_info "Installing NVIDIA open modules..."
    NVIDIA_DIR="${MODULES_BASE_DIR}/${KERNEL_VERSION}/kernel/drivers/video"
    mkdir -p "${NVIDIA_DIR}"
    cp "${SRC_DIR}/${_nv_open_pkg}/kernel-open/"*.ko "${NVIDIA_DIR}/"
    sign_modules "${NVIDIA_DIR}"
fi

# Install ZFS modules if built
if [ "$_build_zfs" = "yes" ]; then
    print_info "Installing ZFS modules..."
    ZFS_DIR="${MODULES_BASE_DIR}/${KERNEL_VERSION}/extra"
    mkdir -p "${ZFS_DIR}"
    find "${SRC_DIR}/zfs/module" -name "*.ko" -exec cp {} "${ZFS_DIR}/" \;
    sign_modules "${ZFS_DIR}"
fi

# Compress all modules with zstd (matching Ubuntu's expected format)
print_info "Compressing kernel modules with zstd..."
find "${MODULES_BASE_DIR}/${KERNEL_VERSION}" -type f -name '*.ko' | while read -r module; do
    zstd --rm -T0 -19 "$module"
done

# Generate modules.dep and other dependency files
print_info "Generating module dependencies..."
if [ "$USR_MERGED" = true ]; then
    depmod -b "${INSTALL_DIR}/usr" "${KERNEL_VERSION}"
else
    depmod -b "${INSTALL_DIR}" "${KERNEL_VERSION}"
fi

# Create modules.builtin if it doesn't exist
if [ ! -f "${MODULES_BASE_DIR}/${KERNEL_VERSION}/modules.builtin" ]; then
    cp "${SRC_DIR}/${_srcname}/modules.builtin" "${MODULES_BASE_DIR}/${KERNEL_VERSION}/" 2>/dev/null || true
fi

# Install kernel headers (for module building)
if [ "$_build_debug" = "yes" ] || [ "$_build_nvidia" = "yes" ] || [ "$_build_nvidia_open" = "yes" ]; then
    print_info "Installing kernel headers..."
    HEADERS_DIR="${INSTALL_DIR}/usr/src/linux-headers-${KERNEL_VERSION}"
    mkdir -p "${HEADERS_DIR}"

    # Copy essential files for module building
    mkdir -p "${HEADERS_DIR}/include"
    cp -r "${SRC_DIR}/${_srcname}/include/config" "${HEADERS_DIR}/include"
    cp -r "${SRC_DIR}/${_srcname}/include/generated" "${HEADERS_DIR}/include"
    cp -r "${SRC_DIR}/${_srcname}/scripts" "${HEADERS_DIR}/"
    mkdir -p "${HEADERS_DIR}/arch"
    cp -r "${SRC_DIR}/${_srcname}/arch/x86" "${HEADERS_DIR}/arch/"
    cp -r "${SRC_DIR}/${_srcname}/tools" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/vmlinux" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/Module.symvers" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/.config" "${HEADERS_DIR}/"
    cp "${SRC_DIR}/${_srcname}/Makefile" "${HEADERS_DIR}/"

    # Create version file
    echo "${KERNEL_VERSION}" > "${HEADERS_DIR}/version"
fi
# build mkinitcpio preset file
if [[ "${_build_mkinitcpiod_preset}" == "yes" || "${_build_mkinitcpiod_preset}" == "ext" ]]; then

print_info "Generating mkinitcpio.d preset for kernel: ${KERNEL_VERSION}"

case "${_build_mkinitcpiod_preset}" in
    yes)
        print_info "Creating mkinitcpio.d preset inside package..."
        mkdir -p "${INSTALL_DIR}/etc/mkinitcpio.d"
         mkinitcpiopreset_file="${INSTALL_DIR}/etc/mkinitcpio.d/kernel-${KERNEL_VERSION}.preset"

        cat > "${mkinitcpiopreset_file}" << EOF
# mkinitcpio preset file for ${KERNEL_VERSION}
ALL_kver="/boot/vmlinuz-${KERNEL_VERSION}"
PRESETS=('default' 'fallback')

default_image="/boot/initramfs-${KERNEL_VERSION}.img"

fallback_image="/boot/initramfs-${KERNEL_VERSION}-fallback.img"
fallback_options="-S autodetect"
EOF
        ;;
    ext)
        print_info "Creating external mkinitcpio.d preset (for distribution or manual use)..."
        mkinitcpiopreset_file="${BUILD_DIR}/kernel-${KERNEL_VERSION}.preset"
        mkdir -p "$(dirname "${mkinitcpiopreset_file}")"

        cat > "${mkinitcpiopreset_file}" << EOF
# mkinitcpio preset for custom kernel (generated for version: ${KERNEL_VERSION})
# This file can be used by any system that supports mkinitcpio presets.
# Place it in /etc/mkinitcpio.d/ and run 'mkinitcpio -P' to generate initramfs.

ALL_kver="/boot/vmlinuz-${KERNEL_VERSION}"
PRESETS=('default' 'fallback')

default_image="/boot/initramfs-${KERNEL_VERSION}.img"

fallback_image="/boot/initramfs-${KERNEL_VERSION}-fallback.img"
fallback_options="-S autodetect"
EOF
        ;;
esac

else print_info "Skipping mkinitcpio.d preset creation."

fi


fix_permissions() {
    local root="${INSTALL_DIR}"          # the root of the image you are packaging

    print_info "=== Fixing permissions for ${root} ==="

    # 1️⃣  Directories – 0755 (rwxr-xr-x)
    find "${root}" -type d -exec chmod 0755 {} +

    # 2️⃣  Regular files – 0644 (rw-r--r--)
    find "${root}" -type f -exec chmod 0644 {} +

    # 4️⃣  Remove any stray group‑write bits that may have crept in
    find "${root}" -perm -g=w -exec chmod g-w {} +
}

fix_permissions

build_deb_package() {
    print_info "Building .deb package for kernel"

    # 2. Set up package parameters (determine package name)
    local kernel_type
    local package_suffix=""
    local nvidia_version=""
    nvidia_suffix=""
    local nvidia_open_suffix=""
    local extra_deb_ver=""
    if [ "$_cpusched" == "cachyos" ]; then
    # Currently using BORE like upstream was/is
    _cpusched="bore"
    fi

    # Determine which type of kernel we're building
    if [[ "$_build_nvidia" == "yes" || "$_build_nvidia_min" == "yes" ]]; then
        nvidia_suffix="-nvidia"
        extra_deb_ver="-${_nv_ver}"
        package_suffix="${nvidia_suffix}"
        nvidia_version="${_nv_ver}"
    elif [[ "$_build_nvidia_open" == "yes" || "$_build_nvidia_open_min" == "yes" ]]; then
        nvidia_open_suffix="-nvidia-open"
        extra_deb_ver="-${_nv_open_ver}"
        package_suffix="${nvidia_open_suffix}"
        nvidia_version="${_nv_open_ver}"
    fi

    # The base package name
    local base_package_name="linux-cachyos"
    local package_name="${base_package_name}-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}"
    local deb_version="${_stable}-${KERNEL_VERSION}${extra_deb_ver}"
    local arch="amd64"

    # 3. Create deb directory structure
    local deb_dir="${BUILD_DIR}/debuild"
    rm -rf "${deb_dir}"
    mkdir -p "${deb_dir}"
    mkdir -p "${deb_dir}/DEBIAN"
    mkdir -p "${deb_dir}/boot"
    mkdir -p "${deb_dir}/lib/modules"
    mkdir -p "${deb_dir}/usr/src"

    # 4. Copy files into deb package structure
    print_info "Copying kernel files to deb package structure..."

    # Copy boot files
    cp -r "${INSTALL_DIR}/boot"/* "${deb_dir}/boot/"

    # Copy modules (for usr-merged systems)
    if [ "$USR_MERGED" = true ]; then
        # For usr-merged systems, copy from /usr/lib/modules to /lib/modules
        cp -r "${INSTALL_DIR}/usr/lib/modules/${KERNEL_VERSION}" "${deb_dir}/lib/modules/"
    else
        # Traditional system, just copy what's in /lib/modules
        cp -r "${INSTALL_DIR}/lib/modules/${KERNEL_VERSION}" "${deb_dir}/lib/modules/"
    fi

    # Copy headers if built (and the package is built with headers)
    if [ "$_build_debug" = "yes" ] || [ "$_build_nvidia" = "yes" ] || [ "$_build_nvidia_open" = "yes" ]; then
        print_info "Copying kernel headers..."
        cp -r "${INSTALL_DIR}/usr/src/linux-headers-${KERNEL_VERSION}" "${deb_dir}/usr/src/"
    fi

    # 5. Create control file (dynamically set based on NVIDIA build type)
    print_info "Creating control file..."
    cat > "${deb_dir}/DEBIAN/control" << EOF
Package: ${package_name}
Version: ${deb_version}
Section: kernel
Priority: optional
Maintainer: GitHub User
Architecture: ${arch}
Pre-Depends: initramfs-tools (>= 0.125)
Depends: linux-base (>= 4.0~)
Description: CachyOS Linux kernel built by a user for Debian or Ubuntu
 kernel ${KERNEL_VERSION}
EOF

    # Add specific notes for NVIDIA types
    if [ -n "${nvidia_suffix}" ] || [ -n "${nvidia_open_suffix}" ]; then
        cat >> "${deb_dir}/DEBIAN/control" << EOF
  Note: This package includes NVIDIA driver ${nvidia_version} which is pre-built
  against the Linux kernel with CachOS patches and has been optimized for gaming. The NVIDIA
  modules are fully integrated with the kernel, avoiding the need for
  separate driver installation. If you have trouble with your graphics after installing this, run: sudo rm /etc/modprobe.d/disable-nouveau-for-nvidia.conf
EOF
    fi
    local version="${KERNEL_VERSION}"
    local image_path="/boot/vmlinuz-${version}"
    #preinst script
    print_info "Creating pre-install script..."
cat > "${deb_dir}/DEBIAN/preinst" << EOF
#!/bin/sh
set -e

version='${version}'
image_path='${image_path}'

# Handle abort-upgrade case
if [ "\$1" = abort-upgrade ]; then
    exit 0
fi

# On fresh install, create a flag file
if [ "\$1" = install ]; then
    # Create a flag file for postinst to detect fresh install
    mkdir -p /lib/modules/\$version
    touch /lib/modules/\$version/.fresh-install
fi

if [ -d /etc/kernel/preinst.d ]; then
    DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version \
	      --arg=\$image_path /etc/kernel/preinst.d
fi

exit 0
EOF

chmod +x "${deb_dir}/DEBIAN/preinst"
    # 6. Create post-install script (safely updates initramfs/GRUB)
    print_info "Creating post-install script..."
    cat > "${deb_dir}/DEBIAN/postinst" << EOFF
#!/bin/sh
set -e

version='${version}'
image_path='${image_path}'

if [ "\$1" != configure ]; then
    exit 0
fi

depmod \$version

if [ -f /lib/modules/\$version/.fresh-install ]; then
    change=install
else
    change=upgrade
fi

# -c creates a new one, -u updates. We try create first.
if command -v update-initramfs >/dev/null 2>&1; then
    echo "Updating initramfs..."
    update-initramfs -c -k "\${version}" || update-initramfs -u -k "\${version}"
fi

linux-update-symlinks \$change \$version \$image_path

rm -f /lib/modules/\$version/.fresh-install

if [ -d /etc/kernel/postinst.d ]; then
    mkdir -p /usr/lib/linux/triggers
    cat - >/usr/lib/linux/triggers/\$version <<EOF
DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version \
      --arg=\$image_path /etc/kernel/postinst.d
EOF
    dpkg-trigger --no-await linux-update-\$version
fi

if command -v update-grub >/dev/null 2>&1; then
    echo "Updating GRUB..."
    update-grub
fi

EOFF
# EOFF - End of File Fursure

    if [ -n "${nvidia_suffix}" ] || [ -n "${nvidia_open_suffix}" ]; then
    cat >> "${deb_dir}/DEBIAN/postinst" << 'EOF'
# For NVIDIA (all): disable nouveau
    echo "blacklist nouveau" | tee -a /etc/modprobe.d/disable-nouveau-for-nvidia.conf
    echo "options nouveau modeset=0" | tee -a /etc/modprobe.d/disable-nouveau-for-nvidia.conf
    echo "successfully created /etc/modprobe.d/disable-nouveau-for-nvidia.conf"
exit 0
EOF
    else
    cat >> "${deb_dir}/DEBIAN/postinst" << 'EOF'
    exit 0
EOF
fi
    chmod +x "${deb_dir}/DEBIAN/postinst"

    # 7. Create pre-uninstall script (cleanup)
    print_info "Creating pre-uninstall script..."
    cat > "${deb_dir}/DEBIAN/prerm" << EOF
#!/bin/sh
set -e

version='${version}'
image_path='${image_path}'

# Only act on real removal, not upgrade, deconfigure, etc.
if [ "\$1" != remove ]; then
    exit 0
fi

# Check that removing this kernel is safe (not the running or only kernel)
linux-check-removal "\$version"

# Run standard kernel prerm hooks
if [ -d /etc/kernel/prerm.d ]; then
    DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version \
	      --arg=\$image_path /etc/kernel/prerm.d
fi

# Run Hooks (Debian Standard)
if command -v linux-run-hooks >/dev/null 2>&1; then
    linux-run-hooks image prerm "\${version}" "\${image_path}"
fi

if command -v linux-update-symlinks >/dev/null 2>&1; then
    linux-update-symlinks remove "\${version}" "\${image_path}"
fi

if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -d -k "\${version}"
fi

EOF
if [ -n "${nvidia_suffix}" ] || [ -n "${nvidia_open_suffix}" ]; then
    cat >> "${deb_dir}/DEBIAN/prerm" << 'EOF'
# Clean up modprobe.d config
if [ -f /etc/modprobe.d/disable-nouveau-for-nvidia.conf ]; then
    rm -f /etc/modprobe.d/disable-nouveau-for-nvidia.conf
fi
exit 0
EOF
    else
    cat >> "${deb_dir}/DEBIAN/prerm" << 'EOF'
    exit 0
EOF
fi

    chmod +x "${deb_dir}/DEBIAN/prerm"

    # Postrm script
    print_info "Creating post-removal script..."
cat > "${deb_dir}/DEBIAN/postrm" << EOF
#!/bin/sh
set -e

version='${version}'
image_path='${image_path}'
rm -f /lib/modules/$version/.fresh-install

if [ "\$1" != upgrade ] && command -v linux-update-symlinks >/dev/null; then
    linux-update-symlinks remove \$version \$image_path
fi

if [ -d /etc/kernel/postrm.d ]; then
    # We cannot trigger ourselves as at the end of this we will no longer
    # exist and can no longer respond to the trigger.  The trigger would
    # then become lost.  Therefore we clear any pending trigger and apply
    # postrm directly.
    if [ -f /usr/lib/linux/triggers/\$version ]; then
	echo "\$0 ... removing pending trigger"
	rm -f /usr/lib/linux/triggers/\$version
    fi
    DEB_MAINT_PARAMS="\$*" run-parts --report --exit-on-error --arg=\$version \
	      --arg=\$image_path /etc/kernel/postrm.d
fi

if [ "\$1" = purge ]; then
    for extra_file in modules.dep modules.isapnpmap modules.pcimap \
                      modules.usbmap modules.parportmap \
                      modules.generic_string modules.ieee1394map \
                      modules.ieee1394map modules.pnpbiosmap \
                      modules.alias modules.ccwmap modules.inputmap \
                      modules.symbols modules.ofmap \
                      modules.seriomap modules.\*.bin \
                      modules.softdep modules.weakdep modules.devname; do
	eval rm -f /lib/modules/\$version/\$extra_file
    done
    rmdir /lib/modules/\$version || true
fi

if [ "\$1" = remove ] || [ "\$1" = purge ]; then
    if command -v update-grub >/dev/null 2>&1; then
        update-grub || true
    fi
fi

EOF
if [ -n "${nvidia_suffix}" ] || [ -n "${nvidia_open_suffix}" ]; then
    cat >> "${deb_dir}/DEBIAN/postrm" << 'EOF'

    # Extra cleanup for NVIDIA: ensure modprobe config is removed on purge
    if [ -f /etc/modprobe.d/disable-nouveau-for-nvidia.conf ]; then
        rm -f /etc/modprobe.d/disable-nouveau-for-nvidia.conf
    fi
EOF
fi
cat >> "${deb_dir}/DEBIAN/postrm" << EOF
exit 0
EOF
    chmod +x "${deb_dir}/DEBIAN/postrm"
    # 8. Build the .deb package with proper name
    print_info "Building .deb package with name: ${package_name}"
    deb_file="${BUILD_DIR}/${package_name}_${deb_version}_${arch}.deb"
    dpkg-deb -b "${deb_dir}" "${deb_file}"

    # 9. Verify package creation
    if [ -f "${deb_file}" ]; then
        print_success "Created .deb package: ${deb_file}"
        print_info "To install: sudo dpkg -i ${deb_file}"
    else
        print_error "Failed to build .deb package. Check DEBIAN/control for errors."
        exit 1
    fi
}



# Build .deb
if [ "${_build_deb}" = "yes" ]; then
    print_step "Step 9.1: Creating .deb package"
     build_deb_package
fi

print_step "Step 10: Creating Compressed Archive"
print_info "Compressing installation files with zstd..."
cd "${BUILD_DIR}"
tar --zstd -cf "linux-cachyos-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}-${KERNEL_VERSION}-x86_84.pkg.tar.zst" -C install .

ARCHIVE_SIZE=$(du -h "linux-cachyos-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}-${KERNEL_VERSION}-x86_84.pkg.tar.zst" | cut -f1)
print_success "Archive created: linux-cachyos-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}-${KERNEL_VERSION}-x86_84.pkg.tar.zst (${ARCHIVE_SIZE})"

print_step "Step 11: Verification"
print_info "Verifying Arch package archive contents..."
if [ "$USR_MERGED" = true ]; then
    print_info "Archive contains usr-merged paths (/usr/lib/modules)"
    tar -tzf "linux-cachyos-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}-${KERNEL_VERSION}-x86_84.pkg.tar.zst" | grep -E "^usr/lib/modules/${KERNEL_VERSION}" | head -10
else
    print_info "Archive contains traditional paths (/lib/modules)"
    tar -tzf "linux-cachyos-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}-${KERNEL_VERSION}-x86_84.pkg.tar.zst" | grep -E "^lib/modules/${KERNEL_VERSION}" | head -10
fi
echo "..."
print_info "Total files in archive: $(tar -tzf "linux-cachyos-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}-${KERNEL_VERSION}-x86_84.pkg.tar.zst" | wc -l)"

print_step "Step 12: Installation Instructions - USR-MERGE AWARE"
print_warning "The kernel has been built successfully!"
print_info "Arch package location: ${BUILD_DIR}/linux-cachyos-${_cpusched}${nvidia_suffix}${nvidia_open_suffix}-${KERNEL_VERSION}-x86_84.pkg.tar.zst"
echo
    if [ -f "${deb_file}" ]; then
        print_success "Created .deb package: ${deb_file}"
        print_info "To install: sudo dpkg -i ${deb_file}"
    else
        echo ".deb package not made"
    fi
if [ "$USR_MERGED" = true ]; then
    print_success "Your system uses usr-merged filesystem layout"
    print_info "Modules will be installed to /usr/lib/modules/ (accessed via /lib/modules symlink)"
else
    print_warning "Your system uses traditional filesystem layout"
    print_info "Modules will be installed to /lib/modules/"
fi

echo
print_info "To install the kernel, run the following commands as root:"
echo
echo "# Verify module installation"
echo "sudo ls -la /lib/modules/${KERNEL_VERSION}/ | head"
echo
echo "# Check that modules.dep exists"
echo "sudo ls -l /lib/modules/${KERNEL_VERSION}/modules.dep"
echo
echo "# Update module dependencies (critical step)"
echo "sudo depmod -a ${KERNEL_VERSION}"
echo
echo "# Verify some key modules are present"
echo "find /lib/modules/${KERNEL_VERSION} -name '*.ko.zst' | head -10"
echo
echo "# Update initramfs if not done already (required for modules to load)"
echo "sudo update-initramfs -c -k ${KERNEL_VERSION}"
echo
echo "# Arch users need to use mkinitcpio instead"
echo "sudo mkinitcpio -P"
echo
echo "# Verify initramfs was created"
echo "ls -lh /boot/initrd.img-${KERNEL_VERSION}"
echo
echo "# Update GRUB if not done already"
echo "sudo update-grub"
echo
echo "# Verify GRUB detected the new kernel"
echo "grep '${KERNEL_VERSION}' /boot/grub/grub.cfg"
echo

if [[ "$_build_nvidia" == "yes" || "$_build_nvidia_open" == "yes" || "$_build_nvidia_min" == "yes" || "$_build_nvidia_open_min" == "yes" ]]; then
    print_warning "NVIDIA modules were built. After successful boot with new kernel:"
    echo "# First boot into new kernel and verify it works"
    echo "# Check loaded modules: lsmod | grep nvidia"
    echo
    echo "# If NVIDIA modules are working, remove old packages:"
    echo "sudo systemctl stop nvidia-persistenced"
    echo "sudo apt remove --purge nvidia-* libnvidia-*"
    echo "sudo apt autoremove"
    echo
    echo "# You may need to blacklist nouveau:"
    echo "echo 'blacklist nouveau' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf"
    echo "sudo update-initramfs -u -k ${KERNEL_VERSION}"
fi

if [[ "${_build_mkinitcpiod_preset}" == "yes" || "${_build_mkinitcpiod_preset}" == "ext" ]]; then
    print_info "# Arch Linux style mkinitcpio built"
    if [ "${_build_mkinitcpiod_preset}" = "yes" ]; then
        echo "Mkinitcpio preset file installed at ${INSTALL_DIR}/etc/mkinitcpio.d/kernel-${KERNEL_VERSION}.preset this archive will be for distros that use mkinitcpio"
    else
        echo "Mkinitcpio preset file generated and is located at ${BUILD_DIR}/kernel-${KERNEL_VERSION}.preset so you can use it on Arch too"
    fi
fi

print_step "Step 13: Module Debug Information"
print_info "To verify modules after installation:"
echo "# List all available modules for new kernel"
echo "find /lib/modules/${KERNEL_VERSION} -name '*.ko.zst' | wc -l"
echo
echo "# Check specific important modules"
echo "ls -la /lib/modules/${KERNEL_VERSION}/kernel/drivers/gpu/drm/"
echo "ls -la /lib/modules/${KERNEL_VERSION}/kernel/net/"
echo "ls -la /lib/modules/${KERNEL_VERSION}/kernel/fs/"
echo
echo "# After booting into new kernel, verify loaded modules"
echo "lsmod | head -20"
echo "dmesg | grep -i 'module'"
echo
echo "# Check for any module loading errors"
echo "sudo journalctl -b | grep -i 'failed.*module'"

print_step "Step 14: Troubleshooting Tips"
print_info "If modules fail to load after installation:"
echo "1. Verify usr-merge symlinks are intact:"
echo "   ls -ld /lib /bin /sbin"
echo
echo "2. Check module path resolution:"
echo "   modinfo -F filename ext4"
echo
echo "3. Manually regenerate module dependencies:"
echo "   sudo depmod -a ${KERNEL_VERSION}"
echo "   sudo update-initramfs -u -k ${KERNEL_VERSION}"
echo
echo "4. Check for broken symlinks:"
echo "   find /lib/modules/${KERNEL_VERSION} -xtype l"

print_step "Step 15: Cleanup Options"
echo
    # Calculate build directory size
    BUILD_DIR_SIZE=$(du -sh "${BUILD_DIR}" | cut -f1)
    print_info "Build directory size: ${BUILD_DIR_SIZE}"
    print_info "Build directory preserved at: ${BUILD_DIR}"
    print_info "Config saved at: ${BUILD_DIR}/config-${KERNEL_VERSION}"
    print_info "To clean up build files later, run:"
    echo "rm -rf ${BUILD_DIR}/src"
print_success "Build process completed successfully!"
print_warning "Remember: Ubuntu Noble uses usr-merged filesystem - modules are in /usr/lib/modules!"
print_info "The /lib/modules path still works due to the /lib -> /usr/lib symlink"
