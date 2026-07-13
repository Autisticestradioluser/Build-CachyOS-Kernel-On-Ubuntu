---

# Custom Linux Kernel Builder for Ubuntu (LTS) - Arch + Debian Output
**This is the `noble-lts` branch, configured to build the CachyOS LTS kernel (6.18.x series)**

A straightforward build script that compiles a customized Linux kernel with CachyOS performance patches and packages it for both **Ubuntu/Debian** and **Arch Linux** in a single run. Built for people who want fine-grained control over their kernel without juggling multiple build systems or packaging formats.

>  **AI Assistance Notice:** This project was developed with AI help. AI-generated automation does not guarantee correctness. Always review the code, test in a safe environment, and understand the risks before using it on important systems. Human oversight is required.
>
> ⚖️ **License:** This project is dedicated to the **Public Domain**. You are free to use, modify, distribute, and sell this script for any purpose without restriction. No warranty is provided.

---

##  Quick Start
*Make sure you understand this first.*

1.  **Make the script executable**
    ```bash
    chmod +x pkgbuild.sh
    ```
2.  **Run it**
    ```bash
    ./pkgbuild.sh
    ```
3.  **Wait for the build to finish** (this takes time, grab a coffee ☕)
4.  **Install the output you need:**
    *   **Ubuntu/Debian:** `sudo dpkg -i linux-image-cachyos-*.deb`
    *   **Arch:** `sudo pacman -U linux-cachyos-*.pkg.tar.zst`
5.  **Reboot into the new kernel**

---

## 📦 What This Script Does
*   **Dual output in one run:** Creates both `.deb` and `.pkg.tar.zst` packages automatically.
*   **Split packages:** Kernel image and headers are packaged separately. Enable headers with `_build_debug=yes`.
*   **Environment overrides:** Change any setting without editing the script. Example: `_cpusched=rt ./pkgbuild.sh`.
*   **Usr-merge aware:** Works correctly on modern Ubuntu (`/lib → /usr/lib`) and traditional filesystem layouts.
*   **Source verification:** Checks `b2sum` hashes for the kernel tarball and base config before building.
*   **Optional extras:** Built-in r8125 driver (with automatic r8169 blacklist), ZFS module support, custom tick rates, schedulers, LTO, and more.

---

## ️ Key Configuration Options
All options use an underscore prefix and can be passed at runtime:  
`_variable=value ./pkgbuild.sh`

| Variable | Default | What it controls |
|:---|:---|:---|
| `_cpusched` | `bore` | Scheduler: `bore`, `bmq`, `hardened`, `cachyos`, `eevdf`, `rt`, `rt-bore` |
| `_use_llvm_lto` | `full` | Link-time optimization: `none`, `thin`, `full`, `thin-dist` |
| `_build_archpkg` | `yes` | Build Arch `.pkg.tar.zst` + mkinitcpio preset |
| `_build_deb` | `yes` | Build Debian/Ubuntu `.deb` package |
| `_build_debug` | `no` | Build & package kernel headers |
| `_build_r8125` | `yes` | Include r8125 driver (automatically blacklists r8169) |
| `_HZ_ticks` | `1000` | Timer frequency (100–1000) |
| `_preempt` | `full` | Preemption model: `full`, `lazy`, `voluntary`, `none` |
| `_hugepage` | `always` | Transparent hugepages: `always`, `madvise` |

📖 The complete list of options and inline explanations lives at the top of [`pkgbuild.sh`](pkgbuild.sh).

---

## 🛠️ Requirements
*   **OS:** Ubuntu Noble 24.04 LTS (other versions may work but are untested)
*   **CPU:** x86_64
*   **RAM:** ~16 GB recommended for full LTO builds (zram compression helps)
*   **Disk:** ~50 GB free space (kernel builds and staging take significant space)
*   **Dependencies:** The script checks for missing packages automatically. If anything is missing, it will tell you exactly what to install.

---

##  Integrity & Security Notes
*   ✅ **Verified before build:** Kernel source and base config are checked against known `b2sum` hashes.
*   ✅ **Conditional module signing:** External modules (ZFS/r8125) are signed automatically if `CONFIG_MODULE_SIG=y` is enabled in the kernel config.
*   ⚠️ **Package checksums not included:** Generated `.deb` and `.pkg.tar.zst` files are not digitally signed or checksummed by the script. Verify them manually if security is critical.
*   ⚠️ **AI-assisted development:** This script contains AI-generated logic and packaging routines. AI does not replace human review. Always test in a non-critical environment first.

---

## ⚠️ Risks & Warnings (Please Read Carefully)
Custom kernel compilation carries real, unavoidable risks. Acknowledge these before proceeding:

*   🚨 **System may fail to boot:** Mismatched configs, missing firmware, or hardware incompatibilities can render your system unbootable.
*   💾 **Data loss is possible:** Boot failures, failed initramfs generation, or disk errors during/after install can corrupt files.
*   🔓 **Security implications:** Custom kernels bypass distribution security patches and updates. You are responsible for keeping them current and safe.
*   ️ **Hardware compatibility isn't guaranteed:** Some GPUs, Wi-Fi cards, storage controllers, or peripherals may lack working out-of-tree modules.
*   📦 **No warranty or support:** This is a personal/community tool. It is not maintained by upstream Linux, CachyOS, Ubuntu, or Arch.
*   🔄 **Always keep a fallback kernel:** Do not remove your working kernel until you've confirmed the new one boots, runs correctly, and handles all your hardware.

---

## 🐛 Reporting Issues (READ THIS FIRST)
**⚠️ IMPORTANT:** Please open an issue **ONLY** at this repository:  
 **[https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues](https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues)**

**🚫 Do NOT report issues to:**
*   CachyOS (they do not maintain this script)
*   Upstream Linux Kernel repositories (this script is not supported there)
*   Ubuntu or Arch Linux bug trackers

When reporting, please include:
*   Your exact distro version (`lsb_release -a`)
*   The full command you ran (including all environment variables)
*   Complete terminal output or error logs
*   `uname -a` before building
*   What you expected to happen vs. what actually happened

*(Reminder: If you have a bug, report it here only. Do not bother upstream projects.)*

---

## 📜 Credits & Upstream Sources
This script builds on work from:
*   [CachyOS Linux Kernel](https://github.com/CachyOS/linux-cachyos)
*   [CachyOS Kernel Patches](https://github.com/cachyos/kernel-patches)
*   Arch Linux packaging standards
*   Debian `linux-image` maintainer script policies

All upstream code remains under its original licenses.

---

## 📝 Final Note
This tool is meant to be transparent, predictable, and easy to control. If something breaks, check your config, verify your hardware support, and fall back to your known-working kernel. Use it carefully, test it safely, and never trust automation blindly.

**Remember:** If you find a bug, report it **only** at [this repository's issue tracker](https://github.com/Autisticestradioluser/Build-CachyOS-Kernel-On-Ubuntu/issues).
