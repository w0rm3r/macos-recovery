# macOS Recovery Bootable USB Creator & Verifier

An interactive, fail-safe Shell CLI utility for macOS that fetches available macOS versions directly from Apple, downloads official full installers, safely formats an external USB flash drive, writes bootable recovery media using Apple's official `createinstallmedia`, and performs comprehensive cryptographic and filesystem data verification to ensure the written USB is not corrupted.

---

## Key Features

1. **Official Installer Catalog Discovery**:
   - Fetches and lists all available full installers from Apple's software distribution catalog via `softwareupdate --list-full-installers`.
   - Also automatically scans `/Applications` for any previously downloaded installer bundles to save bandwidth and time.

2. **Multi-Tier Fail-Safe Protection (Zero Risk to macOS Drive)**:
   - **External Storage Only**: Exclusively queries and displays physical external USB drives using `diskutil list -plist external physical`.
   - **Internal Drive Rejection**: Strictly filters out and blocks any disk marked as internal hardware (`Internal: True`, `OSInternalMedia: True`).
   - **Root Mount Protection**: Dynamically identifies the drive containing the active root filesystem (`/`), `/System/Volumes/Data`, or APFS physical container stores, and unconditionally prevents their selection.
   - **Double Confirmation**: Requires the user to explicitly type the exact disk identifier (e.g. `disk4`) before executing any erase or format operation.
   - **Capacity Sanity Checks**: Alerts the user if the selected drive is smaller than 14 GB (unlikely to fit modern macOS) or larger than 256 GB (to prevent accidental erasure of external backup drives).

3. **Cryptographic & Data Integrity Verification Suite**:
   - **Apple Embedded Checksum Verification**: Runs `hdiutil verify` on `BaseSystem/BaseSystem.dmg` to validate MBR, Primary GPT Header, Primary GPT Table, Apple APFS container, and overall CRC32 digital digest embedded by Apple during compilation.
   - **Bootloader & Asset Structure Check**: Confirms the integrity and accessibility of critical boot assets (`BaseSystem.dmg`, `BaseSystem.chunklist`, `.IAPhysicalMedia`, and the installer app bundle with executable binaries).
   - **Filesystem Health Check**: Scans filesystem headers and catalog allocations.
   - **Flash NAND Read & Bad-Block Scan**: Samples and reads files across the USB drive to confirm zero I/O read errors and verify that flash NAND cells are not failing.

4. **Standalone Verification Mode**:
   - Allows users to verify any existing bootable USB at any time using the `--verify` flag or interactive menu without re-writing.

5. **Dry-Run Mode**:
   - Supports `--dry-run` to simulate discovery, version selection, and safety checks without downloading 15 GB payloads or modifying disks.

---

## Prerequisites

- **Host OS**: macOS Monterey (12.0), Ventura (13.0), Sonoma (14.0), Sequoia (15.0), Tahoe, or newer.
- **Target USB Flash Drive**: Minimum **16 GB** (or 32 GB recommended for modern macOS versions).
- **Disk Space**: At least 25 GB of free space on the host Mac to temporarily download and extract the full installer.
- **Administrative Privileges (`sudo`)**: Required for formatting the USB and executing Apple's `createinstallmedia`.

---

## Quick Start

### 1. Launch the Interactive Wizard

```bash
cd /<folder where you downloaded the below script file>
./macos_recovery_usb.sh
```

Follow the numbered prompts to:
1. Select an installer version to download (or choose a pre-existing installer).
2. Select your connected USB flash drive.
3. Confirm by typing the disk identifier (e.g. `disk4`).
4. Wait for the tool to write and automatically verify your bootable recovery drive.

### 2. Verify an Existing USB Drive

If you already have a bootable macOS USB and want to test if it's healthy or corrupted:

```bash
# Auto-detect mounted installer volumes:
./macos_recovery_usb.sh --verify

# Or specify the exact volume path:
./macos_recovery_usb.sh --verify "/Volumes/Install macOS Sequoia"
```

### 3. List Available macOS Versions from Apple

```bash
./macos_recovery_usb.sh --list-only
```

---

## Command Line Options

```text
Usage: macos_recovery_usb.sh [OPTIONS]

Options:
  -h, --help                 Show this help message and exit.
  -n, --dry-run              Simulate the creation and download process without
                             altering any disks or downloading large payloads.
  -l, --list-only            List all available macOS full installers from Apple and exit.
  -v, --verify [PATH|DISK]   Verify data integrity and cryptographic signatures of
                             an existing bootable USB drive (e.g. /Volumes/Install\ macOS\ Sonoma).
  -d, --disk <diskX>         Pre-select target BSD disk (e.g. disk4). Safety validation
                             will still be strictly enforced!
  -i, --installer <app_path> Use an existing macOS installer application bundle
                             (e.g. /Applications/Install macOS Sequoia.app).
```

---

## How to Boot macOS Recovery from the USB

Once your bootable USB is created and verified:

### On Apple Silicon Macs (M1, M2, M3, M4)
1. Plug the bootable USB into your Mac.
2. Ensure the Mac is shut down completely.
3. Press and **HOLD the Power button** (Touch ID button).
4. Continue holding until **"Loading startup options"** appears on the screen.
5. Select **"Install macOS..."** and click **Continue**.

### On Intel-based Macs
1. Plug the bootable USB into your Mac.
2. Ensure the Mac is shut down completely.
3. Turn on the Mac and immediately press and **HOLD the Option (⌥) / Alt key**.
4. Release the key when the **Startup Manager** screen appears.
5. Select the bootable USB drive icon and press **Return**.

---

## Testing & Validation

A built-in automated test suite is provided to verify script syntax, argument parsing, fail-safe barriers, and verification logic:

```bash
./test_macos_recovery_usb.sh
```
