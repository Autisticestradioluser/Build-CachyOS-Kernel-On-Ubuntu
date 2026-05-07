# Linux Kernel Builder for Ubuntu with CachyOS Patches

⚠️ **WARNING:** This is a custom, experimental build script. It automates advanced kernel compilation and packaging. Use at your own risk. **ONLY report issues to this repository.**

## 🛠️ Overview
This script automates the process of building the Linux kernel on **Ubuntu Noble (24.04 LTS)**, applying performance patches from CachyOS, and generating **fully installable packages for both Debian/Ubuntu and Arch Linux** from a single build run.

It is designed for users who want CachyOS-level kernel optimizations on Debian-based systems, or who maintain dual-boot/multi-distro setups and want to compile once and deploy everywhere.

## 📦 What You Get
✅ **Debian/Ubuntu `.deb` packages** (`linux-image` + optional `linux-headers`)  
✅ **Arch Linux `.pkg.tar.zst` packages** (`linux-cachyos-*` + optional `-headers`)  
✅ **Proper package manager compatibility** (`dpkg -i` and `pacman -U` ready)  
✅ **CachyOS patches & optimizations** applied automatically  
✅ **Dynamic package descriptions** reflecting your exact build flags  
✅ **Automated `initramfs`, `depmod`, and GRUB updates** via maintainer scripts  
✅ **Usr-merge aware** staging and packaging (handles `/lib -> /usr/lib` seamlessly)

## 🎯 Target Environment
- **Host OS:** Ubuntu Noble 24.04 LTS (optimized & validated)
- **Architecture:** `x86_64` / `amd64`
- **Filesystem:** Fully supports modern merged-usr (`/lib -> /usr/lib`) and traditional layouts
- **Toolchain:** GCC or Clang/LLVM (LTO supported), `fakeroot`, `dpkg-deb`, `bsdtar`

## ⚙️ Key Features
- **Dual Package Output:** Generates both `.deb` and `.pkg.tar.zst` in one run
- **Split Packages:** Kernel/image and headers are packaged separately (controlled by `_build_debug`)
- **Full Configurability:** Every build option can be overridden via environment variables without editing the script
- **Pacman-Compliant Arch Packages:** Proper `.PKGINFO`, `.BUILDINFO`, `.MTREE`, sanitized `pkgver`, and `mkinitcpio` preset included
- **Debian-Policy Compliant:** Robust `postinst`/`prerm`/`postrm` scripts, safe `initramfs`/GRUB handling, and `linux-update-symlinks` integration
- **Automatic Fakeroot Handling:** Restarts under `fakeroot` safely if needed, with permission normalization
- **Source Integrity Verification:** `b2sum` validation for kernel tarball, config, and patches before build begins

## 📦 Package Output & Installation
After a successful build, packages are placed in the build directory:

| Package Type | Filename Pattern | Install Command |
|--------------|------------------|-----------------|
| **Arch Image** | `linux-cachyos-<sched>-<ver>.<ver>.<ver>-<pkgrel>-x86_64.pkg.tar.zst` | `sudo pacman -U linux-cachyos-*.pkg.tar.zst` |
| **Arch Headers** | `linux-cachyos-<sched>-headers-<ver>.<ver>.<ver>-<pkgrel>-x86_64.pkg.tar.zst` | `sudo pacman -U linux-cachyos-*-headers-*.pkg.tar.zst` |
| **Debian Image** | `linux-image-cachyos-<sched>_<ver>-<pkgrel>_amd64.deb` | `sudo dpkg -i linux-image-cachyos-*.deb` |
| **Debian Headers** | `linux-headers-cachyos-<sched>_<ver>-<pkgrel>_amd64.deb` | `sudo dpkg -i linux-headers-cachyos-*.deb` |

💡 **Headers are only built & packaged if `_build_debug=yes`**

## 🛠️ Usage & Configuration
### Basic Run
```bash
chmod +x NobleKernelBuild-stable.sh
./NobleKernelBuild-stable.sh
```

### Environment Variable Overrides
All configuration options use the `_` prefix and can be overridden at runtime without editing the script:
```bash
_cpusched=rt _use_llvm_lto=none _build_deb=no _build_archpkg=yes ./NobleKernelBuild-stable.sh
```

### Key Configuration Variables
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

📖 See the top of the script for the complete list of configurable options.

## 🔐 Security & Integrity
- ✅ **Source Verification:** Kernel tarball, base config, and patches are verified via `b2sum` before extraction
- ⚠️ **Package Checksums:** Generated `.deb` and `.pkg.tar.zst` files do not include embedded checksums. Manual verification is recommended for production deployments
- 🔒 **Module Signing:** Automatically signs external modules (ZFS/r8125) if `CONFIG_MODULE_SIG=y` is enabled in the kernel config
- 🛡️ **Safe Maintainer Scripts:** Debian `postinst`/`prerm`/`postrm` follow official kernel packaging policy and gracefully handle upgrades, removals, and purges

## 🐛 Reporting Issues
Please report all bugs to:  
👉 https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues

**Do not file issues with CachyOS or upstream Linux kernel repositories.** This script is an independent community project and is not supported by upstream maintainers.

When reporting, please include:
- Exact distro & release (`lsb_release -a`)
- The exact command/environment variables used
- Full terminal output or error logs
- `uname -a` before building
- A clear description of expected vs actual behavior

## 📜 Upstream Sources & Credits
This script integrates patches, configuration baselines, and packaging inspirations from:
- [CachyOS Linux Kernel](https://github.com/CachyOS/linux-cachyos)
- [CachyOS Kernel Patches](https://github.com/CachyOS/kernel-patches)
- Arch Linux `linux` PKGBUILD packaging conventions
- Debian `linux-image` maintainer script policies

All upstream code remains under its original licenses. This script is provided as-is for educational and personal use.

## ⚠️ Disclaimer
This script compiles and installs a custom Linux kernel. Improper use may result in an unbootable system. Always:
- Keep a known-working kernel installed
- Verify source integrity before building
- Test new kernels in a non-critical environment first
- Back up important data before installation

**Use at your own risk. No warranty is provided.**
