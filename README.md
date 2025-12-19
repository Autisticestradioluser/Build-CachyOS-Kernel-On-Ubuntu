# Linux Kernel Builder for Ubuntu with CachyOS Patches (Work in Progress)

> ⚠️ **WARNING**: This is an experimental script under active development. It may contain bugs, incomplete functionality, or unstable behavior. Use at your own risk. ONLY REPORT ISSUES TO THIS REPOSITORY.

---

## 🛠️ Overview

This script automates the process of building the Linux kernel on Ubuntu Noble (24.04 LTS), applying patches from **CachyOS**, and generating both:

- A `.deb` package for Debian and Ubuntu-based systems.
- An *incomplete* Arch Linux package (work in progress).

The goal is to create a streamlined, reproducible kernel build pipeline tailored for Debian and Ubuntu users that may also have an Arch PC or dual boot but just want to compile the kernel once.
> Note that if you use `_processor_opt=${_processor_opt:-native}` you will need to be sure that both CPUs are the same in clang which may make it more suitable for a dual boot configuration

---

## 📦 What You Get

✅ `.deb` package compatible with Ubuntu Noble also tested on Debian Trixie and Testing (Forky)  
⚠️ Arch package — currently incomplete; will not install correctly  
🔧 CachyOS patches applied  
🔄 Automated build workflow using standard tools (`make`, `fakeroot`, `dpkg-deb`, etc.)  

---

## 🔗 Upstream Sources

This script uses patches and code inspirations from the following upstream repositories:

- [CachyOS Linux Kernel Configuration and PKGBUILD](https://github.com/CachyOS/linux-cachyos)
- [CachyOS Kernel Patches](https://github.com/CachyOS/kernel-patches)

These patches are applied to the official Linux kernel source code to optimize performance.

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

- **Ubuntu Noble (24.04 LTS)** 
- Handling **modern merged-usr filesystem layout**
- Users who may need to build kernels for both Debian/Ubuntu and Arch Linux systems (though Arch support is currently incomplete)

---

## ⚙️ Key Features

- **Modern Ubuntu Support**: Handles merged-usr filesystem structure with `/lib -> /usr/lib` symlink
- **Configurable Build Options**: Customize scheduler, optimization, kernel modules, and more
- **NVIDIA Driver Integration**: Build with NVIDIA Proprietary 580 series drivers or open drivers for Turing+
- **Arch Linux Support**: Generate mkinitcpio presets (though installation is incomplete, only makes a corrupted package due to no metedata for the package manager yet)

---

## 📌 Usage Notes

### Before You Begin

1. **Verify system requirements**: Make sure you have the latest clang-21 from LLVM, fakeroot, and dpkg-dev if you want to build it into a .deb package. Minimum of 8 GB RAM with zstd compressed zram for full LTO build.

2. **Manual verification**: It's recommended to verify integrity of downloaded components using b2sums (the script does this automatically for most files, but you may want to verify the source files manually before proceeding)

3. **NVIDIA Notes**: The script uses NVIDIA driver series 580 (legacy drivers for Maxwell-Pascal architectures). For Turing+ GPUs, the NVIDIA open driver is available and often a better choice.

### Critical Warnings

> ⚠️ **This script is experimental and may cause system instability if used incorrectly**
> 
> - The NVIDIA driver integration may conflict with existing NVIDIA installations
> - The Arch Linux package is **not fully functional** and should only be used for manual installation experiments
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
- Arch Linux package (incomplete) at: `./linux-cachyos-<configuration>-<version>-x86_64.pkg.tar.zst`
- Configuration files at: `./config-<kernel-version>`

> **Important**: The Arch package is experimental and likely requires manual adjustments to work. The Debian package is the only supported output.
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

Remember: Ubuntu Noble uses usr-merged filesystem - modules are in `/usr/lib/modules/` (accessed via `/lib/modules` symlink)
