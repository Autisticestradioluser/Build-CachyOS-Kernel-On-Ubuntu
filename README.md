---

# Custom Linux Kernel Builder for Ubuntu (Arch + Debian Output)

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
*   **Source verification:** Checks `b2sum` hashes for the kernel tarball and base config, and verifies the kernel tarball's GPG signature, before building. (Patches and the r8125 driver source are not verified — see below.)
*   **Optional extras:** Built-in r8125 driver, ZFS module support, custom tick rates, schedulers, LTO, and more.

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
| `_build_r8125` | `yes` | Include r8125 driver. Marks the `.deb` as conflicting with the `r8169-dkms` package, but does **not** blacklist the in-tree `r8169` kernel module — see "Integrity & Security Notes" below |
| `_build_nvidia` | `no` | Build NVIDIA proprietary 580.x kernel modules (Maxwell/Pascal GPUs). Incompatible with RT schedulers (`rt`, `rt-bore`). Uses sha256sum verification against NVIDIA's official checksum file. |
| `_HZ_ticks` | `500` | Timer frequency (100–1000) |
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
*   ✅ **Kernel source is verified two ways:** the tarball is checked against a hardcoded `b2sum` hash, and its GPG signature is verified against the CachyOS maintainer keys before anything is extracted. The base `.config` is checked against a hardcoded `b2sum` hash.
*   ⚠️ **Patches are downloaded but not verified:** the scheduler, hardened, and RT patches are pulled over HTTPS from the CachyOS `kernel-patches` repo with no checksum or signature check before being applied.
*   ⚠️ **r8125 driver source is unpinned and unverified:** with `_build_r8125=yes` (the default), the driver is cloned fresh from a third-party fork (`aravance/r8125`) with no commit pin, checksum, or signature check — unlike ZFS, which is cloned at a specific pinned commit. You're trusting that fork's current `HEAD` at build time.
*   ⚠️ **r8169 is not blacklisted:** enabling r8125 only adds a `Conflicts: r8169-dkms` entry to the `.deb` control file. It does **not** blacklist the in-tree `r8169` kernel module (via `/etc/modprobe.d/` or similar), and the Arch package gets no equivalent handling at all. If your NIC is supported by both drivers, you may need to blacklist `r8169` yourself to avoid both trying to bind to the same device.
*   ✅ **Conditional module signing:** external modules (ZFS/r8125) are signed automatically if `CONFIG_MODULE_SIG=y` is enabled in the kernel config.
*   ⚠️ **Package checksums not included:** generated `.deb` and `.pkg.tar.zst` files are not digitally signed or checksummed by the script. Verify them manually if security is critical.
*   ⚠️ **Overriding the pinned hashes is on you:** `_kernel_b2sum` and `_config_b2sum` can be overridden via environment variable (e.g. to build a newer release before the script is updated). If you do this, verification is only as good as the hash you supply — the script won't warn you either way.
*   ℹ️ **Runs under `fakeroot`, not real root:** if not already running under `fakeroot`, the script silently re-executes itself under it. This fakes root ownership for packaging purposes only; it does not need or request real root to build the kernel. `sudo` is only needed to install missing build dependencies, and afterward to install the finished package.
*   ⚠️ **AI-assisted development:** this script contains AI-generated logic and packaging routines. AI does not replace human review. Always test in a non-critical environment first.

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
