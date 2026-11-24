# Linux Kernel Builder for Ubuntu with CachyOS Patches (Work in Progress)

> ⚠️ **WARNING**: This is an experimental script under active development. It may contain bugs, incomplete functionality, or unstable behavior. Use at your own risk. ONLY REPORT ISSUES TO THIS REPOSITORY.

---

## 🛠️ Overview

This script automates the process of building the Linux kernel on Ubuntu Resolute (26.04 LTS), applying patches from **CachyOS**, and generating both:

- A `.deb` package for Debian and Ubuntu-based systems.
- A complete Arch Linux package (`.pkg.tar.zst`) with proper package metadata.

The goal is to create a streamlined kernel build pipeline tailored for Debian and Ubuntu users that may also have an Arch PC or dual boot but just want to compile the kernel once. Arch package metadata is reproducible when `SOURCE_DATE_EPOCH` is set (timestamps, mtimes and gzip headers are normalised).
> Note that if you use `_processor_opt=${_processor_opt:-native}` you will need to be sure that both CPUs are the same in clang which may make it more suitable for a dual boot configuration

---

## 📦 What You Get

✅ `.deb` package compatible with Ubuntu Resolute and Debian Forky
✅ Arch package — complete with `.PKGINFO`/`.MTREE` metadata
🔧 CachyOS patches applied  
🔄 Automated build workflow using standard tools (`make`, `fakeroot`, `dpkg-deb`, etc.)  

---

## 🔗 Upstream Sources

This script builds on work from:
- **[CachyOS Linux Kernel](https://github.com/CachyOS/linux-cachyos)** — GPLv3; provides PKGBUILD structure, build logic, and kernel configs
- **[CachyOS Kernel Patches](https://github.com/cachyos/kernel-patches)** — GPL; provides performance patches and scheduler variants
- **Arch Linux packaging standards** — provides `.pkg.tar.zst` packaging conventions and `mkinitcpio` preset format
- **Debian `linux-image` maintainer script policies** — provides `.deb` packaging conventions and maintainer scripts
- **Linux Kernel** — GPL-2.0-only; the kernel source itself

- [CachyOS Linux Kernel Configuration and PKGBUILD](https://github.com/CachyOS/linux-cachyos)
- [CachyOS Kernel Patches](https://github.com/CachyOS/kernel-patches)

These patches are applied to the official Linux kernel source code to optimize performance.

---

## License

This project is licensed under the **GNU General Public License v3.0 (GPLv3)**.

This script is a derivative work of the [CachyOS linux-cachyos PKGBUILDs](https://github.com/CachyOS/linux-cachyos), which are licensed under GPLv3. The kernel sources, patches, and configs it downloads and builds are primarily under GPL-2.0-only (with some components under CDDL, MIT, and other GPL-compatible licenses).

You are free to use, modify, and distribute this script under the terms of the GPLv3. No warranty is provided. See [LICENSE](LICENSE) for details.

All upstream code remains under its original licenses. The generated kernel packages inherit the licenses of their constituent components (kernel: GPL-2.0-only, ZFS: CDDL, NVIDIA: proprietary, etc.).

---

## 🧪 Current Status

🚧 **Work in Progress**  
⛔ **Bugs Expected** — These may stem from:
- Poor coding practices / missing edge cases
- LLM-generated code logic flaws
- Incompatibilities between patch layers and kernel versions
- Unhandled dependencies or build environment quirks

**✅ Source integrity checks**: The script now implements b2sum verification for source files (kernel, config, patches) as per CachyOS PKGBUILD standards. This verifies integrity of downloaded components before build begins.

**⚠️ Package integrity**: Package-side sum checks (for .deb and Arch packages) are **still not implemented**. The generated packages do not include integrity checks. You are responsible for verifying package integrity after build.

**⚠️ Security Note**: 
- The script **now verifies b2sums** for downloaded sources some patches
- It **does NOT verify package integrity** for generated .deb or Arch packages
- Manual verification of source integrity is recommended before proceeding with build
- For sensitive components like kernel sources and patches, the script verifies integrity (b2sum) before proceeding with the build

Please ONLY report bugs via [this repository's issue tracker](https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues)

---

## 💡 Why This Exists

CachyOS uses a highly optimized kernel configuration focused on performance. This script aims to:

- Replicate CachyOS's kernel build environment on Ubuntu.
- Allow easy kernel upgrades and customizations.

---

## 📐 Target Environment

This script is specifically designed for:

- **Ubuntu Resolute (26.04 LTS)** 
- Handling **modern merged-usr filesystem layout**
- Users who may need to build kernels for both Debian/Ubuntu and Arch Linux systems

---

## ⚙️ Key Features

- **Modern Ubuntu Support**: Handles merged-usr filesystem structure with `/lib -> /usr/lib` symlink
- **Configurable Build Options**: Customize scheduler, optimization, kernel modules, and more
- **NVIDIA Driver Integration**: Build with NVIDIA proprietary 580 series drivers (Maxwell/Pascal pin). The Debian NVIDIA package bundles the matching user-space and a CUDA profile; since Ubuntu 26.04's CUDA repo only ships 13.x, `_cuda_download=yes` fetches and verifies CUDA 12.9 (the last Pascal-capable toolkit) from NVIDIA's ubuntu2404 debs as local files for manual installation, without adding a foreign apt source
- **Arch Linux Support**: Generate mkinitcpio presets and a complete pacman package. The headers split is always built (upstream semantics); Arch packages carry validated `.PKGINFO`/`.MTREE`/`.BUILDINFO` metadata

---

## 📌 Usage Notes

### Before You Begin

1. **Verify system requirements**: Make sure you have the latest clang-22 from LLVM, fakeroot, and dpkg-dev if you want to build it into a .deb package. Minimum of 8 GB RAM with zstd compressed zram for full LTO build.

2. **Manual verification**: It's recommended to verify integrity of downloaded components using b2sums (the script does this automatically for most files, but you may want to verify the source files manually before proceeding)

3. **NVIDIA Notes**: The script uses NVIDIA driver series 580 (legacy drivers for Maxwell-Pascal architectures). The open-driver variant is not currently wired into this branch (tracked as a follow-up). With `_build_nvidia=yes` the Debian package bundles the matching user-space for the pinned series and ships a CUDA profile. CUDA options:
   - `_cuda_setup=yes` (default): ship the profile and declare the toolchain dependency.
   - `_cuda_meta` (default `cuda-minimal-build-12-9`): package set declared and fetched. The minimal build has nvcc, nvvm, cudart, CCCL and profiler headers (~81 MiB); `cuda-toolkit-12-9` adds docs, Nsight and visual tools (~3.7 GiB).
   - `_cuda_toolkit_dep=recommends` (default) | `depends` | `none`: how the Debian package declares it.
   - `_cuda_download=yes`: download NVIDIA's verified `.debs` from the ubuntu2404 index into the build directory. The final summary generates `install-debs.sh`, which installs the kernel, headers, NVIDIA modules and the downloaded CUDA packages in stages (`sudo <build-dir>/install-debs.sh`). Nothing is installed automatically and Resolute's apt sources are not modified. If the build finishes without this option, the final summary offers to download the packages then.

### Critical Warnings

> ⚠️ **This script is experimental and may cause system instability if used incorrectly**
> 
> - The NVIDIA driver integration may conflict with existing NVIDIA installations
> - The Arch Linux package is complete but untested on Arch systems
> - **Source integrity is verified but package integrity is not** - Verify packages manually after build

---

## 📬 Reporting Issues

**Please report all bugs to [https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues](https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues)**

Do not file issues in other repositories:
- Do not file issues with CachyOS (they do not support this script)
- Do not file issues with upstream Linux kernel (this script is not supported there either)

When reporting issues, please include:
1. Your exact distro release version (`lsb_release -a`)
2. The specific command you ran
3. Any error messages you encountered
4. The output of `uname -a` before building
5. A detailed description of your desired outcome

---

## 📦 Package Output

After successful build, you'll find:

- `.deb` package at: `./linux-cachyos-<configuration>-<version>-amd64.deb`
- Arch Linux package at: `./linux-cachyos-<configuration>-<version>-x86_64.pkg.tar.zst`
- Configuration files at: `./config-<kernel-version>`

> **Important**: The Arch package is metadata-complete and validated in-script (member order, `.MTREE` digests, size, scriptlets) but has not been install-tested on an Arch system. The Debian package is the primary supported output.
> **Security Note**: The generated packages do not include checksums. It is recommended to manually verify the package before installation.

> **Source integrity is verified**: The script now checks b2sums for downloaded sources and patches, but package integrity verification is not implemented.

---

## 📋 Additional Notes

### Security Considerations

- ✅ **Source verification**: All downloaded kernel sources, configuration files, and some patches are verified using b2sums before build begins
- ❌ **Package verification**: Generated .deb and Arch packages **do not** have checksums. Manual verification is required for package integrity
- 🔐 **Critical**: If you're building for production systems, always manually verify the integrity of both source files and final packages

---

## 📌 Final Recommendations

1. Always verify source integrity (b2sum) before starting the build
2. For production systems, manually verify package integrity after build
3. Keep your build environment clean and verified
4. The script is experimental - use at your own risk

Remember: Ubuntu Resolute uses usr-merged filesystem - modules are in `/usr/lib/modules/` (accessed via `/lib/modules` symlink)
