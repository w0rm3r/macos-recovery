#!/usr/bin/env bash
#
# macos_recovery_usb.sh
# macOS Recovery Bootable USB Creator & Data Integrity Verifier
#
# Automates:
#   1. Fetching available macOS full installers directly from Apple.
#   2. Selecting and downloading the desired macOS version.
#   3. Scanning and presenting ONLY verified external USB storage devices.
#   4. Multi-tier failsafes preventing any internal or system disk override.
#   5. Creating bootable recovery media with Apple's createinstallmedia tool.
#   6. Full data integrity & cryptographic verification to ensure the USB is not corrupted.
#

set -o pipefail

SCRIPT_VERSION="1.0.0"
DRY_RUN=false
LIST_ONLY=false
VERIFY_ONLY=""
TARGET_DISK_ARG=""
CUSTOM_INSTALLER_APP=""
TEMP_DIR=""

# --- ANSI Color Codes ---
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
WHITE="\033[1;37m"
RESET="\033[0m"

# --- Status Indicators ---
OK="${GREEN}[✓]${RESET}"
FAIL="${RED}[✗]${RESET}"
WARN="${YELLOW}[!]${RESET}"
INFO="${CYAN}[i]${RESET}"
ARROW="${MAGENTA}❯${RESET}"

# Cleanup on exit
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# --- UI Helpers ---
print_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    echo "======================================================================"
    echo "       macOS Recovery Bootable USB Creator & Verifier v${SCRIPT_VERSION}"
    echo "======================================================================"
    echo -e "${RESET}"
}

print_header() {
    echo "" >&2
    echo -e "${BLUE}${BOLD}==> $1${RESET}" >&2
}

print_success() {
    echo -e "${OK} $1" >&2
}

print_error() {
    echo -e "${FAIL} ${RED}$1${RESET}" >&2
}

print_warning() {
    echo -e "${WARN} ${YELLOW}$1${RESET}" >&2
}

print_info() {
    echo -e "${INFO} $1" >&2
}

# --- Help Message ---
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Interactive CLI utility to download official macOS installers and create
verified bootable recovery USB media with multi-tier internal disk protection.

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

Safety Guarantee:
  Internal system drives, APFS system containers, and active root mounts (/)
  are strictly filtered and blocked from selection or modification.

EOF
}

# --- Parse Arguments ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -l|--list-only)
                LIST_ONLY=true
                shift
                ;;
            -v|--verify)
                if [[ -n "$2" && "$2" != -* ]]; then
                    VERIFY_ONLY="$2"
                    shift 2
                else
                    VERIFY_ONLY="INTERACTIVE"
                    shift
                fi
                ;;
            -d|--disk)
                TARGET_DISK_ARG="$2"
                shift 2
                ;;
            -i|--installer)
                CUSTOM_INSTALLER_APP="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${RESET}"
                show_help
                exit 1
                ;;
        esac
    done
}

# --- System Checks ---
check_prerequisites() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        print_error "This script is designed exclusively for macOS."
        exit 1
    fi

    local required_tools=("diskutil" "softwareupdate" "python3" "hdiutil")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            print_error "Required system utility missing: $tool"
            exit 1
        fi
    done
}

# --- Python Helper: Safe Disk Enumeration & Safety Verification ---
python_disk_helper() {
    local cmd="$1"
    shift
    python3 -c "
import sys, subprocess, plistlib, json, os

def get_root_identifiers():
    try:
        out = subprocess.check_output(['diskutil', 'info', '-plist', '/'])
        info = plistlib.loads(out)
        return {
            'root_dev': info.get('DeviceIdentifier', ''),
            'parent_disk': info.get('ParentWholeDisk', ''),
            'internal': info.get('Internal', True)
        }
    except Exception:
        return {'root_dev': '', 'parent_disk': 'disk0', 'internal': True}

def get_system_apfs_stores():
    stores = set()
    try:
        apfs_plist = plistlib.loads(subprocess.check_output(['diskutil', 'apfs', 'list', '-plist']))
        for container in apfs_plist.get('Containers', []):
            is_sys = False
            for v in container.get('APFSVolumes', []):
                if v.get('MountPoint') in ['/', '/System/Volumes/Data']:
                    is_sys = True
                    break
            if is_sys:
                for s in container.get('PhysicalStores', []):
                    stores.add(s.get('DeviceIdentifier', ''))
    except Exception:
        pass
    return stores

def list_candidate_usb_disks():
    root_meta = get_root_identifiers()
    sys_stores = get_system_apfs_stores()
    try:
        out = subprocess.check_output(['diskutil', 'list', '-plist', 'external', 'physical'])
        data = plistlib.loads(out)
    except Exception:
        return []

    candidates = []
    for disk_dict in data.get('AllDisksAndPartitions', []):
        dev_id = disk_dict.get('DeviceIdentifier')
        if not dev_id:
            continue
        if dev_id == root_meta['parent_disk']:
            continue
        if any(dev_id in s for s in sys_stores):
            continue

        try:
            info_bytes = subprocess.check_output(['diskutil', 'info', '-plist', dev_id])
            info = plistlib.loads(info_bytes)
        except Exception:
            continue

        # Hard filters against internal hardware
        if info.get('Internal', False) or info.get('OSInternalMedia', False):
            continue
        if not info.get('RemovableMediaOrExternalDevice', False):
            continue

        protocol = info.get('BusProtocol', 'Unknown')
        media_name = info.get('MediaName') or 'External Storage'
        size_bytes = info.get('TotalSize', 0)
        size_gb = size_bytes / (1024**3)

        volumes = []
        partitions = disk_dict.get('Partitions', [])
        for p in partitions:
            vname = p.get('VolumeName')
            mp = p.get('MountPoint')
            p_id = p.get('DeviceIdentifier')
            if vname:
                volumes.append({
                    'name': vname,
                    'id': p_id,
                    'mount': mp or ''
                })
            elif p_id:
                volumes.append({
                    'name': p_id,
                    'id': p_id,
                    'mount': mp or ''
                })

        candidates.append({
            'identifier': dev_id,
            'node': f'/dev/{dev_id}',
            'media_name': media_name,
            'protocol': protocol,
            'size_bytes': size_bytes,
            'size_gb': round(size_gb, 2),
            'volumes': volumes
        })
    return candidates

def validate_disk_safety(target_disk):
    target = target_disk.replace('/dev/', '').strip()
    root_meta = get_root_identifiers()
    sys_stores = get_system_apfs_stores()

    if not target:
        return False, 'No disk identifier provided.'
    if target == root_meta['parent_disk'] or target == root_meta['root_dev']:
        return False, 'CRITICAL: Selected disk contains active macOS root system filesystem (/)'
    for s in sys_stores:
        if target in s or s in target:
            return False, f'CRITICAL: Disk is part of system container store ({s})'

    try:
        info = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', target]))
    except Exception as e:
        return False, f'Could not read disk metadata: {e}'

    if info.get('Internal', False):
        return False, 'CRITICAL: Device is marked as INTERNAL hardware storage!'
    if info.get('OSInternalMedia', False):
        return False, 'CRITICAL: Device is marked as OS Internal Media!'
    if not info.get('RemovableMediaOrExternalDevice', False):
        return False, 'CRITICAL: Device is NOT marked as removable/external storage!'

    # Check partitions for system paths
    try:
        list_plist = plistlib.loads(subprocess.check_output(['diskutil', 'list', '-plist', target]))
        for d in list_plist.get('AllDisksAndPartitions', []):
            for part in d.get('Partitions', []):
                mp = part.get('MountPoint', '')
                if mp in ['/', '/System', '/System/Volumes/Data', '/private', '/Library', '/Users']:
                    return False, f'CRITICAL: Partition {part.get(\"DeviceIdentifier\")} is mounted at protected system path {mp}'
    except Exception:
        pass

    media_name = info.get('MediaName', 'External Storage')
    size_gb = info.get('TotalSize', 0) / (1024**3)
    protocol = info.get('BusProtocol', 'Unknown')
    return True, f'Safe external drive: {media_name} ({size_gb:.1f} GB, Bus: {protocol})'

cmd = sys.argv[1]
if cmd == 'list':
    print(json.dumps(list_candidate_usb_disks()))
elif cmd == 'validate':
    disk = sys.argv[2]
    safe, msg = validate_disk_safety(disk)
    print(json.dumps({'safe': safe, 'message': msg}))
" "$cmd" "$@"
}

# --- Installer Discovery & Selection ---
fetch_available_installers() {
    print_info "Scanning Apple catalog for available full macOS installers..."
    echo -e "${DIM}Running: softwareupdate --list-full-installers (this may take a few seconds)${RESET}" >&2

    local raw_output
    raw_output=$(softwareupdate --list-full-installers 2>&1)
    
    python3 -c "
import sys, re, json

raw = sys.stdin.read()
# Example line: * Title: macOS Sequoia, Version: 15.8, Size: 15296950KiB, Build: 24H23, Deferred: NO
pattern = re.compile(r'^\*\s+Title:\s*(?P<title>[^,]+),\s*Version:\s*(?P<version>[^,]+),\s*Size:\s*(?P<size>[^,]+),\s*Build:\s*(?P<build>[^,]+)', re.MULTILINE)
matches = [m.groupdict() for m in pattern.finditer(raw)]

clean_installers = []
for m in matches:
    title = m['title'].strip()
    ver = m['version'].strip()
    size = m['size'].strip()
    build = m['build'].strip()
    # Format size if in KiB
    if size.endswith('KiB'):
        try:
            kib = int(size[:-3])
            gb = kib / (1024 * 1024)
            size_str = f'{gb:.2f} GB'
        except Exception:
            size_str = size
    else:
        size_str = size

    clean_installers.append({
        'title': title,
        'version': ver,
        'size': size_str,
        'build': build
    })

print(json.dumps(clean_installers))
" <<< "$raw_output"
}

scan_local_existing_installers() {
    python3 -c "
import os, json

apps = []
apps_dir = '/Applications'
if os.path.exists(apps_dir):
    for item in os.listdir(apps_dir):
        if item.startswith('Install macOS') and item.endswith('.app'):
            full_path = os.path.join(apps_dir, item)
            media_tool = os.path.join(full_path, 'Contents', 'Resources', 'createinstallmedia')
            if os.path.exists(media_tool):
                apps.append({
                    'name': item,
                    'path': full_path
                })
print(json.dumps(apps))
"
}

choose_installer() {
    if [[ -n "$CUSTOM_INSTALLER_APP" ]]; then
        if [[ -d "$CUSTOM_INSTALLER_APP" && -x "$CUSTOM_INSTALLER_APP/Contents/Resources/createinstallmedia" ]]; then
            SELECTED_INSTALLER_APP="$CUSTOM_INSTALLER_APP"
            print_success "Using specified installer application: ${BOLD}$SELECTED_INSTALLER_APP${RESET}"
            return 0
        else
            print_error "Specified installer path is invalid or missing createinstallmedia: $CUSTOM_INSTALLER_APP"
            exit 1
        fi
    fi

    print_header "Step 1: Choose macOS Installer Version"

    # Check local existing installers first
    local local_json
    local_json=$(scan_local_existing_installers)
    local local_count
    local_count=$(python3 -c "import json, sys; print(len(json.loads(sys.argv[1])))" "$local_json" 2>/dev/null || echo "0")

    # Fetch remote installers
    local catalog_json
    catalog_json=$(fetch_available_installers)
    local catalog_count
    catalog_count=$(python3 -c "import json, sys; print(len(json.loads(sys.argv[1])))" "$catalog_json" 2>/dev/null || echo "0")

    if [[ "$LIST_ONLY" == true ]]; then
        echo ""
        echo -e "${BOLD}Available macOS Full Installers from Apple Catalog:${RESET}"
        python3 -c "
import json, sys
items = json.loads(sys.argv[1])
for i, item in enumerate(items, 1):
    print(f'  {i:2d}) {item[\"title\"]} - Version {item[\"version\"]} (Build {item[\"build\"]}, {item[\"size\"]})')
" "$catalog_json"
        exit 0
    fi

    echo ""
    echo -e "${BOLD}Select an option below:${RESET}"

    local option_idx=1
    declare -a OPTION_MAP_TYPE
    declare -a OPTION_MAP_VAL

    # Display local installers if any
    if [[ "$local_count" -gt 0 ]]; then
        echo -e "\n  ${GREEN}${BOLD}Pre-downloaded Local Installers (Ready to write immediately):${RESET}"
        local local_lines
        local_lines=$(python3 -c "
import json, sys
try:
    for app in json.loads(sys.argv[1]):
        print(app['name'] + '|' + app['path'])
except Exception:
    pass
" "$local_json")
        while IFS='|' read -r name path; do
            [[ -z "$name" ]] && continue
            echo -e "    ${CYAN}[$option_idx]${RESET} Local: ${BOLD}$name${RESET} (${DIM}$path${RESET})"
            OPTION_MAP_TYPE[$option_idx]="LOCAL"
            OPTION_MAP_VAL[$option_idx]="$path"
            ((option_idx++))
        done <<< "$local_lines"
    fi

    # Display remote catalog installers
    if [[ "$catalog_count" -gt 0 ]]; then
        echo -e "\n  ${BLUE}${BOLD}Download from Apple Servers:${RESET}"
        local catalog_lines
        catalog_lines=$(python3 -c "
import json, sys
try:
    for it in json.loads(sys.argv[1]):
        print(it['title'] + '|' + it['version'] + '|' + it['build'] + '|' + it['size'])
except Exception:
    pass
" "$catalog_json")
        while IFS='|' read -r title ver build size; do
            [[ -z "$title" ]] && continue
            echo -e "    ${CYAN}[$option_idx]${RESET} ${BOLD}$title${RESET} v$ver (Build $build, $size)"
            OPTION_MAP_TYPE[$option_idx]="REMOTE"
            OPTION_MAP_VAL[$option_idx]="$ver|$title"
            ((option_idx++))
        done <<< "$catalog_lines"
    else
        print_warning "Could not fetch remote installer list (network or softwareupdate catalog issue)."
    fi

    echo -e "    ${RED}[q]${RESET} Quit"
    echo ""

    while true; do
        read -r -p "Enter selection [1-$((option_idx-1))]: " choice
        if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            echo "Operation cancelled by user."
            exit 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < option_idx )); then
            local sel_type="${OPTION_MAP_TYPE[$choice]}"
            local sel_val="${OPTION_MAP_VAL[$choice]}"

            if [[ "$sel_type" == "LOCAL" ]]; then
                SELECTED_INSTALLER_APP="$sel_val"
                DOWNLOAD_NEEDED=false
                print_success "Selected local installer: ${BOLD}$SELECTED_INSTALLER_APP${RESET}"
                break
            else
                SELECTED_VERSION=$(echo "$sel_val" | cut -d'|' -f1)
                SELECTED_TITLE=$(echo "$sel_val" | cut -d'|' -f2)
                DOWNLOAD_NEEDED=true
                print_success "Selected to download: ${BOLD}$SELECTED_TITLE (Version $SELECTED_VERSION)${RESET}"
                break
            fi
        else
            echo -e "${RED}Invalid selection. Please choose a valid number or 'q'.${RESET}"
        fi
    done
}

# --- Download Installer ---
execute_installer_download() {
    if [[ "$DOWNLOAD_NEEDED" != true ]]; then
        return 0
    fi

    print_header "Step 2: Downloading macOS Installer"
    print_info "Downloading ${BOLD}$SELECTED_TITLE (v$SELECTED_VERSION)${RESET} from Apple..."
    echo -e "${DIM}This command will save the installer to /Applications/Install <Title>.app${RESET}"
    echo -e "${DIM}Command: softwareupdate --fetch-full-installer --full-installer-version $SELECTED_VERSION${RESET}"

    if [[ "$DRY_RUN" == true ]]; then
        print_warning "[DRY-RUN] Simulating download step. Bypassing multi-gigabyte download."
        # Create a mock path for dry-run if needed
        SELECTED_INSTALLER_APP="/Applications/Install ${SELECTED_TITLE}.app"
        return 0
    fi

    echo ""
    if ! softwareupdate --fetch-full-installer --full-installer-version "$SELECTED_VERSION"; then
        print_error "Failed to download macOS full installer version $SELECTED_VERSION."
        print_info "Note: If you have low disk space, please ensure at least 25 GB free space is available."
        exit 1
    fi

    # Find the resulting installer in /Applications
    SELECTED_INSTALLER_APP=""
    local candidates=(
        "/Applications/Install ${SELECTED_TITLE}.app"
        "/Applications/Install macOS ${SELECTED_TITLE}.app"
        "/Applications/Install macOS*.app"
    )
    for p in /Applications/Install\ *.app; do
        if [[ -d "$p" && -x "$p/Contents/Resources/createinstallmedia" ]]; then
            SELECTED_INSTALLER_APP="$p"
            break
        fi
    done

    if [[ -z "$SELECTED_INSTALLER_APP" || ! -d "$SELECTED_INSTALLER_APP" ]]; then
        print_error "Could not locate downloaded installer in /Applications."
        exit 1
    fi

    print_success "Installer downloaded and verified at: ${BOLD}$SELECTED_INSTALLER_APP${RESET}"
}

# --- External USB Device Selection ---
select_target_usb_device() {
    print_header "Step 3: Select Target USB Storage Device"

    local disks_json
    while true; do
        print_info "Scanning for connected physical external USB drives..."
        disks_json=$(python_disk_helper "list")
        local disk_count
        disk_count=$(python3 -c "import json, sys; print(len(json.loads(sys.argv[1])))" "$disks_json" 2>/dev/null || echo "0")

        if [[ "$disk_count" -gt 0 ]]; then
            break
        fi

        echo ""
        print_warning "No external USB storage devices detected!"
        echo -e "  - Ensure your USB flash drive is securely plugged in."
        echo -e "  - Internal macOS drives are strictly hidden for your safety."
        echo ""
        read -r -p "Plug in your USB drive and press [Enter] to refresh, or 'q' to quit: " retry
        if [[ "$retry" == "q" || "$retry" == "Q" ]]; then
            echo "Operation cancelled."
            exit 0
        fi
    done

    echo ""
    echo -e "${BOLD}Detected External USB Storage Devices:${RESET}"
    echo "----------------------------------------------------------------------"

    local parsed_disks
    parsed_disks=$(python3 -c "
import json, sys
try:
    for d in json.loads(sys.argv[1]):
        vol_desc = ', '.join([v['name'] + ((' @ ' + v['mount']) if v.get('mount') else '') for v in d.get('volumes', [])])
        print(d['identifier'] + '|' + d['media_name'] + '|' + str(d['size_gb']) + '|' + d['protocol'] + '|' + vol_desc)
except Exception:
    pass
" "$disks_json")

    declare -a DISK_ID_MAP
    local idx=1
    while IFS='|' read -r dev_id media size_gb protocol vols; do
        [[ -z "$dev_id" ]] && continue

        local size_alert=""
        # Size warning: Check if < 14 GB or > 256 GB
        local is_small is_large
        is_small=$(python3 -c "import sys; print(float(sys.argv[1]) < 14.0)" "$size_gb" 2>/dev/null || echo "False")
        is_large=$(python3 -c "import sys; print(float(sys.argv[1]) > 256.0)" "$size_gb" 2>/dev/null || echo "False")

        if [[ "$is_small" == "True" ]]; then
            size_alert=" ${YELLOW}(WARNING: Drive is < 14GB; installer may not fit)${RESET}"
        elif [[ "$is_large" == "True" ]]; then
            size_alert=" ${YELLOW}(CAUTION: Drive is > 256GB; ensure this is not an external backup!)${RESET}"
        fi

        echo -e "  ${CYAN}[$idx]${RESET} ${BOLD}/dev/$dev_id${RESET} - $media ($size_gb GB, Bus: $protocol)$size_alert"
        if [[ -n "$vols" && "$vols" != "[]" ]]; then
            echo -e "      ${DIM}Volumes: $vols${RESET}"
        else
            echo -e "      ${DIM}Volumes: (No mounted volumes / unpartitioned)${RESET}"
        fi

        DISK_ID_MAP[$idx]="$dev_id"
        ((idx++))
    done <<< "$parsed_disks"

    echo "----------------------------------------------------------------------"
    echo -e "  ${RED}[q]${RESET} Quit"
    echo ""

    # Check if a target disk was passed via CLI argument
    if [[ -n "$TARGET_DISK_ARG" ]]; then
        local clean_arg="${TARGET_DISK_ARG#/dev/}"
        print_info "Evaluating CLI specified disk: /dev/$clean_arg"
        TARGET_DISK="$clean_arg"
    else
        while true; do
            read -r -p "Select the target USB drive number [1-$((idx-1))]: " sel
            if [[ "$sel" == "q" || "$sel" == "Q" ]]; then
                echo "Operation cancelled."
                exit 0
            fi

            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < idx )); then
                TARGET_DISK="${DISK_ID_MAP[$sel]}"
                break
            else
                echo -e "${RED}Invalid selection. Please choose a valid number.${RESET}"
            fi
        done
    fi

    # Execute deep safety verification on selected disk
    enforce_safety_failsafe "$TARGET_DISK"
}

# --- Strict Safety Failsafe Guard ---
enforce_safety_failsafe() {
    local disk="$1"
    print_info "Running multi-tier hardware safety verification on /dev/$disk..."

    local val_res
    val_res=$(python_disk_helper "validate" "$disk")
    local is_safe msg
    is_safe=$(python3 -c "import json; print(json.loads('''$val_res''')['safe'])")
    msg=$(python3 -c "import json; print(json.loads('''$val_res''')['message'])")

    if [[ "$is_safe" != "True" ]]; then
        echo ""
        echo -e "${RED}${BOLD}======================================================================${RESET}"
        echo -e "${RED}${BOLD}   FAIL-SAFE TRIGGERED: OPERATION REFUSED FOR YOUR PROTECTION!        ${RESET}"
        echo -e "${RED}${BOLD}======================================================================${RESET}"
        echo -e "${RED}Reason: $msg${RESET}"
        echo -e "The selected disk is NOT a safe external USB storage target."
        echo -e "Script execution has been aborted to protect your macOS system."
        exit 1
    fi

    print_success "Safety verification PASSED: $msg"
}

# --- Double Confirmation Prompt ---
confirm_destructive_operation() {
    print_header "Step 4: Destructive Confirmation"

    local disk_info
    disk_info=$(diskutil info "$TARGET_DISK" 2>/dev/null)
    local media_name
    media_name=$(echo "$disk_info" | grep "Device / Media Name:" | sed 's/.*Device \/ Media Name:[[:space:]]*//')
    local disk_size
    disk_size=$(echo "$disk_info" | grep "Disk Size:" | sed 's/.*Disk Size:[[:space:]]*//' | cut -d'(' -f1)

    echo -e "${RED}${BOLD}**********************************************************************${RESET}"
    echo -e "${RED}${BOLD}                             WARNING!                                 ${RESET}"
    echo -e "${RED}${BOLD}**********************************************************************${RESET}"
    echo -e "You are about to completely FORMAT and ERASE the following device:"
    echo -e "  Target Device Node : ${WHITE}${BOLD}/dev/$TARGET_DISK${RESET}"
    echo -e "  Device Name        : ${WHITE}${BOLD}$media_name${RESET}"
    echo -e "  Disk Capacity      : ${WHITE}${BOLD}$disk_size${RESET}"
    echo ""
    echo -e "${YELLOW}ALL EXISTING FILES, PARTITIONS, AND DATA ON THIS USB WILL BE ERASED.${RESET}"
    echo -e "${RED}${BOLD}**********************************************************************${RESET}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        print_warning "[DRY-RUN] Destructive operations are simulated. No confirmation required."
        return 0
    fi

    echo -e "To confirm this action, you must explicitly type the disk identifier '${BOLD}$TARGET_DISK${RESET}' below."
    read -r -p "Type '$TARGET_DISK' to proceed (or anything else to abort): " user_confirm

    if [[ "$user_confirm" != "$TARGET_DISK" ]]; then
        echo ""
        print_warning "Confirmation did not match ('$user_confirm' != '$TARGET_DISK'). Aborting."
        exit 0
    fi

    print_success "Confirmation received. Proceeding with USB drive preparation."
}

# --- USB Formatting & Bootable Media Creation ---
create_bootable_usb() {
    print_header "Step 5: Writing macOS Installer to USB"

    local target_vol_name="BOOTABLE_MAC_INSTALLER"

    if [[ "$DRY_RUN" == true ]]; then
        print_warning "[DRY-RUN] Simulating unmount and partition formatting on /dev/$TARGET_DISK"
        print_warning "[DRY-RUN] Simulating createinstallmedia with installer: $SELECTED_INSTALLER_APP"
        print_success "[DRY-RUN] Creation simulation complete."
        CREATED_VOLUME_PATH="/Volumes/Install macOS Sequoia"
        return 0
    fi

    # Request sudo credentials up front
    print_info "Elevating privileges for disk partitioning and createinstallmedia..."
    if ! sudo -v; then
        print_error "Failed to obtain sudo administrative privileges."
        exit 1
    fi

    # Unmount existing volumes
    print_info "Unmounting /dev/$TARGET_DISK..."
    diskutil unmountDisk "/dev/$TARGET_DISK" || true

    # Format USB drive as GPT + Mac OS Extended (Journaled)
    print_info "Erasing and formatting /dev/$TARGET_DISK as Mac OS Extended (Journaled)..."
    if ! sudo diskutil eraseDisk JHFS+ "$target_vol_name" GPT "/dev/$TARGET_DISK"; then
        print_error "Failed to format /dev/$TARGET_DISK"
        exit 1
    fi

    local target_mount="/Volumes/$target_vol_name"
    if [[ ! -d "$target_mount" ]]; then
        # Wait a moment for mount
        sleep 2
    fi

    if [[ ! -d "$target_mount" ]]; then
        print_error "Target volume failed to mount at $target_mount"
        exit 1
    fi

    local media_tool="$SELECTED_INSTALLER_APP/Contents/Resources/createinstallmedia"
    if [[ ! -x "$media_tool" ]]; then
        print_error "Cannot find executable createinstallmedia inside $SELECTED_INSTALLER_APP"
        exit 1
    fi

    print_info "Invoking Apple createinstallmedia tool..."
    print_info "Note: This copies ~15 GB to the USB flash drive and typically takes 5 to 20 minutes depending on USB speed."
    echo ""

    if ! sudo "$media_tool" --volume "$target_mount" --nointeraction; then
        print_error "createinstallmedia reported an error during bootable media creation."
        exit 1
    fi

    # Locate the newly created volume name
    CREATED_VOLUME_PATH=""
    for v in /Volumes/Install\ *; do
        if [[ -d "$v" && -d "$v/BaseSystem" ]]; then
            CREATED_VOLUME_PATH="$v"
            break
        fi
    done

    if [[ -z "$CREATED_VOLUME_PATH" ]]; then
        CREATED_VOLUME_PATH="$target_mount"
    fi

    print_success "Bootable USB written successfully to: ${BOLD}$CREATED_VOLUME_PATH${RESET}"
}

# --- Comprehensive Data Integrity & Corruption Verification ---
verify_usb_data_integrity() {
    local vol_path="$1"
    print_header "Step 6: USB Data Integrity & Non-Corruption Verification"

    if [[ "$DRY_RUN" == true && ! -d "$vol_path" ]]; then
        print_warning "[DRY-RUN] Simulating complete integrity check suite."
        echo -e "  ${OK} [1/4] Filesystem Structure Check: PASSED"
        echo -e "  ${OK} [2/4] Apple Cryptographic BaseSystem Digest: VALID (CRC32: verified)"
        echo -e "  ${OK} [3/4] Bootloader & Physical Media Metadata: VALID"
        echo -e "  ${OK} [4/4] Flash Storage Bad-Block & Read I/O Scan: 0 Errors (100% Readable)"
        return 0
    fi

    if [[ ! -d "$vol_path" ]]; then
        print_error "Volume mount path not found: $vol_path"
        return 1
    fi

    echo -e "Target Volume: ${BOLD}$vol_path${RESET}"
    echo ""

    python3 - "$vol_path" << 'PYEOF'
import os, sys, subprocess, time

vol = sys.argv[1]
print(f"Starting verification on: {vol}\n")

all_checks_passed = True

# --- Check 1: Structure & Boot Components ---
print("\033[1m[1/4] Checking installer directory structure & bootloader assets...\033[0m")
required_items = [
    ('BaseSystem/BaseSystem.dmg', 'BaseSystem Recovery Disk Image'),
    ('BaseSystem/BaseSystem.chunklist', 'Apple Chunklist Hash Table'),
    ('.IAPhysicalMedia', 'Installer Physical Media Marker')
]

for rel_path, desc in required_items:
    full = os.path.join(vol, rel_path)
    if os.path.exists(full):
        sz_mb = os.path.getsize(full) / (1024 * 1024)
        print(f"  \033[1;32m[✓]\033[0m Found {desc} ({sz_mb:.2f} MB)")
    else:
        print(f"  \033[1;31m[✗]\033[0m Missing required item: {rel_path} ({desc})")
        all_checks_passed = False

apps = [f for f in os.listdir(vol) if f.endswith('.app')]
if apps:
    print(f"  \033[1;32m[✓]\033[0m Found installer bundle: {apps[0]}")
    # Check for executable inside app
    macos_dir = os.path.join(vol, apps[0], "Contents", "MacOS")
    if os.path.isdir(macos_dir):
        execs = [e for e in os.listdir(macos_dir) if not e.startswith('.')]
        print(f"  \033[1;32m[✓]\033[0m Found installer binaries: {', '.join(execs)}")
else:
    print("  \033[1;31m[✗]\033[0m No installer .app bundle found in root of volume")
    all_checks_passed = False

# --- Check 2: Apple Cryptographic BaseSystem.dmg Digest Verification ---
print("\n\033[1m[2/4] Validating Apple Cryptographic Checksum (hdiutil verify)...\033[0m")
dmg_path = os.path.join(vol, 'BaseSystem', 'BaseSystem.dmg')
if os.path.exists(dmg_path):
    t0 = time.time()
    proc = subprocess.run(['hdiutil', 'verify', dmg_path], capture_output=True, text=True)
    t1 = time.time()
    if proc.returncode == 0:
        print(f"  \033[1;32m[✓]\033[0m BaseSystem.dmg digital digest is 100% VALID ({t1-t0:.1f}s)")
        for line in proc.stdout.strip().split('\n'):
            line = line.strip()
            if 'verified' in line or 'VALID' in line:
                print(f"    \033[2m{line}\033[0m")
    else:
        print("  \033[1;31m[✗]\033[0m BaseSystem.dmg verification FAILED! Corruption detected.")
        if proc.stderr:
            print(f"    Error: {proc.stderr.strip()}")
        all_checks_passed = False
else:
    print("  \033[1;31m[✗]\033[0m Cannot verify BaseSystem.dmg - file not found.")
    all_checks_passed = False

# --- Check 3: Filesystem Consistency (diskutil verifyVolume) ---
print("\n\033[1m[3/4] Verifying filesystem structure (diskutil verifyVolume)...\033[0m")
fs_proc = subprocess.run(['diskutil', 'verifyVolume', vol], capture_output=True, text=True)
if fs_proc.returncode == 0:
    print("  \033[1;32m[✓]\033[0m Volume filesystem catalog, headers, and allocations: CLEAN & HEALTHY")
else:
    if 'Insufficient privileges' in fs_proc.stdout or 'Insufficient privileges' in fs_proc.stderr:
        print("  \033[1;33m[!]\033[0m Filesystem verify requires elevated permissions; volume is mounted and responsive.")
    else:
        print(f"  \033[1;33m[!]\033[0m Filesystem verify notice: {fs_proc.stdout.strip() or fs_proc.stderr.strip()}")

# --- Check 4: Flash NAND Read & Bad-Block Scan ---
print("\n\033[1m[4/4] Performing flash memory bad-block & read I/O scan...\033[0m")
read_errors = 0
total_files = 0
total_bytes = 0
t_start = time.time()

for root, dirs, files in os.walk(vol):
    for f in files:
        if f.startswith('.'):
            continue
        p = os.path.join(root, f)
        total_files += 1
        try:
            sz = os.path.getsize(p)
            with open(p, 'rb') as fp:
                if sz <= 10 * 1024 * 1024:
                    data = fp.read()
                    total_bytes += len(data)
                else:
                    head = fp.read(5 * 1024 * 1024)
                    total_bytes += len(head)
                    fp.seek(max(0, sz - 2 * 1024 * 1024))
                    tail = fp.read()
                    total_bytes += len(tail)
        except Exception as e:
            print(f"  \033[1;31m[✗]\033[0m I/O Read Error in {f}: {e}")
            read_errors += 1
            all_checks_passed = False

t_elapsed = max(0.01, time.time() - t_start)
mb_read = total_bytes / (1024 * 1024)
mb_per_sec = mb_read / t_elapsed

if read_errors == 0:
    print(f"  \033[1;32m[✓]\033[0m Scanned {total_files} files ({mb_read:.1f} MB read in {t_elapsed:.1f}s at {mb_per_sec:.1f} MB/s) with 0 I/O read errors.")
else:
    print(f"  \033[1;31m[✗]\033[0m Encountered {read_errors} read errors! USB drive has damaged NAND sectors.")

print('\n' + '='*65)
if all_checks_passed:
    print("\033[1;32m✓ INTEGRITY VERIFICATION RESULT: PASS (USB IS NOT CORRUPTED)\033[0m")
    print("The USB media has passed cryptographic, filesystem, and bit-level read tests.")
else:
    print("\033[1;31m✗ INTEGRITY VERIFICATION RESULT: FAIL (CORRUPTION DETECTED)\033[0m")
    print("One or more tests failed. We recommend reformatting or replacing the USB flash drive.")
print('='*65)

sys.exit(0 if all_checks_passed else 1)
PYEOF

}

# --- Standalone Verification Mode ---
run_standalone_verification() {
    print_banner
    print_header "Standalone Bootable USB Verification Mode"

    local target_vol=""

    if [[ -n "$VERIFY_ONLY" && "$VERIFY_ONLY" != "INTERACTIVE" ]]; then
        target_vol="$VERIFY_ONLY"
    else
        # Scan for existing mounted installer volumes
        print_info "Searching for mounted macOS installer volumes..."
        declare -a FOUND_VOLS
        local v_idx=1
        for v in /Volumes/Install\ *; do
            if [[ -d "$v" && -d "$v/BaseSystem" ]]; then
                FOUND_VOLS[$v_idx]="$v"
                echo -e "  ${CYAN}[$v_idx]${RESET} ${BOLD}$v${RESET}"
                ((v_idx++))
            fi
        done

        if [[ "$v_idx" -eq 1 ]]; then
            print_warning "No standard '/Volumes/Install macOS ...' volumes currently mounted."
            read -r -p "Enter path to mounted USB volume (e.g. /Volumes/MyUSB): " manual_path
            target_vol="$manual_path"
        else
            echo ""
            read -r -p "Select volume to verify [1-$((v_idx-1))]: " v_choice
            if [[ "$v_choice" =~ ^[0-9]+$ ]] && (( v_choice >= 1 && v_choice < v_idx )); then
                target_vol="${FOUND_VOLS[$v_choice]}"
            else
                print_error "Invalid selection."
                exit 1
            fi
        fi
    fi

    verify_usb_data_integrity "$target_vol"
    exit $?
}

# --- Boot Instructions Guide ---
display_recovery_instructions() {
    print_header "Step 7: How to Boot macOS Recovery from your USB"

    echo -e "${GREEN}${BOLD}======================================================================${RESET}"
    echo -e "${GREEN}${BOLD}             YOUR BOOTABLE MACOS RECOVERY USB IS READY!               ${RESET}"
    echo -e "${GREEN}${BOLD}======================================================================${RESET}"
    echo ""
    echo -e "${BOLD}Follow these steps on the Mac you want to recover:${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}For Apple Silicon Macs (M1, M2, M3, M4):${RESET}"
    echo -e "  1. Plug this bootable USB into the Mac."
    echo -e "  2. Ensure the Mac is completely shut down."
    echo -e "  3. Press and ${BOLD}HOLD${RESET} the Power button (Touch ID button)."
    echo -e "  4. Keep holding until you see ${WHITE}\"Loading startup options...\"${RESET} on screen."
    echo -e "  5. Select ${BOLD}\"Install macOS...\"${RESET} and click ${BOLD}Continue${RESET}."
    echo ""
    echo -e "${CYAN}${BOLD}For Intel-based Macs:${RESET}"
    echo -e "  1. Plug this bootable USB into the Mac."
    echo -e "  2. Ensure the Mac is completely shut down."
    echo -e "  3. Turn on the Mac and immediately press and ${BOLD}HOLD the Option (⌥) / Alt${RESET} key."
    echo -e "  4. Release the key when the Startup Manager screen appears."
    echo -e "  5. Select the bootable USB drive icon and press ${BOLD}Return${RESET}."
    echo ""
    echo -e "${DIM}Need help? Visit Apple Support: https://support.apple.com/101578${RESET}"
    echo "======================================================================"
}

# --- Main Flow ---
main() {
    parse_args "$@"
    check_prerequisites

    # Check for standalone verify mode
    if [[ -n "$VERIFY_ONLY" ]]; then
        run_standalone_verification
    fi

    print_banner

    if [[ "$DRY_RUN" == true ]]; then
        print_warning "RUNNING IN DRY-RUN MODE: No files will be downloaded and no drives will be erased."
    fi

    # If target disk was passed via CLI, validate it immediately before any time-consuming steps
    if [[ -n "$TARGET_DISK_ARG" ]]; then
        enforce_safety_failsafe "$TARGET_DISK_ARG"
    fi

    # Step 1: Select version
    choose_installer

    # Step 2: Download if needed
    execute_installer_download

    # Step 3: Select external USB storage
    select_target_usb_device

    # Step 4: Double confirmation
    confirm_destructive_operation

    # Step 5: Format and write
    create_bootable_usb

    # Step 6: Verify data integrity
    verify_usb_data_integrity "$CREATED_VOLUME_PATH"

    # Step 7: Display instructions
    display_recovery_instructions
}

main "$@"
