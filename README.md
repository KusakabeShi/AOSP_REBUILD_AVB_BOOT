# AOSP AVB Boot Toolchain ⚙️

> **Complete Android boot image backup, patch, sign, and flash toolchain**  
> Uses **AOSP public test keys** for AVB signing and supports root solutions

---

## ✨ Features

- 🔒 **Complete Workflow**: Factory backup → OTA backup → Root patching → AVB signing → Device flashing
- 🔐 **AOSP Test Key Signing**: Re-sign boot images with AOSP provided public test keys
- 🧰 **Built-in Tools**: Repository includes all necessary tools (`rebuild_avb.py`, `avbtool.py`, signing keys)
- 🚀 **Root Solution Support**: Auto-detection and patching with Magisk, APatch, KernelSU (GKI/LKM)
- 📱 **Device Safety**: Comprehensive backup and restore capabilities with signature verification
- 📦 **CI Friendly**: Can be used directly in GitHub Actions with archive snapshots

---

## 📁 Project Structure

```text
AOSP_REBUILD_AVB_BOOT/
├── 1_restore_factory.sh  # Restore factory images from backups
├── 2_backup_factory.sh   # Backup post-OTA partitions with verification
├── 3_patch.sh            # Patch boot images with root solutions
├── 4_sign_patched.sh     # Sign patched images with AVB
├── 5_flash.sh            # Flash signed images to device partitions
├── rebuild_avb.py        # Core AVB rebuilding script
├── verify_images.sh      # Image verification utility
├── tools/                # Signing keys, avbtool.py, and utilities
└── README.md
```

## 🚀 Complete Workflow Guide

### Prerequisites
- **Android device** with root access (su permissions)
- **A/B partition scheme** support
- **Terminal emulator** or ADB shell access

### Phase 1: Initial Factory Backup
```bash
# Run this BEFORE applying any OTA updates
# Creates baseline factory image backups
./2_backup_factory.sh
```

### Phase 2: Post-OTA Update Process
```bash
# 1. Apply your OTA update through normal system update

# 2. Create post-OTA backup (with signature verification)
./2_backup_factory.sh
# This will detect OTA changes and create verified backups

# 3. Patch boot images with your preferred root solution
./3_patch.sh
# Auto-detects: Magisk, APatch, KernelSU-GKI, KernelSU-LKM

# 4. Sign patched images with AOSP test keys
./4_sign_patched.sh --image patched/boot_a_magisk_20231201_120000.img

# 5. Flash signed images to device
./5_flash.sh --image patched_signed/boot_signed.img --vbmeta patched_signed/vbmeta_signed.img
```

### Phase 3: Recovery (if needed)
```bash
# Restore to factory state anytime
./1_restore_factory.sh
# Compares current partitions with backups and restores differences
```

## 📋 Script Details

### `1_restore_factory.sh`
- **Purpose**: Restore device to factory state
- **Features**: Hash comparison, size validation, slot detection
- **Usage**: `./1_restore_factory.sh [--dry-run] [--force-flash]`

### `2_backup_factory.sh` 
- **Purpose**: Backup partition images with OTA change detection
- **Features**: Signature verification, integrity checks, OTA validation
- **Usage**: `./2_backup_factory.sh [--dry-run] [--force-backup]`

### `3_patch.sh`
- **Purpose**: Patch boot images with root solutions
- **Features**: Auto-detection of root solutions and device slots
- **Usage**: `./3_patch.sh [--slot a|b] [--root magisk|apatch|kernelsu-gki|kernelsu-lkm]`

### `4_sign_patched.sh`
- **Purpose**: Sign patched images with AVB using rebuild_avb.py
- **Features**: Automatic signing, verification, chained partition support
- **Usage**: `./4_sign_patched.sh --image <patched_image> [--dry-run]`

### `5_flash.sh`
- **Purpose**: Flash signed images to device partitions
- **Features**: Safety confirmations, size validation, slot management
- **Usage**: `./5_flash.sh --image <signed_image> [--vbmeta <signed_vbmeta>] [--slot a|b]`

## 🔧 Advanced Usage

### Manual Partition Operations
```bash
# Specify custom slot
./3_patch.sh --slot b --root magisk

# Specify custom root solution  
./3_patch.sh --root kernelsu-gki

# Force operations without confirmation
./4_sign_patched.sh --image patched/boot.img --force-sign
./5_flash.sh --image signed/boot.img --force-flash

# Dry run mode (test without changes)
./1_restore_factory.sh --dry-run
./2_backup_factory.sh --dry-run
```

### Chained Partition Mode (Advanced)
```bash
# For devices with chained partitions (no vbmeta dependency)
./4_sign_patched.sh --image patched/boot.img  # Auto-detects chained mode
./5_flash.sh --image signed/boot.img          # No vbmeta needed
```

## ⚠️ Important Notes

### Security Warnings
- Uses **AOSP public test keys** - suitable for debugging, development, and custom ROMs
- **NOT for production devices** - does not use device-specific private keys
- Always verify `boot.img` is standard Android boot image format
- Keep factory backups safe for recovery

### Device Compatibility  
- Designed for **A/B partition scheme** devices
- Requires **root access** for direct partition access
- Tested on devices using AOSP public key signatures
- May work on custom ROMs and development devices

### Safety Features
- Comprehensive backup system with verification
- Dry-run modes for all operations  
- Multiple confirmation prompts for destructive operations
- Automatic slot detection and management
- Hash verification and signature checking

## 🔍 Troubleshooting

### Common Issues
```bash
# Missing partitions
# Solution: Ensure running on Android device with root

# Size mismatches  
# Solution: Check backup image compatibility with device

# Signature verification failures
# Solution: Verify OTA integrity, re-apply if needed

# Root detection issues
# Solution: Manually specify root solution with --root parameter
```

### Recovery Procedures
1. **Boot issues**: Use `./1_restore_factory.sh` to restore working state
2. **OTA problems**: Re-apply OTA and run `./2_backup_factory.sh` again  
3. **Patch failures**: Check root solution installation and try manual specification

## 🫡 Credits

- **AOSP** / Android Verified Boot project
- **Magisk** / **APatch** / **KernelSU** projects  
- **Android** open source community
