# Linux Kernel Builder for Ubuntu Noble with CachyOS Patches

A deterministic, single-run build script that compiles the Linux kernel with CachyOS patches and outputs **fully installable packages for both Debian/Ubuntu and Arch Linux**.

## 🎯 Scope & Behavior
- **Host OS:** Ubuntu Noble 24.04 LTS (optimized & validated)
- **Architecture:** `x86_64` / `amd64`
- **Filesystem:** Fully supports merged-usr (`/lib -> /usr/lib`) and traditional layouts
- **Output:** Split `linux-image` + `linux-headers` packages for both `.deb` and `.pkg.tar.zst` formats
- **Execution:** Runs once, stages artifacts, packages both formats simultaneously, exits cleanly

## ✅ Verified Features
| Feature | Status | Implementation |
|---------|--------|----------------|
| CachyOS patch integration | ✅ Active | Downloads & applies scheduler, RT, hardened, and DKMS-clang patches from upstream |
| Dual package output | ✅ Active | Generates `.deb` and `.pkg.tar.zst` in one build run |
| Split image/headers | ✅ Active | Controlled by `_build_debug=yes`. Headers packaged separately with correct `/lib/modules/$ver/build` symlinks |
| Pacman compliance | ✅ Active | `.PKGINFO`, `.BUILDINFO`, `.MTREE`, sanitized `pkgver` (dots in version, hyphen before pkgrel) |
| Debian policy compliance | ✅ Active | `postinst`/`prerm`/`postrm` follow kernel packaging standards; safe `initramfs`/GRUB handling |
| Source integrity verification | ✅ Active | `b2sum` validation for kernel tarball and base config before extraction |
| Module signing | ✅ Conditional | Runs automatically if `CONFIG_MODULE_SIG=y` is present in the kernel config |
| Fakeroot handling | ✅ Active | Auto-detects, fixes permissions, and restarts under `fakeroot` if needed |
| r8125 driver integration | ✅ Active | Builds, packages, and auto-blacklists `r8169` via maintainer scripts |
| ZFS module support | ✅ Conditional | Builds when `_build_zfs=yes`. Incompatible with `rt`/`rt-bore` schedulers (enforced by script) |

## 📦 Package Output & Installation
Packages are placed in the build directory after successful compilation.

| Format | Package | Filename Pattern | Install Command |
|--------|---------|------------------|-----------------|
| **Arch Image** | `linux-cachyos-<sched>` | `linux-cachyos-<sched>-<ver>.<ver>.<ver>-<pkgrel>-x86_64.pkg.tar.zst` | `sudo pacman -U linux-cachyos-*.pkg.tar.zst` |
| **Arch Headers** | `linux-cachyos-<sched>-headers` | `linux-cachyos-<sched>-headers-<ver>.<ver>.<ver>-<pkgrel>-x86_64.pkg.tar.zst` | `sudo pacman -U linux-cachyos-*-headers-*.pkg.tar.zst` |
| **Debian Image** | `linux-image-cachyos-<sched>` | `linux-image-cachyos-<sched>_<ver>-<pkgrel>_amd64.deb` | `sudo dpkg -i linux-image-cachyos-*.deb` |
| **Debian Headers** | `linux-headers-cachyos-<sched>` | `linux-headers-cachyos-<sched>_<ver>-<pkgrel>_amd64.deb` | `sudo dpkg -i linux-headers-cachyos-*.deb` |

⚠️ Headers are only built and packaged when `_build_debug=yes`.

## ⚙️ Configuration
All options use the `_` prefix and can be overridden at runtime via environment variables without editing the script.

**Syntax:** `_var=value ./pkgbuild.sh`

| Variable | Default | Description |
|----------|---------|-------------|
| `_cpusched` | `bore` | Scheduler: `bore`, `bmq`, `hardened`, `cachyos`, `eevdf`, `rt`, `rt-bore` |
| `_use_llvm_lto` | `full` | LTO mode: `none`, `thin`, `full`, `thin-dist` |
| `_processor_opt` | `native` | CPU target: `native`, `zen4`, `generic_v1`-`v4` |
| `_build_archpkg` | `yes` | Build Arch `.pkg.tar.zst` + mkinitcpio preset |
| `_build_deb` | `yes` | Build Debian `.deb` package |
| `_build_debug` | `no` | Build & package kernel headers |
| `_build_zfs` | `no` | Build in-tree ZFS module (incompatible with `rt`/`rt-bore`) |
| `_build_r8125` | `yes` | Build & package r8125 driver (auto-blacklists r8169) |
| `_HZ_ticks` | `1000` | Timer frequency: `100`, `250`, `300`, `500`, `600`, `750`, `1000` |
| `_preempt` | `full` | Preemption: `full`, `lazy`, `voluntary`, `none` |
| `_hugepage` | `always` | THP policy: `always`, `madvise` |
| `_cc_harder` | `yes` | Enable `-O3` compiler optimization |
| `_tcp_bbr3` | `yes` | Enable BBRv3 TCP congestion control |
| `_tickrate` | `full` | Tick type: `periodic`, `idle`, `full` |

📖 See the top of `pkgbuild.sh` for the complete variable list and inline documentation.

## 🛠️ Requirements & Setup
### System
- Ubuntu Noble 24.04 LTS (other releases may work but are unvalidated)
- `x86_64` CPU
- ≥8 GB RAM recommended for `full` LTO builds (use `zram-generator` with `zstd` compression if needed)

### Dependencies
The script auto-checks and prompts for missing packages. Core requirements:
```bash
build-essential libncurses-dev libelf-dev libssl-dev flex bison cpio gettext \
python3 perl zstd wget curl git pkg-config kmod fakeroot dwarves bc dpkg-dev libarchive-tools
```
- LLVM/Clang 21 packages are required when `_use_llvm_lto!=none`
- `rustc`, `rust-src`, `bindgen` are required for non-RT schedulers
- `fakeroot` is mandatory for safe module installation and packaging

### Execution
```bash
chmod +x pkgbuild.sh
./pkgbuild.sh
```
The script will:
1. Validate OS, usr-merge status, and dependencies
2. Restart under `fakeroot` if needed
3. Download, verify (`b2sum`), extract, patch, and configure sources
4. Compile kernel, modules, and optional extras (ZFS/r8125)
5. Stage artifacts, fix permissions, and generate both package formats
6. Exit with exact installation commands

## 🔐 Integrity & Security
| Component | Verification Status | Notes |
|-----------|---------------------|-------|
| Kernel tarball | ✅ `b2sum` verified | Checked before extraction |
| Base config | ✅ `b2sum` verified | Checked before configuration |
| Patches | ⚠️ Downloaded, not checksummed | Fetched from upstream CachyOS patch repository |
| Generated packages | ❌ Not signed/checksummed | Manual verification recommended for production deployment |
| Kernel modules | ✅ Conditionally signed | Auto-signed if `CONFIG_MODULE_SIG=y` is enabled |
| Maintainer scripts | ✅ Policy-compliant | Safe `initramfs`, `depmod`, `grub`, and symlink handling |

## 🐛 Reporting Issues
Please report all bugs to:  
👉 https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues

**Do not file issues with CachyOS or upstream Linux kernel repositories.** This script is an independent community project.

When reporting, include:
- Exact distro & release (`lsb_release -a`)
- Full command & environment overrides used
- Complete terminal output or error logs
- `uname -a` before building
- Expected vs actual behavior

## 📜 Upstream Sources & Credits
This script integrates patches, configuration baselines, and packaging conventions from:
- [CachyOS Linux Kernel](https://github.com/CachyOS/linux-cachyos)
- [CachyOS Kernel Patches](https://github.com/cachyos/kernel-patches)
- Arch Linux `linux` PKGBUILD packaging standards
- Debian `linux-image` maintainer script policies

All upstream code remains under its original licenses. This script is provided as-is for educational and personal use.

## ⚠️ Disclaimer
This script compiles and installs a custom Linux kernel. Improper use may result in an unbootable system. Always:
- Keep a known-working kernel installed
- Verify source integrity before building
- Test new kernels in a non-critical environment first
- Back up important data before installation

**Use at your own risk. No warranty is provided.**
