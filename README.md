# AOSP AVB Boot Toolchain ⚙️

> **Complete Android boot image backup, patch, sign, and flash toolchain**  
> **Designed for bootloader-locked devices** to maintain root access after OTA updates  
> **Uses custom signing keys** for AVB verification and supports all major root solutions

---

## ✨ Features

- 🔒 **Complete Workflow**: Factory backup → OTA backup → Root patching → Custom key signing → Device flashing
- 🔐 **Custom Key Signing**: Sign boot images with your own private keys for bootloader verification
- 🧰 **Built-in Tools**: Repository includes all necessary tools (`rebuild_avb.py`, `avbtool.py`, key generation)
- 🚀 **Root Solution Support**: Auto-detection and patching with Magisk, APatch, KernelSU (GKI/LKM)
- 📱 **Device Safety**: Comprehensive backup and restore capabilities with signature verification
- 📦 **Termux Ready**: Designed to run in Termux environment on Android devices
- 🔄 **APatch KPM Support**: Special script for re-signing after KernelPatch Module installation

---

## 📦 Dependencies (Termux)

Install required packages in Termux:

```bash
pkg update
pkg install python openssl-tool
```

**Requirements:**
- **Python 3** - For running avbtool.py and rebuild_avb.py
- **OpenSSL tools** - For key generation and cryptographic operations
- **Root access** - For direct partition access on Android device

---

## 🔑 Signing Key Setup

**Replace the default AOSP test key** with your own private key:

```bash
# Put your private key at this path:
tools/pem/testkey_rsa4096.pem
```

---

## 📁 Project Structure

```text
AOSP_REBUILD_AVB_BOOT/
├── 1_restore_factory.sh   # Restore factory images from backups
├── 2_backup_factory.sh    # Backup post-OTA partitions with verification
├── 3_patch.sh             # Patch boot images with root solutions
├── 3-1_dump_user_patched.sh # Dump user-patched images from root manager
├── 4_sign_patched.sh      # Sign patched images with custom keys
├── 5_flash.sh             # Flash signed images to device partitions
├── 9_resign.sh            # Re-sign partitions (KPM support & general use)
├── rebuild_avb.py         # Core AVB rebuilding script
├── verify_images.sh       # Image verification utility
├── tools/                 # Signing keys, avbtool.py, and utilities
│   ├── pem/               # Private/public key pairs
│   ├── avbtool.py         # Android Verified Boot tool
│   └── ...
└── README.md
```

---

## 🚀 Complete Workflow Guide

### Prerequisites
- **Android device** with root access (su permissions)
- **A/B partition scheme** support (bootloader-locked devices)
- **Termux** terminal emulator installed
- Device with **custom ROM** or **bootloader that accepts custom signatures**

### 🔒 Two Main Workflows

This toolchain provides **two distinct workflows** for different scenarios:

## 📱 Workflow 1: OTA Update Process (Scripts 1-5)
**Use when**: System OTA updates are available and you want to maintain root access

### Step 0: Prepare Factory Backups (Required for Incremental OTAs)

**Why needed**: Incremental OTAs require factory images to restore clean state first.

Choose ONE method to populate `backups/` folder:

**Method A: Extract from Firmware Package (Recommended)**
```bash
# Download firmware matching your build number, extract 6 images to backups/
mkdir -p backups/
# Place: boot_a.img, boot_b.img, init_boot_a.img, init_boot_b.img, vbmeta_a.img, vbmeta_b.img
```

**Method B: Temporary Root**
```bash
fastboot boot patched_kernel.img
# Once booted with root access:
./2_backup_factory.sh
```

**Method C: EDL/9008 Mode (Qualcomm)**
```bash
# Use EDL tools (QFIL, MiFlash) to dump partitions directly
```

**Method D: BROM Mode (MediaTek)**
```bash
# Use MTK tools (SP Flash Tool, MTKClient) to dump partitions
```

**Verify backups before proceeding:**
```bash
./verify_images.sh backups/
```

---

### Main OTA Process (After Step 0 Complete)

**Step 1: Restore to factory state**
```bash
./1_restore_factory.sh
# This restores clean, unsigned images to allow OTA installation
# REQUIRES factory backups from Step 0!
# Use --dry-run to test, --force-flash to skip confirmations
```

**Step 2: Apply OTA update**
```bash
# Apply OTA update through system settings
# OTA will install to inactive slot (slot A <-> slot B)
```

**Step 3: Create post-OTA backup**
```bash
./2_backup_factory.sh
# Detects OTA changes and creates verified backups of new slot
# Use --dry-run to test, --force-backup to skip confirmations
```

**Step 4: Patch boot images (choose ONE method)**

Method A: Auto-patch with CLI
```bash
./3_patch.sh
# Auto-detects target slot and root solution
# Patches images from backup, NOT currently running slot
# Use --dry-run to test, --force-patch to skip confirmations
```

Method B: Dump user-patched images
```bash
./3-1_dump_user_patched.sh
# For when user already patched via root manager
# Dumps from inactive slot partitions, compares with backup to verify patching
# Use --dry-run to test, --force-dump to skip confirmations
```

**Step 5: Sign patched images**
```bash
./4_sign_patched.sh
# Uses rebuild_avb.py to sign with your custom keys
# Use --dry-run to test, --force-sign to skip confirmations
```

**Step 6: Flash signed images**
```bash
./5_flash.sh
# Default: OTA mode - flashes to inactive slot, maintaining A/B partition integrity
# Options: --mode current (flash to current slot) or --slot a/b (explicit slot)
```

## 🔌 Workflow 2: Partition Re-signing (Script 9)
**Use when**: Installing APatch KernelPatch Modules (KPM) or general partition re-signing

**Re-sign partitions:**
```bash
./9_resign.sh
# Default: current mode - re-signs current running partitions (KPM use case)
```

**With options:**
```bash
# Test without actual changes
./9_resign.sh --dry-run

# Skip confirmation prompts  
./9_resign.sh --force-flash

# OTA mode - re-sign other slot
./9_resign.sh --mode ota

# Explicit slot selection
./9_resign.sh --slot a
```

**This script automatically:**
1. Dumps target slot's vbmeta, boot, and init_boot partitions
2. Checks if already properly signed (skips if already signed)
3. Signs them with your private key using rebuild_avb.py (if needed)
4. Flashes back to target slot (with strong confirmation prompts)

## 🆘 Recovery (Both Workflows)
```bash
# Restore to factory state anytime if issues occur
./1_restore_factory.sh
# Compares current partitions with backups and restores differences
# Use --dry-run to test, --force-flash to skip confirmations
```

### 💡 Key Concepts for Bootloader-Locked Devices

- **Slot Management**: OTA updates install to the **inactive slot**, while your current rooted system runs from the **active slot**
- **Custom Key Signing**: Uses your own private keys to maintain boot verification on locked bootloaders
- **Non-Destructive**: Factory backups allow safe rollback to clean state for OTA installation
- **Root Preservation**: Automatically maintains root access after each OTA update
- **KPM Support**: Special handling for APatch Kernel Patch Modules that modify running kernel

---

## 📋 Script Details

### `1_restore_factory.sh`
- **Purpose**: Restore device to factory state
- **Features**: Hash comparison, size validation, slot detection, cleanup
- **Usage**: `./1_restore_factory.sh [--dry-run] [--force-flash]`

### `2_backup_factory.sh` 
- **Purpose**: Backup partition images with OTA change detection
- **Features**: Signature verification, integrity checks, OTA validation, cleanup
- **Usage**: `./2_backup_factory.sh [--dry-run] [--force-backup]`

### `3_patch.sh`
- **Purpose**: Patch boot images with root solutions
- **Features**: Auto-detection of root solutions and device slots, cleanup
- **Usage**: `./3_patch.sh [--slot a|b] [--root magisk|apatch|kernelsu-gki|kernelsu-lkm] [--dry-run] [--force-patch]`

### `3-1_dump_user_patched.sh` 🆕
- **Purpose**: Dump user-patched images from root manager (alternative to script 3)
- **Features**: Dumps from partitions instead of patching, backup comparison verification
- **Usage**: `./3-1_dump_user_patched.sh [--slot a|b] [--current-slot a|b] [--partition boot|init_boot] [--dry-run] [--force-dump]`
- **Use Case**: When user already patched images through root manager interface

### `4_sign_patched.sh`
- **Purpose**: Sign patched images with custom keys using rebuild_avb.py
- **Features**: Automatic signing, verification, chained partition support, cleanup
- **Usage**: `./4_sign_patched.sh [--dry-run] [--force-sign]`

### `5_flash.sh`
- **Purpose**: Flash signed images to device partitions
- **Features**: Safety confirmations, size validation, slot management, cleanup
- **Usage**: `./5_flash.sh [--slot a|b] [--mode ota|current] [--dry-run] [--force-flash]`
- **Default**: OTA mode (flash to inactive slot)

### `9_resign.sh` 🆕
- **Purpose**: Re-sign partitions with custom keys (KPM support & general use)
- **Features**: Pre-verification, auto-skip if signed, partition dumping, signing, flashing
- **Usage**: `./9_resign.sh [--slot a|b] [--mode ota|current] [--dry-run] [--force-flash]`
- **Default**: Current mode (re-sign current running partitions for KPM use case)
- **Smart Skip**: Exits early if partitions are already properly signed

---

## ⚠️ Important Notes

### Security Warnings
- **Default AOSP keys are for testing only** - replace with your own private keys for production
- **Designed for bootloader-locked devices** with custom ROM/unlocked-then-relocked bootloader
- **NOT for production devices with OEM keys** - requires device that accepts custom signatures
- Always verify `boot.img` is standard Android boot image format
- Keep factory backups and private keys safe for recovery

### Device Compatibility  
- Designed for **A/B partition scheme** devices with **bootloader-locked** configuration
- Requires **root access** for direct partition access
- **Must be used on devices that accept custom signing keys** (custom ROMs, development devices)
- Tested on devices using custom key signatures after bootloader relock
- **Will NOT work on stock OEM devices** with hardware-enforced signature verification

### Safety Features
- Comprehensive backup system with verification
- **Three-mode safety pattern**: `--dry-run` (test), `--force-*` (skip confirmations), or manual confirmation
- Multiple confirmation prompts for destructive operations (type 'YES' to confirm)
- Automatic slot detection and management
- Hash verification and signature checking
- **Automatic cleanup** of temporary files after each script execution
- **Smart OTA detection** prevents unnecessary operations

---

## 🫡 Credits

- **AOSP** / Android Verified Boot project
- **Magisk** / **APatch** / **KernelSU** projects  
- **Termux** Android terminal emulator
- **Android** open source community
- **AOSP_REBUILD_AVB_BOOT** re-sign script
