#!/bin/bash
# test-bayer-modes.sh — Test OV02E10 bayer pattern fix modes
#
# Cycles through window_offset_mode values 0-4, reloading the ov02e10
# driver each time and launching qcam for visual inspection.
#
# Usage: sudo ./test-bayer-modes.sh
#
# For each mode, check if colors look correct in qcam:
#   - Hold up colored objects (red, green, blue, yellow, white)
#   - Compare to what you see with your eyes
#   - If colors match reality = that mode works!
#
# Note: The image will be right-side-up (rotation=180 from ipu-bridge-fix
# is still active). If you see correct colors AND right-side-up = success.

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# Check if ov02e10-bayer-fix DKMS is installed
if ! dkms status ov02e10-bayer-fix/1.0 2>/dev/null | grep -q "installed"; then
    echo "ERROR: ov02e10-bayer-fix DKMS module not installed."
    echo ""
    echo "Install it first:"
    echo "  sudo cp -r /path/to/ov02e10-bayer-fix /usr/src/ov02e10-bayer-fix-1.0"
    echo "  sudo dkms install ov02e10-bayer-fix/1.0"
    exit 1
fi

MODE_DESCRIPTIONS=(
    "Mode 0: No window adjustment (baseline — MODIFY_LAYOUT removal only)"
    "Mode 1: B(0x44:45) +1 on hflip, A(0x42:43) +1 on vflip"
    "Mode 2: A(0x42:43) +1 on hflip, B(0x44:45) +1 on vflip"
    "Mode 3: B+C +1 on hflip, A+D +1 on vflip (both start+end)"
    "Mode 4: A+D +1 on hflip, B+C +1 on vflip (opposite of mode 3)"
)

QCAM_PID=""

cleanup() {
    if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
        kill "$QCAM_PID" 2>/dev/null
        wait "$QCAM_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "=============================================="
echo "  OV02E10 Bayer Pattern Fix — Mode Tester"
echo "=============================================="
echo ""
echo "This will cycle through 5 window offset modes (0-4)."
echo "For each mode, qcam will open so you can check colors."
echo ""
echo "What to look for:"
echo "  - Hold up RED, GREEN, BLUE, YELLOW, WHITE objects"
echo "  - Do colors on screen match reality?"
echo "  - Mode 0 = baseline (probably still purple)"
echo "  - Modes 1-4 = experimental fixes"
echo ""
echo "Press Enter to start..."
read -r _

RESULTS=()

for mode in 0 1 2 3 4; do
    echo ""
    echo "=============================================="
    echo "  ${MODE_DESCRIPTIONS[$mode]}"
    echo "=============================================="

    # Kill qcam if running
    if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
        kill "$QCAM_PID" 2>/dev/null
        wait "$QCAM_PID" 2>/dev/null || true
        sleep 1
    fi

    # Reload driver with new mode
    echo "  Reloading ov02e10 with window_offset_mode=$mode..."
    modprobe -r ov02e10 2>/dev/null || true
    sleep 1
    modprobe ov02e10 window_offset_mode=$mode
    sleep 2

    # Launch qcam as the real user with their display session
    REAL_USER="${SUDO_USER:-$USER}"
    REAL_UID=$(id -u "$REAL_USER")
    echo "  Launching qcam..."
    su "$REAL_USER" -c "
        export DISPLAY=${DISPLAY:-:0}
        export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
        export XDG_RUNTIME_DIR=/run/user/$REAL_UID
        export XAUTHORITY=${XAUTHORITY:-/home/$REAL_USER/.Xauthority}
        qcam
    " &
    QCAM_PID=$!
    sleep 3

    echo ""
    echo "  Look at the qcam window. Do the colors look correct?"
    echo ""
    read -r -p "  Rate this mode (g=good/correct, b=bad/wrong, s=skip): " rating

    case "$rating" in
        g|G) RESULTS+=("Mode $mode: GOOD") ;;
        b|B) RESULTS+=("Mode $mode: BAD") ;;
        *)   RESULTS+=("Mode $mode: SKIPPED") ;;
    esac
done

# Kill final qcam
if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
    kill "$QCAM_PID" 2>/dev/null
    wait "$QCAM_PID" 2>/dev/null || true
fi

echo ""
echo "=============================================="
echo "  Results Summary"
echo "=============================================="
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""
echo "Please report these results in the GitHub issue!"
echo "Also mention your kernel version: $(uname -r)"
echo ""

# Check dmesg for any errors
echo "Recent ov02e10 kernel messages:"
dmesg | grep -i ov02e10 | tail -10
echo ""
