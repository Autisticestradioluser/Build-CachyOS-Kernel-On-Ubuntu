# Linux Kernel Builder for Ubuntu with CachyOS Patches (Work in Progress)

> ⚠️ **WARNING**: This is an experimental script under active development. It may contain bugs, incomplete functionality, or unstable behavior. Use at your own risk.

---

## 🛠️ Overview

This script automates the process of building the Linux kernel on Ubuntu Noble (24.04 LTS), applying patches from **CachyOS**, and generating both:

- A `.deb` package for Debian and Ubuntu-based systems.
- An *incomplete* Arch Linux package (work in progress).

The goal is to create a streamlined, reproducible kernel build pipeline tailored for Debian and Ubuntu users that may also have an Arch PC or dual boot but just want to compile the kernel once
Note that if you use _processor_opt=${_processor_opt:-native} you will need to be sure that both CPUs are the same in clang which may make it more suitable for a dual boot configuration

---

## 📦 What You Get

✅ `.deb` package compatible with Ubuntu Noble  
⚠️ Arch package — currently incomplete; will not install correctly  
🔧 CachyOS patches applied
🔄 Automated build workflow using standard tools (`make`, `fakeroot`, `dpkg-deb`, etc.)

---

## 🧪 Current Status

🚧 **Work in Progress**  
⛔ **Bugs Expected** — These may stem from:
- Poor coding practices / missing edge cases
- LLM-generated code logic flaws
- Incompatibilities between patch layers and kernel versions
- Unhandled dependencies or build environment quirks

**Please report bugs via GitHub issues!**

---

## 💡 Why This Exists

CachyOS uses a highly optimized kernel configuration focused on performance. This script aims to:

- Replicate CachyOS’s kernel build environment on Ubuntu.
- Allow easy kernel upgrades or customizations.

---
