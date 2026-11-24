#!/bin/bash
# CachyOS style Kernel Build Script for Ubuntu Resolute 26.04
# Properly handles modern Ubuntu's merged-usr filesystem structure
# Outputs split Arch (.pkg.tar.zst) and Debian (.deb) packages for image & headers
set -eo pipefail
umask 022   # standard 0644/0755 modes for Arch and Debian packages (Ubuntu defaults to 0002)

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
_cpusched=${_cpusched:-bore}             # bore, bmq, cachyos, eevdf, rt, rt-bore
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
# Upstream linux-cachyos uses _build_debug to add a -dbg split package containing
# the non-stripped vmlinux (/usr/src/debug/${pkgbase}/vmlinux, depends on headers).
# Headers are built unconditionally, as upstream does (pkgname+=("$pkgbase-headers")).
# This script has no -dbg split yet, so the flag is accepted but has no effect.
_build_debug=${_build_debug:-no}
_autofdo=${_autofdo:-no}
_autofdo_profile_name=${_autofdo_profile_name:-}
_propeller=${_propeller:-no}
_propeller_profiles=${_propeller_profiles:-no}
_build_r8125=${_build_r8125:-yes}
# r8125 source: "v7" (default, flap fix) or "oldtag" to pin to the
# last known-good version before the 9.018.00 regression
_r8125_src=${_r8125_src:-v7}
_build_nvidia=${_build_nvidia:-no}
_nv_userspace=${_nv_userspace:-yes}      # bundle matching user-space into the NVIDIA deb
_blacklist_nouveau=${_blacklist_nouveau:-yes}  # keep nouveau from claiming the GPU

# --- CUDA (Debian NVIDIA package metadata + optional local package fetch) ---
# 12.9 is the last toolkit for Pascal, and NVIDIA publishes 12.x only for Ubuntu 24.04.
_cuda_ver=${_cuda_ver:-12-9}
# Ship /etc/profile.d/cachyos-cuda.sh and declare the toolchain dependency.
_cuda_setup=${_cuda_setup:-yes}
# Package whose dependency closure the NVIDIA deb declares and _cuda_download fetches.
# Default is the lean build set (nvcc, nvvm, cudart, CCCL, profiler headers; ~81 MiB).
# Use cuda-toolkit-${_cuda_ver} for the full set with docs/Nsight/visual tools (~3.7 GiB).
_cuda_meta=${_cuda_meta:-cuda-minimal-build-${_cuda_ver}}
# How the NVIDIA deb declares the toolchain: recommends (default) | depends | none
_cuda_toolkit_dep=${_cuda_toolkit_dep:-recommends}
# yes = download NVIDIA's verified .debs into BUILD_DIR for manual installation.
# Nothing is installed automatically and no apt source is added.
_cuda_download=${_cuda_download:-no}
# NVIDIA's CUDA repo for the Ubuntu release that ships this toolkit series.
case "$_cuda_ver" in
    12-*) _cuda_repo_suite=${_cuda_repo_suite:-ubuntu2404} ;;
    *)    _cuda_repo_suite=${_cuda_repo_suite:-ubuntu2604} ;;
esac
_nv_ver=580.196.07
_nv_pkg="NVIDIA-Linux-x86_64-${_nv_ver}"
_nv_sha256=${_nv_sha256:-}

# Package targets (replaces _build_mkinitcpiod_preset)
_build_archpkg=${_build_archpkg:-yes}    # yes = build Arch .pkg.tar.zst + mkinitcpio preset
_build_deb=${_build_deb:-yes}            # yes = build Debian .deb

# Kernel version info
_major=7.3
_minor=6
_tagrel=1
pkgver=${_major}.${_minor}
_stable=${_major}.${_minor}
pkgrel=1
_srcver=${_major}.${_minor}-${_tagrel}
_srcname=cachyos-${_srcver}

# Checksums (Update per release)
_kernel_b2sum=${_kernel_b2sum:-67e2a98ad5df5469afae493c34a3f2155932abb94b16c016a8782790bf3a305f91c03b126555294bd4f88d74952bb997f4839b5769980dafbcad08d0579ac7ea}
_config_b2sum=${_config_b2sum:-e6fc382da6b317f14b0ffe1e22e120ea8c9efa03a95ee58360765629b7b81f89e98f04349134232215ae0ff8aa10c2200a7551a3c3aeb1e5d1fb1e4c5673f0e9}
# Matches upstream linux-cachyos b2sums[3]
_dkms_clang_patch_b2sum=${_dkms_clang_patch_b2sum:-c992567bd7dd8553432be496ffa1c17e2f5ebe9c7edb51945cf977e1b742dd6517c210d8843bb82744ca705efd07f8027cd7dde41b50215ebd707a34aa81462e}

# GPG keys for signature verification
_validpgpkeys=(
    E18447AC260021D31F3FF6C4C8A2A4774B8B63C4  # Eric Naim <dnaim@cachyos.org>
    E8B9AA39F054E30E8290D492C3C4820857F654FE  # Peter Jung <admin@ptr1337.dev>
)

_patchsource="https://raw.githubusercontent.com/cachyos/kernel-patches/master/${_major}"
BUILD_DIR="${PWD}/linux-cachyos-${_cpusched}-${_stable}-${pkgrel}-${_processor_opt}"
SRC_DIR="${BUILD_DIR}/src"
DOWNLOAD_DIR="${BUILD_DIR}/downloads"

# Reproducible metadata: honour SOURCE_DATE_EPOCH when set (makepkg semantics).
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}

# Print resolved configuration and exit (used by helper scripts and tests).
if [ "${1:-}" = "--print-config" ]; then
    printf '_cpusched=%s\n'              "$_cpusched"
    printf '_makenconfig=%s\n'           "$_makenconfig"
    printf '_makexconfig=%s\n'           "$_makexconfig"
    printf '_localmodcfg=%s\n'           "$_localmodcfg"
    printf '_localmodcfg_path=%s\n'      "$_localmodcfg_path"
    printf '_use_current=%s\n'           "$_use_current"
    printf '_cc_harder=%s\n'             "$_cc_harder"
    printf '_default_gov=%s\n'           "$_default_gov"
    printf '_tcp_bbr3=%s\n'              "$_tcp_bbr3"
    printf '_HZ_ticks=%s\n'              "$_HZ_ticks"
    printf '_tickrate=%s\n'              "$_tickrate"
    printf '_preempt=%s\n'               "$_preempt"
    printf '_hugepage=%s\n'              "$_hugepage"
    printf '_processor_opt=%s\n'         "$_processor_opt"
    printf '_use_llvm_lto=%s\n'          "$_use_llvm_lto"
    printf '_use_lto_suffix=%s\n'        "$_use_lto_suffix"
    printf '_use_gcc_suffix=%s\n'        "$_use_gcc_suffix"
    printf '_use_kcfi=%s\n'              "$_use_kcfi"
    printf '_build_zfs=%s\n'             "$_build_zfs"
    printf '_build_debug=%s\n'           "$_build_debug"
    printf '_autofdo=%s\n'               "$_autofdo"
    printf '_autofdo_profile_name=%s\n'  "$_autofdo_profile_name"
    printf '_propeller=%s\n'             "$_propeller"
    printf '_propeller_profiles=%s\n'    "$_propeller_profiles"
    printf '_build_r8125=%s\n'           "$_build_r8125"
    printf '_r8125_src=%s\n'             "$_r8125_src"
    printf '_build_nvidia=%s\n'          "$_build_nvidia"
    printf '_nv_userspace=%s\n'          "$_nv_userspace"
    printf '_blacklist_nouveau=%s\n'     "$_blacklist_nouveau"
    printf '_cuda_setup=%s\n'            "$_cuda_setup"
    printf '_cuda_ver=%s\n'              "$_cuda_ver"
    printf '_cuda_meta=%s\n'             "$_cuda_meta"
    printf '_cuda_toolkit_dep=%s\n'      "$_cuda_toolkit_dep"
    printf '_cuda_download=%s\n'         "$_cuda_download"
    printf '_cuda_repo_suite=%s\n'       "$_cuda_repo_suite"
    printf '_nv_ver=%s\n'                "$_nv_ver"
    printf '_nv_pkg=%s\n'                "$_nv_pkg"
    printf '_nv_sha256=%s\n'             "$_nv_sha256"
    printf '_build_archpkg=%s\n'         "$_build_archpkg"
    printf '_build_deb=%s\n'             "$_build_deb"
    printf '_major=%s\n'                 "$_major"
    printf '_minor=%s\n'                 "$_minor"
    printf '_tagrel=%s\n'                "$_tagrel"
    printf 'pkgver=%s\n'                 "$pkgver"
    printf '_stable=%s\n'                "$_stable"
    printf 'pkgrel=%s\n'                 "$pkgrel"
    printf '_srcver=%s\n'                "$_srcver"
    printf '_srcname=%s\n'               "$_srcname"
    printf '_kernel_b2sum=%s\n'          "$_kernel_b2sum"
    printf '_config_b2sum=%s\n'          "$_config_b2sum"
    printf '_dkms_clang_patch_b2sum=%s\n' "$_dkms_clang_patch_b2sum"
    printf '_validpgpkeys=%s\n'          "${_validpgpkeys[*]}"
    printf '_patchsource=%s\n'           "$_patchsource"
    printf 'BUILD_DIR=%s\n'              "$BUILD_DIR"
    printf 'SRC_DIR=%s\n'                "$SRC_DIR"
    printf 'DOWNLOAD_DIR=%s\n'           "$DOWNLOAD_DIR"
    printf 'SOURCE_DATE_EPOCH=%s\n'      "$SOURCE_DATE_EPOCH"
    exit 0
fi

# ======================== ACTIVE CONFIGURATION ========================
_onoff() { [ "$1" = "yes" ] && echo -e "${GREEN}yes${NC}" || echo -e "${YELLOW}$1${NC}"; }
print_step "Active configuration"
print_info "Kernel:   ${_srcver}-cachyos-${_cpusched} (pkgrel ${pkgrel})"
print_info "Packages: Debian=$(_onoff "$_build_deb"), headers=$(_onoff yes), Arch=$(_onoff "$_build_archpkg")"
print_info "CPU:      ${_cpusched} / ${_preempt} preempt / ${_HZ_ticks}Hz / ${_processor_opt} / LLVM LTO ${_use_llvm_lto}"
print_info "Extras:   ZFS=$(_onoff "$_build_zfs"), r8125=$(_onoff "$_build_r8125"), NVIDIA=$(_onoff "$_build_nvidia")"
if [ "$_build_nvidia" = "yes" ]; then
    print_info "NVIDIA:   userspace=$(_onoff "$_nv_userspace"), nouveau blacklist=$(_onoff "$_blacklist_nouveau"), driver ${_nv_ver}"
    print_info "CUDA:     ${_cuda_ver} (meta: ${_cuda_meta}, setup=$(_onoff "$_cuda_setup"), dependency: ${_cuda_toolkit_dep}, download=$(_onoff "$_cuda_download"))"
fi

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
print_step "Step 1: Checking Ubuntu Resolute System and usr-merge status"
if ! command -v lsb_release >/dev/null 2>&1 || ! lsb_release -cs 2>/dev/null | grep -q "resolute"; then
    print_warning "This script is optimized for Ubuntu Resolute 26.04. Current system: $(lsb_release -cs 2>/dev/null || echo 'Unknown')"
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
    REQUIRED_PACKAGES+=(clang-22 llvm-22 lld-22 libclang-22-dev)
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

# CUDA 12.9 is the last toolkit for Pascal, and NVIDIA publishes 12.x only for
# Ubuntu 24.04. With _cuda_download=yes, fetch the exact .debs from NVIDIA's
# ubuntu2404 repo and verify the index signature and each file's SHA256. Nothing is
# installed and no apt source is added: the verified .debs stay in
# ${DOWNLOAD_DIR}/cuda-<ver> and the install command is printed. Their Ubuntu
# dependencies resolve from Resolute's own repos (libtinfo5 is an "| libtinfo6"
# alternative).
fetch_cuda_packages() {
    if [ "$_build_nvidia" != "yes" ] || [ "$_cuda_setup" != "yes" ] || [ "$_cuda_download" != "yes" ]; then
        return 0
    fi
    local pkg="$_cuda_meta"
    local ver="${_cuda_ver/-/.}"
    local cdir="${DOWNLOAD_DIR}/cuda-${ver}"
    [ -f "${cdir}/.complete" ] && return 0
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        return 0
    fi
    if [ -x "/usr/local/cuda-${ver}/bin/nvcc" ]; then
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || print_error "python3 is required to resolve the CUDA package set"
    local repo="https://developer.download.nvidia.com/compute/cuda/repos/${_cuda_repo_suite}/x86_64"
    mkdir -p "$cdir"
    print_info "Fetching NVIDIA's CUDA ${ver} repo index..."
    wget -q -O "${cdir}/Packages.gz" "${repo}/Packages.gz" || print_error "Could not fetch ${repo}/Packages.gz"
    wget -q -O "${cdir}/InRelease" "${repo}/InRelease" || print_error "Could not fetch ${repo}/InRelease"
    gzip -dc "${cdir}/Packages.gz" > "${cdir}/Packages"
    # Verify the index with the keyring shipped by this repo: ubuntu2404 and
    # ubuntu2604 are signed by different NVIDIA keys. The keyring package name
    # carries its version, so take the current filename from the index.
    local kdir="${cdir}/keyring"
    mkdir -p "$kdir"
    local kfile
    kfile="$(awk -v RS='' '$1=="Package:" && $2=="cuda-keyring" {for(i=1;i<=NF;i++) if($i=="Filename:") print $(i+1)}' "${cdir}/Packages" | tail -n 1)"
    [ -n "$kfile" ] || print_error "cuda-keyring not found in NVIDIA's index"
    wget -q -O "${kdir}/cuda-keyring.deb" "${repo}/${kfile#./}" || print_error "Could not fetch ${kfile}"
    dpkg-deb -x "${kdir}/cuda-keyring.deb" "${kdir}/root" || print_error "Could not extract cuda-keyring"
    local keyring="${kdir}/root/usr/share/keyrings/cuda-archive-keyring.gpg"
    if command -v gpgv >/dev/null 2>&1; then
        gpgv --keyring "$keyring" "${cdir}/InRelease" >/dev/null 2>&1 || print_error "CUDA repo InRelease signature verification failed"
    else
        print_warning "gpgv is unavailable; CUDA repo signature not verified"
    fi
    python3 -I - "${cdir}/Packages" "$pkg" > "${cdir}/filelist.txt" <<'PY'
import re, sys
path, root = sys.argv[1], sys.argv[2]
pkgs = {}
for para in open(path, encoding="utf-8", errors="replace").read().split("\n\n"):
    f = {}
    for line in para.splitlines():
        if not line or line[0] in " \t" or ":" not in line:
            continue
        k, v = line.split(":", 1)
        f[k.strip()] = v.strip()
    if f.get("Package"):
        pkgs.setdefault(f["Package"], []).append(f)
def dep_name(clause):
    c = clause.split("|")[0].split(":")[0].strip()
    m = re.match(r"([A-Za-z0-9.+_-]+)", c)
    return m.group(1) if m else None
seen, stack = set(), [root]
while stack:
    name = stack.pop()
    if name in seen or name not in pkgs:
        continue
    seen.add(name)
    st = pkgs[name][-1]
    fn = st.get("Filename", "").lstrip("./")
    print(fn, st.get("SHA256", ""))
    for clause in st.get("Depends", "").split(","):
        d = dep_name(clause)
        if d in pkgs:
            stack.append(d)
PY
    [ -s "${cdir}/filelist.txt" ] || print_error "Could not resolve ${pkg} from NVIDIA's index"
    print_info "Downloading $(wc -l < "${cdir}/filelist.txt") CUDA packages..."
    local fname sha out
    while read -r fname sha; do
        [ -n "$fname" ] || continue
        out="${cdir}/$(basename "$fname")"
        if [ ! -f "$out" ]; then
            wget -q -O "$out" "${repo}/${fname}" || print_error "Failed to download ${fname}"
        fi
        if [ -n "$sha" ]; then
            if ! printf '%s  %s\n' "$sha" "$out" | sha256sum -c --quiet -; then
                rm -f "$out"
                print_error "SHA256 mismatch for ${fname}"
            fi
        fi
    done < "${cdir}/filelist.txt"
    touch "${cdir}/.complete"
    print_success "CUDA ${ver} packages verified in ${cdir}"
    print_info "Install all build packages with: sudo ${BUILD_DIR}/install-debs.sh (generated at the end of the build)"
}

fetch_cuda_packages

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
    wget -O "${DOWNLOAD_DIR}/config" "https://raw.githubusercontent.com/CachyOS/linux-cachyos/d16eb41f38a434414c4c8e9bfdc5a1c3d7c81ed5/linux-cachyos/config"
fi
[[ "$(b2sum "${DOWNLOAD_DIR}/config" | cut -d' ' -f1)" == "$_config_b2sum" ]] || print_error "Config b2sum mismatch"

case "$_cpusched" in
    cachyos|bore|rt-bore)
        [ ! -f "${DOWNLOAD_DIR}/0001-bore-cachy.patch" ] && wget -P "${DOWNLOAD_DIR}" "${_patchsource}/sched/0001-bore-cachy.patch" ;;
    bmq)
        [ ! -f "${DOWNLOAD_DIR}/0001-prjc-cachy.patch" ] && wget -P "${DOWNLOAD_DIR}" "${_patchsource}/sched/0001-prjc-cachy.patch" ;;
esac
[[ "$_cpusched" == "rt" || "$_cpusched" == "rt-bore" ]] && wget -q -N -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/0001-rt-i915.patch"
[[ "$_use_llvm_lto" != "none" ]] && [ ! -f "${DOWNLOAD_DIR}/dkms-clang.patch" ] && wget -P "${DOWNLOAD_DIR}" "${_patchsource}/misc/dkms-clang.patch"
if [[ "$_use_llvm_lto" != "none" ]]; then
    [[ "$(b2sum "${DOWNLOAD_DIR}/dkms-clang.patch" | cut -d' ' -f1)" == "$_dkms_clang_patch_b2sum" ]] || print_error "dkms-clang.patch b2sum mismatch"
fi
[ "$_build_zfs" = "yes" ] && [ ! -d "${SRC_DIR}/zfs" ] && git clone --depth=1 https://github.com/cachyos/zfs.git "${SRC_DIR}/zfs" && git -C "${SRC_DIR}/zfs" fetch origin fb48c76e17d3e0092fbba430a9eec1960e1b9961 --depth=1 && git -C "${SRC_DIR}/zfs" checkout fb48c76e17d3e0092fbba430a9eec1960e1b9961
if [ "$_build_r8125" = "yes" ] && [ ! -d "${SRC_DIR}/r8125" ]; then
    if [ "$_r8125_src" = "oldtag" ]; then
        # Pin to 9.017.01 — last known-good before 9.018.00 link-flap regression
        git clone --depth=1 https://github.com/Autisticestradioluser/r8125.git "${SRC_DIR}/r8125"
        git -C "${SRC_DIR}/r8125" fetch origin 68eb2645137288688583bbf3c111ec772b7d7327 --depth=1
        git -C "${SRC_DIR}/r8125" checkout 68eb2645137288688583bbf3c111ec772b7d7327
    else
        git clone --branch=rtl8125bp-fix-v7-aldps-eee-rpm --depth=1 https://github.com/Autisticestradioluser/r8125.git "${SRC_DIR}/r8125"
    fi
fi

if [ "$_build_nvidia" = "yes" ]; then
    [ ! -f "${DOWNLOAD_DIR}/${_nv_pkg}.run" ] && wget -P "${DOWNLOAD_DIR}" "https://download.nvidia.com/XFree86/Linux-x86_64/${_nv_ver}/${_nv_pkg}.run"
    [ ! -f "${DOWNLOAD_DIR}/${_nv_pkg}.run.sha256sum" ] && wget -P "${DOWNLOAD_DIR}" "https://download.nvidia.com/XFree86/Linux-x86_64/${_nv_ver}/${_nv_pkg}.run.sha256sum"
    [ ! -f "${DOWNLOAD_DIR}/0001-nvidia-kms.patch" ] && wget -P "${DOWNLOAD_DIR}" "https://raw.githubusercontent.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/main/patches/nvidia/0001-nvidia-kms.patch"
fi

# ======================== EXTRACT & CONFIGURE ========================
print_step "Step 5: Extracting and Preparing Sources"
cd "${SRC_DIR}"
tar -xf "${DOWNLOAD_DIR}/${_srcname}.tar.gz"
cd "${_srcname}"

echo "-$pkgrel" > localversion.10-pkgrel
echo "-cachyos-${_cpusched}" > localversion.20-pkgname

# Extract NVIDIA proprietary driver source
if [ "$_build_nvidia" = "yes" ]; then
    print_info "Extracting NVIDIA driver source..."
    cd "${DOWNLOAD_DIR}"
    sh "${_nv_pkg}.run" --extract-only
    cd "${SRC_DIR}/${_srcname}"

    # Verify NVIDIA driver sha256sum against NVIDIA's official checksum file
    print_info "Verifying NVIDIA driver sha256sum..."
    _nv_hashed=$(sha256sum "${DOWNLOAD_DIR}/${_nv_pkg}.run" | cut -d' ' -f1)
    _nv_expected=$(awk '{print $1}' "${DOWNLOAD_DIR}/${_nv_pkg}.run.sha256sum")
    [[ "${_nv_hashed}" == "${_nv_expected}" ]] || print_error "NVIDIA sha256sum mismatch"
fi

print_step "Step 6: Applying Patches"
[[ "$_use_llvm_lto" != "none" ]] && patch -Np1 < "${DOWNLOAD_DIR}/dkms-clang.patch"
case "$_cpusched" in
    cachyos|bore|rt-bore) patch -Np1 < "${DOWNLOAD_DIR}/0001-bore-cachy.patch" ;;
    bmq) patch -Np1 < "${DOWNLOAD_DIR}/0001-prjc-cachy.patch" ;;
esac
[[ "$_cpusched" == "rt" || "$_cpusched" == "rt-bore" ]] && patch -Np1 < "${DOWNLOAD_DIR}/0001-rt-i915.patch"

# Apply NVIDIA KMS patch (fetched from repo raw GitHub URL)
if [ "$_build_nvidia" = "yes" ] && [ -f "${DOWNLOAD_DIR}/0001-nvidia-kms.patch" ]; then
    print_info "Applying NVIDIA KMS patch..."
    patch -Np1 -i "${DOWNLOAD_DIR}/0001-nvidia-kms.patch" -d "${DOWNLOAD_DIR}/${_nv_pkg}/kernel"
fi

print_step "Step 7: Configuring Kernel"
cp "${DOWNLOAD_DIR}/config" .config
BUILD_FLAGS=()
[[ "$_use_llvm_lto" != "none" ]] && BUILD_FLAGS=(CC=clang-22 LD=ld.lld-22 LLVM=-22 LLVM_IAS=1)

[ -n "$_processor_opt" ] && MARCH="${_processor_opt^^}" && case "$MARCH" in
    GENERIC_V[1-4]) scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU --set-val X86_64_VERSION "${MARCH//GENERIC_V}" ;;
    ZEN4) scripts/config -d GENERIC_CPU -e MZEN4 -d X86_NATIVE_CPU ;;
    NATIVE) scripts/config -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU ;;
esac

[ "$_cachy_config" = "yes" ] && scripts/config -e CACHY

case "$_cpusched" in
    cachyos|bore) scripts/config -e SCHED_BORE ;;
    bmq) scripts/config -e SCHED_ALT -e SCHED_BMQ ;;
    rt) scripts/config -e PREEMPT_RT ;;
    rt-bore) scripts/config -e SCHED_BORE -e PREEMPT_RT ;;
esac

[ "$_use_kcfi" = "yes" ] && scripts/config -e CFI

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

# NVIDIA proprietary driver is incompatible with PREEMPT_RT kernels
if [ "$_build_nvidia" = "yes" ] && [[ "$_cpusched" == "rt" || "$_cpusched" == "rt-bore" ]]; then
    print_error "NVIDIA proprietary driver is incompatible with RT kernels (_cpusched=$_cpusched). Set _build_nvidia=no or use a non-RT scheduler."
fi

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

if [ "$_build_nvidia" = "yes" ]; then
    print_info "Building NVIDIA proprietary kernel modules..."
    cd "${DOWNLOAD_DIR}/${_nv_pkg}/kernel"
    MODULE_FLAGS=(
        KERNEL_UNAME="${KERNEL_VERSION}"
        IGNORE_PREEMPT_RT_PRESENCE=1
        SYSSRC="${SRC_DIR}/${_srcname}"
        SYSOUT="${SRC_DIR}/${_srcname}"
    )
    MODULE_FLAGS+=(NV_EXCLUDE_BUILD_MODULES='__EXCLUDE_MODULES')
    make "${BUILD_FLAGS[@]}" "${MODULE_FLAGS[@]}" -j"$(nproc)" modules
    cd "${SRC_DIR}/${_srcname}"
fi

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
KERNEL_IMAGE="$(make -s image_name)"
install -Dm644 "${KERNEL_IMAGE}" "${INSTALL_DIR}/boot/vmlinuz-${KERNEL_VERSION}"
install -Dm644 System.map "${INSTALL_DIR}/boot/System.map-${KERNEL_VERSION}"
install -Dm644 .config "${INSTALL_DIR}/boot/config-${KERNEL_VERSION}"

if [ "$USR_MERGED" = true ]; then
    make INSTALL_MOD_PATH="${INSTALL_DIR}/usr" INSTALL_MOD_STRIP=1 modules_install
else
    make INSTALL_MOD_PATH="${INSTALL_DIR}" INSTALL_MOD_STRIP=1 modules_install
fi

# Arch kernels also ship modulesdir/vmlinuz (arms the 90-mkinitcpio-install hook
# and systemd hibernation) and a pkgbase marker (mkinitcpio names presets after it).
install -Dm644 "${KERNEL_IMAGE}" "${MODULES_BASE_DIR}/${KERNEL_VERSION}/vmlinuz"
printf '%s\n' "linux-cachyos-${_cpusched}" > "${MODULES_BASE_DIR}/${KERNEL_VERSION}/pkgbase"

# The image must not own the build/source symlinks: kbuild leaves an absolute
# host path there, and the headers package owns the relative one. Stripping them
# here mirrors the Debian branch and avoids a split-package file conflict.
rm -f "${MODULES_BASE_DIR}/${KERNEL_VERSION}/build" "${MODULES_BASE_DIR}/${KERNEL_VERSION}/source"

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

# Install the NVIDIA driver license text at the given path. The custom license must
# ship with the NVIDIA packages, and the text exists in exactly two places: the
# distro's installed driver package, or the driver runfile this script downloads.
# nvidia-580xx-utils installs under the legacy nvidia-utils license dir (see the
# nvidia-580xx-utils PKGBUILD), and Ubuntu's nvidia-driver-<major> ships LICENSE.gz.
install_nvidia_license() {
    local dest="$1" lic="" tmp=""
    if [ -f /usr/share/licenses/nvidia-utils/LICENSE ]; then
        lic=/usr/share/licenses/nvidia-utils/LICENSE
    elif [ -f /usr/share/licenses/nvidia-580xx-utils/LICENSE ]; then
        lic=/usr/share/licenses/nvidia-580xx-utils/LICENSE
    elif [ -f "/usr/share/doc/nvidia-driver-${_nv_ver%%.*}/LICENSE.gz" ]; then
        tmp="$(mktemp)"
        if gzip -dc "/usr/share/doc/nvidia-driver-${_nv_ver%%.*}/LICENSE.gz" > "$tmp" && [ -s "$tmp" ]; then
            lic="$tmp"
        else
            rm -f "$tmp"
            tmp=""
        fi
    fi
    if [ -z "$lic" ] && [ -f "${DOWNLOAD_DIR}/${_nv_pkg}/LICENSE" ]; then
        lic="${DOWNLOAD_DIR}/${_nv_pkg}/LICENSE"
    fi
    if [ -z "$lic" ]; then
        print_error "NVIDIA license not found: install nvidia-driver-${_nv_ver%%.*} or nvidia-580xx-utils, or keep ${DOWNLOAD_DIR}/${_nv_pkg}/LICENSE"
    fi
    install -Dm644 "$lic" "$dest"
    if [ -n "$tmp" ]; then rm -f "$tmp"; fi
}

# nouveau binds NVIDIA GPUs before the proprietary module can probe them, so
# keep it from loading. Ships only in the NVIDIA packages, never the base image.
install_nouveau_blacklist() {
    local pkgroot="$1"
    mkdir -p "${pkgroot}/etc/modprobe.d"
    cat > "${pkgroot}/etc/modprobe.d/blacklist-cachyos-nouveau.conf" <<'EOF'
blacklist nouveau
blacklist nova_core
blacklist nova_drm
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
install nouveau /bin/false
EOF
}

# Install the complete user-space from the extracted NVIDIA .run into a Debian
# package root. Excludes only the kernel sources, 32-bit compat and installer
# internals. Paths follow Ubuntu multiarch conventions so ldconfig finds them.
# Layout mirrors what the nvidia-580xx-utils package ships on Arch.
install_nvidia_userspace() {
    local pkgroot="$1" srcdir="$2" ver="$3"
    local libdir="${pkgroot}/usr/lib/x86_64-linux-gnu"
    local bindir="${pkgroot}/usr/bin"

    mkdir -p "${libdir}" "${bindir}" \
        "${pkgroot}/usr/lib/xorg/modules/drivers" \
        "${pkgroot}/usr/lib/xorg/modules/extensions" \
        "${pkgroot}/usr/lib/x86_64-linux-gnu/vdpau" \
        "${pkgroot}/usr/lib/nvidia/wine" \
        "${pkgroot}/usr/lib/firmware/nvidia/${ver}" \
        "${pkgroot}/usr/lib/systemd/system" \
        "${pkgroot}/usr/lib/systemd/system-sleep" \
        "${pkgroot}/usr/lib/udev/rules.d" \
        "${pkgroot}/usr/lib/modprobe.d" \
        "${pkgroot}/usr/lib/sysusers.d" \
        "${pkgroot}/usr/share/dbus-1/system.d" \
        "${pkgroot}/usr/share/man/man1" \
        "${pkgroot}/usr/share/nvidia" \
        "${pkgroot}/usr/share/vulkan/icd.d" \
        "${pkgroot}/usr/share/vulkan/implicit_layer.d" \
        "${pkgroot}/usr/share/egl/egl_external_platform.d" \
        "${pkgroot}/usr/share/X11/xorg.conf.d" \
        "${pkgroot}/etc/OpenCL/vendors"

    # Shared libraries -> multiarch dir. Skip vendor-neutral libglvnd/OpenCL
    # loader files (provided by Ubuntu's libglvnd0 / ocl-icd-libopencl1) and
    # libs that live in dedicated dirs.
    while IFS= read -r f; do
        local base
        base="$(basename "$f")"
        case "$base" in
            libGL.so.*|libGLX.so.0|libGLdispatch.so.0|libOpenGL.so.0|libEGL.so.*|\
            libGLESv1_CM.so.*|libGLESv2.so.*|libOpenCL.so.*|\
            libvdpau_nvidia.so.*|libglxserver_nvidia.so.*) continue ;;
        esac
        cp -a "$f" "${libdir}/"
    done < <(find "${srcdir}" -maxdepth 1 -type f -name '*.so.*' | sort)

    # The .run ships no symlinks; create the SONAME links ldconfig/apps expect.
    while IFS= read -r f; do
        local soname base
        soname="$(objdump -p "$f" 2>/dev/null | awk '/SONAME/{print $2; exit}')"
        base="$(basename "$f")"
        if [ -n "$soname" ] && [ "$soname" != "$base" ]; then
            ln -sfn "$base" "${libdir}/${soname}"
        fi
    done < <(find "${libdir}" -maxdepth 1 -type f -name '*.so.*' | sort)

    # Binaries
    for b in nvidia-smi nvidia-modprobe nvidia-persistenced nvidia-settings \
             nvidia-xconfig nvidia-debugdump nvidia-pcc nvidia-ngx-updater nvidia-bug-report.sh \
             nvidia-powerd nvidia-sleep.sh nvidia-cuda-mps-server nvidia-cuda-mps-control; do
        [ -f "${srcdir}/${b}" ] && cp -a "${srcdir}/${b}" "${bindir}/"
    done
    # nvidia-modprobe creates /dev/nvidia* and loads nvidia-uvm for unprivileged
    # CUDA processes; NVIDIA ships it setuid root for this reason.
    chmod 4755 "${bindir}/nvidia-modprobe" 2>/dev/null || true

    # Xorg driver and GLX server module
    [ -f "${srcdir}/nvidia_drv.so" ] && cp -a "${srcdir}/nvidia_drv.so" "${pkgroot}/usr/lib/xorg/modules/drivers/"
    find "${srcdir}" -maxdepth 1 -type f -name 'libglxserver_nvidia.so.*' \
        -exec cp -a {} "${pkgroot}/usr/lib/xorg/modules/extensions/" \; 2>/dev/null || true
    find "${srcdir}" -maxdepth 1 -type f -name 'libvdpau_nvidia.so.*' \
        -exec cp -a {} "${libdir}/vdpau/" \; 2>/dev/null || true

    # Vendor/config files
    [ -f "${srcdir}/nvidia.icd" ] && cp -a "${srcdir}/nvidia.icd" "${pkgroot}/etc/OpenCL/vendors/"
    for j in nvidia_icd.json nvidia_icd_vksc.json; do
        [ -f "${srcdir}/${j}" ] && cp -a "${srcdir}/${j}" "${pkgroot}/usr/share/vulkan/icd.d/"
    done
    [ -f "${srcdir}/nvidia_layers.json" ] && cp -a "${srcdir}/nvidia_layers.json" "${pkgroot}/usr/share/vulkan/implicit_layer.d/"
    for j in 10_nvidia.json 10_nvidia_wayland.json 15_nvidia_gbm.json 20_nvidia_xcb.json 20_nvidia_xlib.json; do
        [ -f "${srcdir}/${j}" ] && cp -a "${srcdir}/${j}" "${pkgroot}/usr/share/egl/egl_external_platform.d/"
    done
    [ -f "${srcdir}/nvidia-drm-outputclass.conf" ] && cp -a "${srcdir}/nvidia-drm-outputclass.conf" "${pkgroot}/usr/share/X11/xorg.conf.d/"
    [ -f "${srcdir}/nvidia-dbus.conf" ] && cp -a "${srcdir}/nvidia-dbus.conf" "${pkgroot}/usr/share/dbus-1/system.d/"
    for f in nvidia-application-profiles-* nvoptix.bin sandboxutils-filelist.json; do
        [ -f "${srcdir}/${f}" ] && cp -a "${srcdir}/${f}" "${pkgroot}/usr/share/nvidia/"
    done
    for dll in nvngx.dll _nvngx.dll nvngx_dlssg.dll; do
        [ -f "${srcdir}/${dll}" ] && cp -a "${srcdir}/${dll}" "${pkgroot}/usr/lib/nvidia/wine/"
    done

    # GSP firmware, systemd sleep/power units, persistenced unit, man pages
    [ -d "${srcdir}/firmware" ] && cp -a "${srcdir}/firmware/." "${pkgroot}/usr/lib/firmware/nvidia/${ver}/"
    find "${srcdir}/systemd" -type f -name '*.service' \
        -exec cp -a {} "${pkgroot}/usr/lib/systemd/system/" \; 2>/dev/null || true
    [ -f "${srcdir}/systemd/system-sleep/nvidia" ] && \
        install -Dm755 "${srcdir}/systemd/system-sleep/nvidia" "${pkgroot}/usr/lib/systemd/system-sleep/nvidia"
    if [ -f "${srcdir}/nvidia-persistenced-init.tar.bz2" ]; then
        local pdir; pdir="$(mktemp -d)"
        tar -xjf "${srcdir}/nvidia-persistenced-init.tar.bz2" -C "${pdir}" 2>/dev/null || true
        if [ -f "${pdir}/systemd/nvidia-persistenced.service.template" ]; then
            sed 's/__USER__/nvidia-persistenced/' "${pdir}/systemd/nvidia-persistenced.service.template" \
                > "${pkgroot}/usr/lib/systemd/system/nvidia-persistenced.service"
        fi
        rm -rf "${pdir}"
    fi
    find "${srcdir}" -maxdepth 1 -type f -name '*.1.gz' \
        -exec cp -a {} "${pkgroot}/usr/share/man/man1/" \; 2>/dev/null || true

    # Preserve video memory across suspend (nvidia-580xx-utils ships the same options)
    cat > "${pkgroot}/usr/lib/modprobe.d/nvidia-580xx-utils.conf" <<'EOF'
softdep nvidia post: nvidia-uvm nvidia-drm
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
EOF

    # Do not freeze user sessions on sleep/hibernate with NVIDIA (nvidia-utils default)
    local unit
    for unit in systemd-homed systemd-suspend systemd-suspend-then-hibernate systemd-hibernate systemd-hybrid-sleep; do
        mkdir -p "${pkgroot}/usr/lib/systemd/system/${unit}.service.d"
        if [ "$unit" = "systemd-homed" ]; then
            printf '%s\n' '[Service]' 'Environment="SYSTEMD_HOME_LOCK_FREEZE_SESSION=false"' \
                > "${pkgroot}/usr/lib/systemd/system/${unit}.service.d/10-nvidia-no-freeze-session.conf"
        else
            printf '%s\n' '[Service]' 'Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false"' \
                > "${pkgroot}/usr/lib/systemd/system/${unit}.service.d/10-nvidia-no-freeze-session.conf"
        fi
    done

    # Persistence daemon user (same sysusers entry as nvidia-utils)
    printf '%s\n' "u! nvidia-persistenced 143 'NVIDIA Persistence Daemon'" \
        > "${pkgroot}/usr/lib/sysusers.d/nvidia-580xx-utils.conf"

    # Device nodes: with no user-space installed there are no /dev/nvidia* nodes.
    # nvidia-modprobe creates them and loads nvidia-uvm on module/device events.
    cat > "${pkgroot}/usr/lib/udev/rules.d/70-nvidia.rules" <<'EOF'
KERNEL=="nvidia", RUN+="/usr/bin/nvidia-modprobe -c0 -u"
KERNEL=="nvidia-uvm", RUN+="/usr/bin/nvidia-modprobe -u -c=0"
SUBSYSTEM=="module", ACTION=="add", KERNEL=="nvidia", RUN+="/usr/bin/nvidia-modprobe -c0 -u"
SUBSYSTEM=="module", ACTION=="add", KERNEL=="nvidia_uvm", RUN+="/usr/bin/nvidia-modprobe -u -c=0"
KERNEL=="nvidia*", MODE="0666"
EOF
}

# Make the CUDA toolkit's nvcc available in login shells. The toolkit itself is
# declared via package metadata (NVIDIA repo), not bundled into the kernel deb.
install_cuda_profile() {
    local pkgroot="$1"
    mkdir -p "${pkgroot}/etc/profile.d"
    cat > "${pkgroot}/etc/profile.d/cachyos-cuda.sh" <<'EOF'
# Managed by the CachyOS NVIDIA kernel package
export CUDA_HOME=/usr/local/cuda
export PATH="$CUDA_HOME/bin:$PATH"
EOF
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

if [ "$_build_nvidia" = "yes" ]; then
    print_info "Installing NVIDIA modules"
    nvidia_DIR="${MODULES_BASE_DIR}/${KERNEL_VERSION}/kernel/extra"
    mkdir -p "${nvidia_DIR}"
    find "${DOWNLOAD_DIR}/${_nv_pkg}/kernel" -name "*.ko" -exec cp {} "${nvidia_DIR}/" \;
    sign_modules "${nvidia_DIR}"
fi

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

# Headers staging (always built; upstream ships the headers split unconditionally)
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

# Remove dangling symlinks that reference source-tree paths (scripts/dtc, tools, etc.)
# These are not needed for out-of-tree module building from installed headers
find "${HEADERS_DIR}" -xtype l -delete 2>/dev/null || true

fix_permissions() {
    local root="${INSTALL_DIR}"
    print_info "=== Fixing permissions for ${root} ==="
    find "${root}" -type d -exec chmod 0755 {} + 2>/dev/null || true
    find "${root}" -type f -perm /111 -exec chmod 0755 {} + 2>/dev/null || true
    find "${root}" -type f ! -perm /111 -exec chmod 0644 {} + 2>/dev/null || true
}
fix_permissions

# Semantic validation of an Arch .pkg.tar.zst. Replaces the old presence-only
# greps (which passed corrupt/empty packages as SUCCESS). $1=package path,
# $2=staging dir (size comparison), $3=label.
validate_arch_pkg() {
    local pkg="$1" stage="$2" label="$3"
    local tmp m pkgsize installed_size path digest actual line
    tmp="$(mktemp -d)" || { print_error "$label validation failed: cannot create temp dir"; return 1; }

    # --- member inventory: metadata members present, .PKGINFO first.
    # .INSTALL is required only when the package ships an install scriptlet
    # (the headers split intentionally has none).
    members="$(bsdtar -tf "$pkg" 2>/dev/null)" || { print_error "$label validation failed: cannot list archive members"; rm -rf "$tmp"; return 1; }
    local required_meta=".PKGINFO .MTREE .BUILDINFO"
    [ -e "$stage/.INSTALL" ] && required_meta="$required_meta .INSTALL"
    for m in $required_meta; do
        printf '%s\n' "$members" | grep -qx "$m" || { print_error "$label validation failed: missing member $m"; rm -rf "$tmp"; return 1; }
    done
    [ "$(printf '%s\n' "$members" | head -n 1)" = ".PKGINFO" ] || { print_error "$label validation failed: .PKGINFO is not the first member"; rm -rf "$tmp"; return 1; }
    # B1 regression guard: libalpm skips members with a leading "./", so payload
    # must be archived with bare names.
    printf '%s\n' "$members" | grep -q '^\./' && { print_error "$label validation failed: payload member carries leading './'"; rm -rf "$tmp"; return 1; }

    # --- extract everything to temp (avoids pipes under pipefail) ---
    bsdtar -xf "$pkg" -C "$tmp" 2>/dev/null || { print_error "$label validation failed: cannot extract archive"; rm -rf "$tmp"; return 1; }

    # --- .INSTALL must run depmod when the package ships one ---
    if [ -e "$stage/.INSTALL" ]; then
        grep -q 'depmod' "$tmp/.INSTALL" 2>/dev/null || { print_error "$label validation failed: .INSTALL has no depmod"; rm -rf "$tmp"; return 1; }
    fi

    # --- .BUILDINFO: format=2, pkgname, pkgarch, builddate ---
    grep -qx 'format = 2' "$tmp/.BUILDINFO" 2>/dev/null || { print_error "$label validation failed: .BUILDINFO format != 2"; rm -rf "$tmp"; return 1; }
    grep -qE '^pkgname = ' "$tmp/.BUILDINFO" 2>/dev/null || { print_error "$label validation failed: .BUILDINFO missing pkgname"; rm -rf "$tmp"; return 1; }
    grep -qE '^pkgarch = ' "$tmp/.BUILDINFO" 2>/dev/null || { print_error "$label validation failed: .BUILDINFO missing pkgarch"; rm -rf "$tmp"; return 1; }
    grep -qE '^builddate = ' "$tmp/.BUILDINFO" 2>/dev/null || { print_error "$label validation failed: .BUILDINFO missing builddate"; rm -rf "$tmp"; return 1; }

    # --- .PKGINFO size matches installed bytes ---
    pkgsize="$(grep -E '^size = ' "$tmp/.PKGINFO" 2>/dev/null | head -n 1 | cut -d= -f2 | tr -d ' ')"
    installed_size="$(find "$stage" -mindepth 1 -maxdepth 1 ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' -exec du -sb {} + 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"
    [ -n "$pkgsize" ] && [ "$pkgsize" = "$installed_size" ] || { print_error "$label validation failed: .PKGINFO size ($pkgsize) != installed ($installed_size)"; rm -rf "$tmp"; return 1; }

    # --- .MTREE entry set must match archive data members (bare names) ---
    bsdtar -xOf "$pkg" .MTREE > "$tmp/.mtree.gz" 2>/dev/null || { print_error "$label validation failed: cannot extract .MTREE"; rm -rf "$tmp"; return 1; }
    gzip -dc "$tmp/.mtree.gz" > "$tmp/.mtree" 2>/dev/null || { print_error "$label validation failed: cannot decompress .MTREE"; rm -rf "$tmp"; return 1; }
    local archive_data mtree_data
    archive_data="$(bsdtar -tf "$pkg" 2>/dev/null | grep -vE '^\.(PKGINFO|MTREE|BUILDINFO|INSTALL)$' | sed -E 's#^\./##; s#/$##' | sort)"
    mtree_data="$(grep -vE '^(#|/set )' "$tmp/.mtree" | awk '{sub(/^\.\//,"",$1); print $1}' | sort)"
    [ "$archive_data" = "$mtree_data" ] || { print_error "$label validation failed: .MTREE entry set does not match archive payload"; rm -rf "$tmp"; return 1; }

    # --- .MTREE sha256digest values must match extracted file bytes ---
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            *sha256digest=*)
                path="$(printf '%s' "$line" | sed -E 's#^\.\/##; s# .*##')"
                digest="$(printf '%s' "$line" | sed -E 's/.*sha256digest=([^ ]+).*/\1/')"
                [ -n "$path" ] && [ -n "$digest" ] || continue
                actual="$(sha256sum "$tmp/$path" 2>/dev/null | awk '{print $1}')"
                [ "$actual" = "$digest" ] || { print_error "$label validation failed: .MTREE sha256 mismatch for $path"; rm -rf "$tmp"; return 1; }
                ;;
        esac
    done < "$tmp/.mtree"

    rm -rf "$tmp"
    return 0
}

# ======================== PACKAGING ========================
print_step "Step 10: Packaging"

# Generate dynamic description
DESC="Linux ${KERNEL_VERSION} CachyOS kernel [${_cpusched^^} sched] [${_preempt} preempt] [${_HZ_ticks}Hz] [BBRv3]"
[[ "$_use_llvm_lto" != "none" ]] && DESC+=" [Clang-${_use_llvm_lto^^} LTO]" || DESC+=" [GCC]"
[[ "$_cc_harder" == "yes" ]] && DESC+=" [-O3]"
[[ "$_hugepage" == "always" ]] && DESC+=" [THP=always]"
[[ "$_build_zfs" == "yes" ]] && DESC+=" [ZFS]"
[[ "$_build_r8125" == "yes" ]] && DESC+=" [r8125]"
[[ "$_build_nvidia" == "yes" ]] && DESC+=" [nvidia]"

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
    # NVIDIA modules are owned solely by the split NVIDIA package.
    # Keeping them here too causes pacman duplicate-file errors.
    find "${ARCH_IMG}/usr/lib/modules/${KERNEL_VERSION}/kernel/extra" -type f -name 'nvidia*.ko.zst' -delete 2>/dev/null || true
    cp -a "${INSTALL_DIR}/etc" "${ARCH_IMG}/" 2>/dev/null || true

    # mkinitcpio preset (named after pkgbase; mkinitcpio's libalpm scripts key on it)
    mkdir -p "${ARCH_IMG}/etc/mkinitcpio.d"
    cat > "${ARCH_IMG}/etc/mkinitcpio.d/linux-cachyos-${_cpusched}.preset" << EOF
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
    if command -v mkinitcpio >/dev/null 2>&1; then
        mkinitcpio -P || true
    fi
}
post_upgrade() {
    depmod ${KERNEL_VERSION}
    if command -v mkinitcpio >/dev/null 2>&1; then
        mkinitcpio -P || true
    fi
}
post_remove() {
    depmod ${KERNEL_VERSION}
}
EOF

    # Arch pkgver: hyphens become dots, pkgrel appended after final hyphen
    PACMAN_PKGVER="${pkgver}-${pkgrel}"
    PKG_IMG_FILENAME="linux-cachyos-${_cpusched}-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"

    # Calculate size for .PKGINFO (installed size only, excluding metadata files)
    PKG_SIZE=$(find "${ARCH_IMG}" -mindepth 1 -maxdepth 1 \
        ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' \
        -exec du -sb {} + | awk '{sum+=$1} END {print sum+0}')

    # Strict Arch PKGINFO format
    cat > "${ARCH_IMG}/.PKGINFO" << EOF
pkgname = linux-cachyos-${_cpusched}
pkgbase = linux-cachyos-${_cpusched}
pkgver = ${PACMAN_PKGVER}
pkgdesc = ${DESC}
url = https://github.com/CachyOS/linux-cachyos
builddate = ${SOURCE_DATE_EPOCH}
packager = Build-CachyOS-Kernel-On-Ubuntu
size = ${PKG_SIZE}
arch = x86_64
license = GPL-2.0-only
backup = etc/mkinitcpio.d/linux-cachyos-${_cpusched}.preset
depend = coreutils
depend = initramfs
depend = kmod
provides = VIRTUALBOX-GUEST-MODULES WIREGUARD-MODULE KSMBD-MODULE V4L2LOOPBACK-MODULE NTSYNC-MODULE VHBA-MODULE ADIOS-MODULE
optdepend = linux-cachyos-${_cpusched}-headers: headers and scripts for building modules
optdepend = wireless-regdb: to set the correct wireless channels of your country
optdepend = linux-firmware: firmware images needed for some devices
optdepend = modprobed-db: Keeps track of EVERY kernel module that has ever been probed - useful for those of us who make localmodconfig
optdepend = scx-scheds: to use sched-ext schedulers
xdata = pkgtype=pkg
EOF

    cat > "${ARCH_IMG}/.BUILDINFO" << EOF
format = 2
pkgname = linux-cachyos-${_cpusched}
pkgbase = linux-cachyos-${_cpusched}
pkgver = ${PACMAN_PKGVER}
pkgarch = x86_64
packager = Build-CachyOS-Kernel-On-Ubuntu
builddate = ${SOURCE_DATE_EPOCH}
EOF

    # Normalize mtimes, then generate .MTREE (gzip -n omits the timestamp)
    cd "${ARCH_IMG}"
    find . -mindepth 1 -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
    find . -mindepth 1 ! -name '.MTREE' ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.INSTALL' -print0 | \
        bsdtar -cf - --format=mtree --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' --null -T - | gzip -n > .MTREE
    touch -h -d "@${SOURCE_DATE_EPOCH}" .MTREE
    cd - >/dev/null

    # Enforce Archive Ordering using piped zstd (bsdtar --zstd not supported on Ubuntu)
    # Order: .PKGINFO, .MTREE, .BUILDINFO, .INSTALL, then directories/files
    # Root ownership is handled by fakeroot wrapper
    cd "${ARCH_IMG}"
    # NUL-safe, bare member names (no leading "./"): libalpm skips "./"-prefixed
    # payload members and installs zero files, so the four metadata members are
    # emitted first, then every top-level dir/file reported without "./".
    {
        printf '%s\0' .PKGINFO .MTREE .BUILDINFO .INSTALL
        find . -mindepth 1 -maxdepth 1 -type d -printf '%P\0' | sort -z
        find . -mindepth 1 -maxdepth 1 -type f ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' -printf '%P\0' | sort -z
    } | bsdtar --null -T - -cf - | zstd -19 -T0 -f -o "${BUILD_DIR}/${PKG_IMG_FILENAME}"
    cd - >/dev/null

    # Final Validation Step
    validate_arch_pkg "${BUILD_DIR}/${PKG_IMG_FILENAME}" "${ARCH_IMG}" "Arch image"
    print_success "Arch image: ${BUILD_DIR}/${PKG_IMG_FILENAME}"

    # NVIDIA separate split package
    if [ "$_build_nvidia" = "yes" ]; then
        print_info "Building NVIDIA Arch package..."
        NVIDIA_DIR="${BUILD_DIR}/pkg-arch-nvidia"
        rm -rf "${NVIDIA_DIR}"
        mkdir -p "${NVIDIA_DIR}/usr/lib/modules/${KERNEL_VERSION}/kernel/extra"

        # Keep nouveau from grabbing the GPU before the proprietary module probes it.
        if [ "$_blacklist_nouveau" = "yes" ]; then
            print_info "Shipping nouveau blacklist in NVIDIA package"
            install_nouveau_blacklist "${NVIDIA_DIR}"
        fi
        # No CUDA PATH profile in the Arch package: Arch ships CUDA under /opt/cuda,
        # so /usr/local/cuda would be wrong. The deb gets the profile instead.

        # Copy NVIDIA .ko.zst modules (already compressed in staging)
        find "${MODULES_BASE_DIR}/${KERNEL_VERSION}/kernel/extra" -name "nvidia*.ko.zst" -exec cp {} "${NVIDIA_DIR}/usr/lib/modules/${KERNEL_VERSION}/kernel/extra/" \;

        # NVIDIA LICENSE: custom license text ships in the package's license dir
        install_nvidia_license "${NVIDIA_DIR}/usr/share/licenses/linux-cachyos-${_cpusched}-nvidia/LICENSE"

        # .PKGINFO
        NVIDIA_PKGVER="${pkgver}-${pkgrel}"
        NVIDIA_FILENAME="linux-cachyos-${_cpusched}-nvidia-${NVIDIA_PKGVER}-x86_64.pkg.tar.zst"

        NVIDIA_SIZE=$(find "${NVIDIA_DIR}" -mindepth 1 -maxdepth 1 \
            ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' \
            -exec du -sb {} + | awk '{sum+=$1} END {print sum+0}')

        cat > "${NVIDIA_DIR}/.PKGINFO" << EOF
pkgname = linux-cachyos-${_cpusched}-nvidia
pkgbase = linux-cachyos-${_cpusched}
pkgver = ${NVIDIA_PKGVER}
pkgdesc = NVIDIA proprietary modules for Linux ${KERNEL_VERSION} CachyOS kernel
url = https://github.com/CachyOS/linux-cachyos
builddate = ${SOURCE_DATE_EPOCH}
packager = Build-CachyOS-Kernel-On-Ubuntu
size = ${NVIDIA_SIZE}
arch = x86_64
license = custom
depend = linux-cachyos-${_cpusched}=${NVIDIA_PKGVER}
depend = nvidia-580xx-utils=${_nv_ver}
depend = libglvnd
provides = NVIDIA-MODULE
conflicts = linux-cachyos-${_cpusched}-nvidia-open
xdata = pkgtype=pkg
EOF

        cat > "${NVIDIA_DIR}/.BUILDINFO" << EOF
format = 2
pkgname = linux-cachyos-${_cpusched}-nvidia
pkgbase = linux-cachyos-${_cpusched}
pkgver = ${NVIDIA_PKGVER}
pkgarch = x86_64
packager = Build-CachyOS-Kernel-On-Ubuntu
builddate = ${SOURCE_DATE_EPOCH}
EOF

        # .INSTALL script
        cat > "${NVIDIA_DIR}/.INSTALL" << EOF
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

        # Normalize mtimes, then generate .MTREE (gzip -n omits the timestamp)
        cd "${NVIDIA_DIR}"
        find . -mindepth 1 -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
        find . -mindepth 1 ! -name '.MTREE' ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.INSTALL' -print0 | \
            bsdtar -cf - --format=mtree --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' --null -T - | gzip -n > .MTREE
        touch -h -d "@${SOURCE_DATE_EPOCH}" .MTREE
        cd - >/dev/null

        # Build package using tar | zstd pipeline
        cd "${NVIDIA_DIR}"
        {
            printf '%s\0' .PKGINFO .MTREE .BUILDINFO .INSTALL
            find . -mindepth 1 -maxdepth 1 -type d -printf '%P\0' | sort -z
            find . -mindepth 1 -maxdepth 1 -type f ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name '.INSTALL' -printf '%P\0' | sort -z
        } | bsdtar --null -T - -cf - | zstd -19 -T0 -f -o "${BUILD_DIR}/${NVIDIA_FILENAME}"
        cd - >/dev/null

        # Validation
        validate_arch_pkg "${BUILD_DIR}/${NVIDIA_FILENAME}" "${NVIDIA_DIR}" "Arch NVIDIA package"
        print_success "Arch NVIDIA package: ${BUILD_DIR}/${NVIDIA_FILENAME}"
    fi

    # Headers tree (always built; upstream ships the headers split unconditionally)
    mkdir -p "${ARCH_HDR}/usr/src" "${ARCH_HDR}/usr/lib/modules/${KERNEL_VERSION}"
    cp -a "${INSTALL_DIR}/usr/src/linux-headers-${KERNEL_VERSION}" "${ARCH_HDR}/usr/src/"
    ln -srf "${ARCH_HDR}/usr/src/linux-headers-${KERNEL_VERSION}" "${ARCH_HDR}/usr/lib/modules/${KERNEL_VERSION}/build"

    PKG_HDR_FILENAME="linux-cachyos-${_cpusched}-headers-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"

    # Calculate size for headers .PKGINFO (exclude metadata files)
    cd "${ARCH_HDR}"
    HDR_PKG_SIZE=$(find . -mindepth 1 -maxdepth 1 ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' -print0 | \
        xargs -0 du -sb 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    cd - >/dev/null

    cat > "${ARCH_HDR}/.PKGINFO" << EOF
pkgname = linux-cachyos-${_cpusched}-headers
pkgbase = linux-cachyos-${_cpusched}
pkgver = ${PACMAN_PKGVER}
pkgdesc = Headers for ${DESC}
url = https://github.com/CachyOS/linux-cachyos
builddate = ${SOURCE_DATE_EPOCH}
packager = Build-CachyOS-Kernel-On-Ubuntu
size = ${HDR_PKG_SIZE}
arch = x86_64
license = GPL-2.0-only
depend = binutils
depend = glibc
depend = libelf
depend = libgcc
depend = openssl
depend = pahole
depend = xxhash
depend = zlib
depend = zstd
depend = linux-cachyos-${_cpusched}=${PACMAN_PKGVER}
provides = LINUX-HEADERS
xdata = pkgtype=pkg
EOF

    cat > "${ARCH_HDR}/.BUILDINFO" << EOF
format = 2
pkgname = linux-cachyos-${_cpusched}-headers
pkgbase = linux-cachyos-${_cpusched}
pkgver = ${PACMAN_PKGVER}
pkgarch = x86_64
packager = Build-CachyOS-Kernel-On-Ubuntu
builddate = ${SOURCE_DATE_EPOCH}
EOF

    # Normalize mtimes, then generate .MTREE (gzip -n omits the timestamp)
    cd "${ARCH_HDR}"
    find . -mindepth 1 -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
    find . -mindepth 1 ! -name '.MTREE' ! -name '.PKGINFO' ! -name '.BUILDINFO' -print0 | \
        bsdtar -cf - --format=mtree --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' --null -T - | gzip -n > .MTREE
    touch -h -d "@${SOURCE_DATE_EPOCH}" .MTREE
    cd - >/dev/null

    # Create package using tar | zstd pipeline (replaces unsupported bsdtar --zstd flags)
    # Order: .PKGINFO first, then .MTREE, .BUILDINFO, then directories/files
    # Root ownership is handled by fakeroot wrapper
    cd "${ARCH_HDR}"
    {
        printf '%s\0' .PKGINFO .MTREE .BUILDINFO
        find . -mindepth 1 -maxdepth 1 -type d -printf '%P\0' | sort -z
        find . -mindepth 1 -maxdepth 1 -type f ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' -printf '%P\0' | sort -z
    } | tar --null -T - -cf - | zstd -19 -T0 -f -o "${BUILD_DIR}/${PKG_HDR_FILENAME}"
    cd - >/dev/null

    # Final Validation Step for headers
    validate_arch_pkg "${BUILD_DIR}/${PKG_HDR_FILENAME}" "${ARCH_HDR}" "Arch headers package"
    print_success "Arch headers: ${BUILD_DIR}/${PKG_HDR_FILENAME}"
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
        # Remove build symlink owned by headers package, not image package
        rm -f "${DEB_IMG}/usr/lib/modules/${KERNEL_VERSION}/build"
    else
        MODULES_PATH="lib/modules"
        mkdir -p "${DEB_IMG}/lib/modules"
        cp -a "${INSTALL_DIR}/lib/modules/${KERNEL_VERSION}" "${DEB_IMG}/lib/modules/"
        # Remove build symlink owned by headers package, not image package
        rm -f "${DEB_IMG}/lib/modules/${KERNEL_VERSION}/build"
    fi
    # NVIDIA modules are owned solely by the split NVIDIA package.
    # Keeping them here too causes dpkg "trying to overwrite" errors.
    find "${DEB_IMG}/${MODULES_PATH}/${KERNEL_VERSION}/kernel/extra" -type f -name 'nvidia*.ko.zst' -delete 2>/dev/null || true
    
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

    # --- NVIDIA PACKAGE ---
    if [ "$_build_nvidia" = "yes" ]; then
        print_info "Building NVIDIA Debian package..."

        DEB_NV_PKG="linux-modules-nvidia-${KERNEL_VERSION}"
        DEB_NV="${BUILD_DIR}/pkg-deb-nvidia"
        rm -rf "${DEB_NV}"
        mkdir -p "${DEB_NV}/DEBIAN" "${DEB_NV}/usr/lib/modules/${KERNEL_VERSION}/kernel/extra"
        mkdir -p "${DEB_NV}/usr/share/doc/${DEB_NV_PKG}"

        # Keep nouveau from grabbing the GPU before the proprietary module probes it.
        if [ "$_blacklist_nouveau" = "yes" ]; then
            print_info "Shipping nouveau blacklist in NVIDIA package"
            install_nouveau_blacklist "${DEB_NV}"
        fi

        # Copy NVIDIA modules (already zstd-compressed from staging)
        find "${MODULES_BASE_DIR}/${KERNEL_VERSION}/kernel/extra" -name "nvidia*.ko.zst" -exec cp {} "${DEB_NV}/usr/lib/modules/${KERNEL_VERSION}/kernel/extra/" \;

        # Copy MODULE.symvers
        cp "${SRC_DIR}/${_srcname}/Module.symvers" "${DEB_NV}/usr/lib/modules/${KERNEL_VERSION}/" 2>/dev/null || true

        # Debian copyright must live in the binary package's own doc directory
        install_nvidia_license "${DEB_NV}/usr/share/doc/${DEB_NV_PKG}/copyright"

        # Bundle the matching user-space so a single install gives working CUDA.
        if [ "$_nv_userspace" = "yes" ]; then
            print_info "Bundling NVIDIA ${_nv_ver} user-space into the NVIDIA package"
            install_nvidia_userspace "${DEB_NV}" "${DOWNLOAD_DIR}/${_nv_pkg}" "${_nv_ver}"
        fi
        if [ "$_cuda_setup" = "yes" ]; then
            print_info "Adding CUDA ${_cuda_ver} environment profile"
            install_cuda_profile "${DEB_NV}"
        fi

        # Control fields depend on whether the matching user-space is bundled
        NV_DEPENDS="Depends: ${DEB_IMG_PKG} (= ${DEB_VERSION})"
        NV_RECOMMENDS_LIST=""
        NV_EXTRA=""
        NV_DESC="NVIDIA proprietary kernel modules for ${DESC}"
        NV_DESC_LONG=" Contains the NVIDIA kernel modules (nvidia, nvidia-modeset, nvidia-drm, nvidia-uvm)
 built for the ${KERNEL_VERSION} CachyOS kernel."
        if [ "$_nv_userspace" = "yes" ]; then
            NV_DEPENDS="${NV_DEPENDS}, libc6 (>= 2.34), libgcc-s1, libssl3t64, libtirpc3t64, adduser, ocl-icd-libopencl1"
            NV_EXTRA="Provides: libcuda.so.1, libnvidia-ml.so.1, libnvidia-cfg1, libnvidia-gpucomp, nvidia-opencl-icd, opencl-icd, nvidia-modprobe, nvidia-persistenced
Conflicts: nvidia-driver-580, nvidia-dkms-580, nvidia-utils-580, nvidia-compute-utils-580, libnvidia-extra-580, libnvidia-compute-580, libnvidia-gl-580, libnvidia-cfg1-580, libnvidia-decode-580, libnvidia-encode-580, libnvidia-fbc1-580, nvidia-modprobe, xserver-xorg-video-nvidia-580
Replaces: nvidia-modprobe"
            NV_DESC="NVIDIA proprietary kernel modules and user-space for ${DESC}"
            NV_DESC_LONG=" Contains the NVIDIA kernel modules (nvidia, nvidia-modeset, nvidia-drm, nvidia-uvm)
 built for the ${KERNEL_VERSION} CachyOS kernel, plus the matching ${_nv_ver}
 user-space (libcuda, NVML, nvidia-smi, nvidia-modprobe, firmware) so CUDA works
 after installing this package."
        else
            # Modules-only package needs the distro's user-space for X/Wayland.
            NV_RECOMMENDS_LIST="nvidia-driver"
        fi
        if [ "$_cuda_setup" = "yes" ]; then
            case "$_cuda_toolkit_dep" in
                depends)    NV_DEPENDS="${NV_DEPENDS}, ${_cuda_meta}" ;;
                recommends) NV_RECOMMENDS_LIST="${NV_RECOMMENDS_LIST:+${NV_RECOMMENDS_LIST}, }${_cuda_meta}" ;;
            esac
        fi

        # DEBIAN/control
        {
        cat << EOF
Package: ${DEB_NV_PKG}
Version: ${DEB_VERSION}
Section: kernel
Priority: optional
Maintainer: GitHub User <github@example.com>
Architecture: amd64
${NV_DEPENDS}
EOF
        [ -n "$NV_RECOMMENDS_LIST" ] && printf 'Recommends: %s\n' "$NV_RECOMMENDS_LIST"
        [ -n "$NV_EXTRA" ] && printf '%s\n' "$NV_EXTRA"
        cat << EOF
Description: ${NV_DESC}
${NV_DESC_LONG}
EOF
        } > "${DEB_NV}/DEBIAN/control"

        # DEBIAN/postinst
        cat > "${DEB_NV}/DEBIAN/postinst" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'

if [ "\$1" = configure ]; then
    moddir="/usr/lib/modules/\$version"
    if [ -d "\$moddir" ]; then
        depmod "\$version" || true
    fi
    ldconfig || true
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger 2>/dev/null || true
    fi
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "\$version" 2>/dev/null || update-initramfs -c -k "\$version" 2>/dev/null || true
    fi
fi
exit 0
EOF
        chmod +x "${DEB_NV}/DEBIAN/postinst"

        # DEBIAN/prerm
        cat > "${DEB_NV}/DEBIAN/prerm" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'

if [ "\$1" = remove ] || [ "\$1" = purge ]; then
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "\$version" 2>/dev/null || true
    fi
fi
exit 0
EOF
        chmod +x "${DEB_NV}/DEBIAN/prerm"

        # DEBIAN/postrm
        cat > "${DEB_NV}/DEBIAN/postrm" << EOF
#!/bin/sh
set -e
version='${KERNEL_VERSION}'

if [ "\$1" = remove ] || [ "\$1" = purge ]; then
    ldconfig || true
fi
if [ "\$1" = purge ]; then
    rm -rf "/usr/lib/modules/\$version/kernel/extra/nvidia"* 2>/dev/null || true
fi
exit 0
EOF
        chmod +x "${DEB_NV}/DEBIAN/postrm"

        # Build
        DEB_NV_FILE="${BUILD_DIR}/${DEB_NV_PKG}_${DEB_VERSION}_amd64.deb"
        dpkg-deb --root-owner-group -b "${DEB_NV}" "${DEB_NV_FILE}"
        print_success "Debian NVIDIA package: ${DEB_NV_FILE}"
    fi

    # --- HEADERS PACKAGE ---
    # Headers are always built (upstream ships the headers split unconditionally).
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

# ======================== SUMMARY ========================
print_step "Step 11: Verification & Summary"
print_warning "The kernel has been built successfully!"

# One-command installer for everything this build produced (including fetched CUDA debs).
INSTALLER="${BUILD_DIR}/install-debs.sh"
cat > "$INSTALLER" << 'INSTALLER_EOF'
#!/bin/bash
# Install the packages built by pkgbuild.sh, stage by stage.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

install_stage() {
    local label="$1"; shift
    local files=() f
    for f in "$@"; do
        if [ -f "$f" ]; then files+=("$f"); fi
    done
    [ "${#files[@]}" -gt 0 ] || return 0
    printf '\n==> %s\n' "$label"
    printf '    %s\n' "${files[@]}"
    apt-get install -y "${files[@]}"
}

install_stage "Kernel image"   linux-image-*_*.deb
install_stage "Kernel headers" linux-headers-*_*.deb
install_stage "NVIDIA modules" linux-modules-nvidia-*_*.deb
install_stage "CUDA toolkit"   downloads/cuda-*/*.deb

printf '\nAll packages installed.\n'
INSTALLER_EOF
chmod 755 "$INSTALLER"

echo "=========================================="
if [[ "$_build_archpkg" == "yes" ]]; then
    PACMAN_PKGVER="${pkgver}-${pkgrel}"
    echo " Arch Image:   sudo pacman -U ${BUILD_DIR}/linux-cachyos-${_cpusched}-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"
    echo " Arch Headers: sudo pacman -U ${BUILD_DIR}/linux-cachyos-${_cpusched}-headers-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"
    [[ "$_build_nvidia" == "yes" ]] && echo " Arch NVIDIA:  sudo pacman -U ${BUILD_DIR}/linux-cachyos-${_cpusched}-nvidia-${PACMAN_PKGVER}-x86_64.pkg.tar.zst"
fi
if [[ "$_build_deb" == "yes" ]]; then
    echo " Debian all:   sudo ${BUILD_DIR}/install-debs.sh"
fi
echo "=========================================="
if [ "$_build_nvidia" = "yes" ]; then
    print_warning "NVIDIA builds need BOTH packages: install the image package first, then the NVIDIA package."
    print_info "The NVIDIA package owns the nvidia*.ko modules, the nouveau blacklist and the matching user-space; the image stays generic."
    [ "$_nv_userspace" = "yes" ] && print_info "After installing it, verify with: nvidia-smi"
    if [ "$_cuda_setup" = "yes" ]; then
        if dpkg-query -W -f='${Status}' "$_cuda_meta" 2>/dev/null | grep -q 'install ok installed'; then
            print_info "CUDA ${_cuda_ver/-/.}: toolkit installed; /etc/profile.d/cachyos-cuda.sh puts nvcc on PATH."
        elif [ -f "${DOWNLOAD_DIR}/cuda-${_cuda_ver/-/.}/.complete" ]; then
            print_info "CUDA ${_cuda_ver/-/.}: verified packages in ${DOWNLOAD_DIR}/cuda-${_cuda_ver/-/.}"
            print_info "Install all build packages with: sudo ${INSTALLER}"
        else
            print_info "CUDA ${_cuda_ver/-/.}: profile ships with the NVIDIA deb; the packages were not downloaded."
            read -p "Download ${_cuda_meta} now? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                _cuda_download=yes
                fetch_cuda_packages
            fi
        fi
        print_warning "Pascal needs CUDA 12.9 - do NOT install Ubuntu's nvidia-cuda-toolkit."
    fi
fi
if [ "$USR_MERGED" = true ]; then
    print_success "Your system uses usr-merged filesystem layout"
    print_info "Modules will be installed to /usr/lib/modules/ (accessed via /lib/modules symlink)"
else
    print_warning "Your system uses traditional filesystem layout"
    print_info "Modules will be installed to /lib/modules/"
fi
echo
print_info "The Debian package postinst runs depmod, update-initramfs and update-grub automatically."
echo
print_info "Build directory preserved at: ${BUILD_DIR}"
print_info "Config saved at: ${BUILD_DIR}/config-${KERNEL_VERSION}"
print_info "To clean up: rm -rf ${BUILD_DIR}/src"
print_success "Build process completed successfully!"
