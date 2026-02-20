#!/bin/bash
# Uninstall the Galaxy Book5 webcam fix
# Removes DKMS module, config files, and environment settings added by install.sh
# Does NOT uninstall distro packages (libcamera, pipewire-libcamera, etc.)

set -e

VISION_DRIVER_VER="1.0.0"
SRC_DIR="/usr/src/vision-driver-${VISION_DRIVER_VER}"
IPU_BRIDGE_FIX_VER="1.0"
IPU_BRIDGE_FIX_SRC="/usr/src/ipu-bridge-fix-${IPU_BRIDGE_FIX_VER}"

echo "=============================================="
echo "  Samsung Galaxy Book5 Webcam Fix Uninstaller"
echo "=============================================="
echo ""

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# [1/9] Remove vision-driver DKMS module
echo "[1/9] Removing vision-driver DKMS module..."
if dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "vision-driver"; then
    sudo dkms remove "vision-driver/${VISION_DRIVER_VER}" --all 2>/dev/null || true
    echo "  ✓ DKMS module removed"
else
    echo "  ✓ DKMS module not installed (nothing to remove)"
fi

# [2/9] Remove vision-driver DKMS source
echo "[2/9] Removing vision-driver DKMS source..."
if [[ -d "$SRC_DIR" ]]; then
    sudo rm -rf "$SRC_DIR"
    echo "  ✓ Removed ${SRC_DIR}"
else
    echo "  ✓ Source directory not present"
fi

# [3/9] Remove ipu-bridge-fix DKMS module (camera rotation fix)
echo "[3/9] Removing ipu-bridge-fix DKMS module..."
if dkms status "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null | grep -q "ipu-bridge-fix"; then
    sudo dkms remove "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" --all 2>/dev/null || true
    echo "  ✓ DKMS module removed"
else
    echo "  ✓ DKMS module not installed (nothing to remove)"
fi
if [[ -d "$IPU_BRIDGE_FIX_SRC" ]]; then
    sudo rm -rf "$IPU_BRIDGE_FIX_SRC"
    echo "  ✓ Removed ${IPU_BRIDGE_FIX_SRC}"
fi
# Remove upstream check script and service
sudo systemctl disable ipu-bridge-check-upstream.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ipu-bridge-check-upstream.service
sudo rm -f /usr/local/sbin/ipu-bridge-check-upstream.sh
# Restore kernel's original ipu-bridge
sudo depmod -a 2>/dev/null || true

# [3b/9] Remove ov02e10-fix DKMS module (legacy — no longer installed)
echo "[3b/9] Removing ov02e10-fix DKMS module (if present from older install)..."
if dkms status "ov02e10-fix/1.0" 2>/dev/null | grep -q "ov02e10-fix"; then
    sudo dkms remove "ov02e10-fix/1.0" --all 2>/dev/null || true
    echo "  ✓ DKMS module removed"
else
    echo "  ✓ DKMS module not installed (nothing to remove)"
fi
if [[ -d "/usr/src/ov02e10-fix-1.0" ]]; then
    sudo rm -rf "/usr/src/ov02e10-fix-1.0"
    echo "  ✓ Removed /usr/src/ov02e10-fix-1.0"
fi

# [4/9] Remove modprobe config
echo "[4/9] Removing module configuration..."
sudo rm -f /etc/modprobe.d/intel-ipu7-camera.conf
# Also remove old name from earlier versions of the installer
sudo rm -f /etc/modprobe.d/intel-cvs-camera.conf
echo "  ✓ Module configuration removed"

# [5/9] Remove modules-load config
echo "[5/9] Removing module autoload configuration..."
sudo rm -f /etc/modules-load.d/intel-ipu7-camera.conf
# Also remove old name from earlier versions of the installer
sudo rm -f /etc/modules-load.d/intel-cvs.conf
echo "  ✓ Module autoload configuration removed"

# [6/9] Remove udev rules (including legacy hide rule from earlier versions)
echo "[6/9] Removing udev rules..."
sudo rm -f /etc/udev/rules.d/90-hide-ipu7-v4l2.rules
sudo udevadm control --reload-rules 2>/dev/null || true
echo "  ✓ Udev rules removed"

# [7/9] Remove WirePlumber rules
echo "[7/9] Removing WirePlumber rules..."
sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-disable-ipu7-v4l2.conf
sudo rm -f /etc/wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua
echo "  ✓ WirePlumber rules removed"

# [8/9] Remove sensor color tuning files
echo "[8/9] Removing libcamera sensor tuning files..."
for dir in /usr/local/share/libcamera/ipa/simple /usr/share/libcamera/ipa/simple; do
    for sensor in ov02e10 ov02c10; do
        if [[ -f "$dir/${sensor}.yaml" ]]; then
            sudo rm -f "$dir/${sensor}.yaml"
            echo "  ✓ Removed $dir/${sensor}.yaml"
        fi
    done
done
echo "  ✓ Sensor tuning files removed"

# [9/9] Remove environment configs
echo "[9/9] Removing environment configuration..."
sudo rm -f /etc/environment.d/libcamera-ipa.conf
sudo rm -f /etc/profile.d/libcamera-ipa.sh
echo "  ✓ Removed libcamera environment files"

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo ""
echo "  Note: Distro packages (libcamera, pipewire-libcamera, etc.) were NOT"
echo "  removed — you may need them for other purposes. Remove manually if desired."
echo ""
echo "  Reboot to fully restore the original state."
echo "=============================================="
