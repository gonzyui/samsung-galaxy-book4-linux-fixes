#!/bin/bash
# dump-registers.sh — Dump OV02E10 sensor registers for debugging
#
# Loads the ov02e10 driver with dump_regs=1, opens qcam to trigger
# streaming (which triggers the register dump), then extracts the
# dump from dmesg.
#
# Usage: sudo ./dump-registers.sh
#
# The register dump shows ALL registers on ALL pages AFTER mode init
# and flip controls are applied. This lets us see exactly which
# registers change when flip is on vs off.
#
# Output is saved to ov02e10-regdump.txt in the current directory.

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_UID=$(id -u "$REAL_USER")
OUTPUT="ov02e10-regdump-$(date +%Y%m%d-%H%M%S).txt"

echo "=============================================="
echo "  OV02E10 Register Dump Tool"
echo "=============================================="
echo ""

# Check current flip state
echo "  Checking current driver state..."
HFLIP=$(cat /sys/class/video4linux/*/device/driver/*/video4linux/*/name 2>/dev/null | head -1 || echo "unknown")
echo "  Output file: $OUTPUT"
echo ""

# Record kernel info
{
    echo "=== OV02E10 Register Dump ==="
    echo "Date: $(date)"
    echo "Kernel: $(uname -r)"
    echo "DKMS status:"
    dkms status 2>/dev/null | grep -E "(ov02e10|ipu-bridge)" || echo "  (none found)"
    echo ""
} > "$OUTPUT"

# Clear dmesg marker
dmesg -c > /dev/null 2>&1 || true
MARKER="OV02E10_DUMP_$(date +%s)"
echo "$MARKER" > /dev/kmsg 2>/dev/null || true

# Reload driver with dump_regs enabled and window_offset_mode=0
echo "  Reloading ov02e10 with dump_regs=1..."
modprobe -r ov02e10 2>/dev/null || true
sleep 1
modprobe ov02e10 dump_regs=1 window_offset_mode=0
sleep 2

# Launch qcam to trigger stream start (which triggers the dump)
echo "  Launching qcam to trigger register dump..."
echo "  (Camera will open briefly, then close automatically)"
echo ""

su "$REAL_USER" -c "
    export DISPLAY=${DISPLAY:-:0}
    export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
    export XDG_RUNTIME_DIR=/run/user/$REAL_UID
    export XAUTHORITY=${XAUTHORITY:-/home/$REAL_USER/.Xauthority}
    timeout 5 qcam 2>/dev/null || true
" &
QCAM_PID=$!

# Wait for qcam to start streaming and dump to complete
sleep 6
kill "$QCAM_PID" 2>/dev/null || true
wait "$QCAM_PID" 2>/dev/null || true

# Extract register dump from dmesg
echo "  Extracting register dump from dmesg..."
{
    echo "=== Register dump (with current flip state) ==="
    echo ""
    dmesg | grep -A1000 "OV02E10 REGISTER DUMP" | grep -B1 -A1000 "DUMP\|REGISTER DUMP\|END REGISTER" | head -300
    echo ""
} >> "$OUTPUT"

# Reload without dump to clean up
modprobe -r ov02e10 2>/dev/null || true
sleep 1
modprobe ov02e10 window_offset_mode=0
sleep 1

echo ""
echo "=============================================="
echo "  Register dump saved to: $OUTPUT"
echo "=============================================="
echo ""
echo "  Please paste the contents of this file in the GitHub issue:"
echo "    cat $OUTPUT"
echo ""
echo "  Or attach the file directly to the issue."
echo ""

# Show a preview
echo "  Preview (first 30 lines of dump):"
echo "  ─────────────────────────────────"
grep "DUMP\|REGISTER DUMP\|END REGISTER" "$OUTPUT" | head -30
echo ""
