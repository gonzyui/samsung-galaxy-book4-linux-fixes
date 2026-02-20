#!/bin/bash
# tune-ccm.sh — Interactive CCM tuning tool for IPU7 cameras
# Cycles through color correction presets with live qcam preview.
#
# Usage: ./tune-ccm.sh [sensor]
#   sensor: ov02e10 (default) or ov02c10
#
# Requires: qcam (libcamera-tools), sudo access to write tuning files

set -e

SENSOR="${1:-ov02e10}"

# Find the tuning file location
TUNING_FILE=""
for dir in /usr/local/share/libcamera/ipa/simple \
           /usr/share/libcamera/ipa/simple; do
    if [[ -d "$dir" ]]; then
        TUNING_FILE="$dir/${SENSOR}.yaml"
        break
    fi
done

if [[ -z "$TUNING_FILE" ]]; then
    echo "ERROR: Could not find libcamera IPA data directory."
    echo "Make sure libcamera is installed."
    exit 1
fi

if ! command -v qcam >/dev/null 2>&1; then
    echo "ERROR: qcam not found. Install libcamera-tools first."
    echo "  Arch:   sudo pacman -S libcamera-tools"
    echo "  Fedora: sudo dnf install libcamera-tools"
    exit 1
fi

# Export IPA path in case it's a source build
for dir in /usr/local/lib/*/libcamera/ipa /usr/local/lib/libcamera/ipa \
           /usr/lib/*/libcamera/ipa /usr/lib/libcamera/ipa; do
    if [[ -d "$dir" ]]; then
        export LIBCAMERA_IPA_MODULE_PATH="$dir"
        break
    fi
done

# Back up the current tuning file
BACKUP=""
if [[ -f "$TUNING_FILE" ]]; then
    BACKUP="${TUNING_FILE}.bak.$$"
    sudo cp "$TUNING_FILE" "$BACKUP"
fi

cleanup() {
    # Kill qcam if we started it
    if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
        kill "$QCAM_PID" 2>/dev/null
        wait "$QCAM_PID" 2>/dev/null || true
    fi
    # Restore backup if user didn't explicitly save (Ctrl+C, error, etc.)
    if [[ $SELECTED -lt 0 && -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo cp "$BACKUP" "$TUNING_FILE"
        sudo rm -f "$BACKUP"
        echo ""
        echo "  Interrupted — restored original tuning file."
    fi
}
trap cleanup EXIT INT TERM

# ─── CCM Presets ───────────────────────────────────────────────
# Each preset: NAME|DESCRIPTION|YAML_CONTENT
# Rows must sum to 1.0 to preserve neutral greys.
#
# Samsung OV02E10 R↔B swap: The mainline ov02e10 driver has a bug where
# MODIFY_LAYOUT is set on flip controls but the bayer format code is never
# updated. On Samsung Book5 models (sensor mounted upside-down), libcamera
# debayers with SGRBG pattern on SGBRG data, swapping R and B channels.
# All CCM presets below have columns 1 and 3 swapped to compensate.
PRESETS=(
"No CCM (baseline)|No color correction — raw debayer + AWB only. Colors will be R/B swapped.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Adjust:
  - Agc:
..."

"R↔B swap only|Pure red/blue channel swap — fixes bayer mismatch with no other color change.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 0.0, 0.0, 1.0,
                 0.0, 1.0, 0.0,
                 1.0, 0.0, 0.0 ]
  - Adjust:
  - Agc:
..."

"R↔B swap + light boost|R/B swap with 10% saturation boost on all channels.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [-0.05, -0.05,  1.1,
                -0.05,  1.1,  -0.05,
                 1.1,  -0.05, -0.05 ]
  - Adjust:
  - Agc:
..."

"R↔B swap + medium boost|R/B swap with 20% saturation boost. Stronger color.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [-0.1, -0.1,  1.2,
                -0.1,  1.2, -0.1,
                 1.2, -0.1, -0.1 ]
  - Adjust:
  - Agc:
..."

"R↔B swap + strong boost|R/B swap with 40% saturation boost. Very vivid colors.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [-0.2, -0.2,  1.4,
                -0.2,  1.4, -0.2,
                 1.4, -0.2, -0.2 ]
  - Adjust:
  - Agc:
..."

"R↔B swap + green boost light|R/B swap with green boosted 20% more than R/B. Default preset.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [-0.025, -0.025,  1.05,
                -0.2,    1.3,   -0.1,
                 1.05,  -0.025, -0.025 ]
  - Adjust:
  - Agc:
..."

"R↔B swap + green boost medium|R/B swap with green boosted 40% more. Stronger green.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 0.0,  0.0,  1.0,
                -0.2,  1.4, -0.2,
                 1.0,  0.0,  0.0 ]
  - Adjust:
  - Agc:
..."

"R↔B swap + green boost strong|R/B swap with strong green boost. For residual color cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 0.025,  0.025, 0.95,
                -0.25,   1.5,  -0.25,
                 0.95,   0.025, 0.025 ]
  - Adjust:
  - Agc:
..."

"R↔B swap + warm correction|R/B swap with red reduced, green boosted. For warm/yellow cast.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [ 0.05,  0.05,  0.9,
                -0.2,   1.35, -0.15,
                 1.05, -0.05,  0.0 ]
  - Adjust:
  - Agc:
..."

"Arch Wiki + R↔B swap|Arch Wiki OV02C10 matrix with R/B swap applied.|# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
  - Ccm:
      ccms:
        - ct: 5000
          ccm: [-0.01, -0.02,  1.05,
                -0.03,  0.92, -0.03,
                 1.05, -0.02, -0.01 ]
  - Adjust:
  - Agc:
..."
)

# ─── Main loop ─────────────────────────────────────────────────
TOTAL=${#PRESETS[@]}
CURRENT=0
SELECTED=-1
QCAM_PID=""

echo "=============================================="
echo "  IPU7 Camera CCM Tuning Tool"
echo "=============================================="
echo ""
echo "  Sensor:  $SENSOR"
echo "  File:    $TUNING_FILE"
echo "  Presets: $TOTAL"
echo ""
echo "  Controls:"
echo "    Enter / n  →  Next preset"
echo "    p          →  Previous preset"
echo "    s          →  Save current preset and exit"
echo "    q          →  Quit without saving (restores backup)"
echo "    number     →  Jump to preset (1-${TOTAL})"
echo ""
echo "  qcam will restart for each preset (takes ~1 second)."
echo "  Position the qcam window where you can see it."
echo ""
read -r -p "Press Enter to start..." _

apply_preset() {
    local idx=$1
    local entry="${PRESETS[$idx]}"
    # Extract fields using parameter expansion (read only handles one line)
    local name="${entry%%|*}"
    local rest="${entry#*|}"
    local desc="${rest%%|*}"
    local yaml="${rest#*|}"

    echo ""
    echo "──────────────────────────────────────────────"
    echo "  [$((idx+1))/$TOTAL] $name"
    echo "  $desc"
    echo "──────────────────────────────────────────────"

    # Kill existing qcam first (must release camera before restarting)
    if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
        kill "$QCAM_PID" 2>/dev/null
        wait "$QCAM_PID" 2>/dev/null || true
        sleep 0.5  # let camera device settle after close
    fi

    # Write tuning file
    echo "$yaml" | sudo tee "$TUNING_FILE" > /dev/null
    sync  # ensure file is flushed to disk before qcam reads it

    # Launch qcam in background (stderr visible for debugging)
    qcam &
    QCAM_PID=$!

    # Give qcam time to open window and start streaming
    sleep 3
}

apply_preset $CURRENT

while true; do
    echo ""
    read -r -p "  [$((CURRENT+1))/${TOTAL}] Next(Enter/n) Prev(p) Save(s) Quit(q) Jump(1-${TOTAL}): " choice

    case "$choice" in
        ""| n | N)
            CURRENT=$(( (CURRENT + 1) % TOTAL ))
            apply_preset $CURRENT
            ;;
        p | P)
            CURRENT=$(( (CURRENT - 1 + TOTAL) % TOTAL ))
            apply_preset $CURRENT
            ;;
        s | S)
            SELECTED=$CURRENT
            break
            ;;
        q | Q)
            break
            ;;
        [0-9]*)
            if [[ "$choice" -ge 1 && "$choice" -le $TOTAL ]] 2>/dev/null; then
                CURRENT=$((choice - 1))
                apply_preset $CURRENT
            else
                echo "  Invalid number. Enter 1-${TOTAL}."
            fi
            ;;
        *)
            echo "  Unknown command: $choice"
            ;;
    esac
done

# Kill qcam
if [[ -n "$QCAM_PID" ]] && kill -0 "$QCAM_PID" 2>/dev/null; then
    kill "$QCAM_PID" 2>/dev/null
    wait "$QCAM_PID" 2>/dev/null || true
fi

echo ""
if [[ $SELECTED -ge 0 ]]; then
    name="${PRESETS[$SELECTED]%%|*}"
    echo "=============================================="
    echo "  Saved: $name"
    echo "  File:  $TUNING_FILE"
    echo "=============================================="
    echo ""
    echo "  Restart PipeWire to apply for all apps:"
    echo "    systemctl --user restart pipewire wireplumber"
    # Remove backup
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo rm -f "$BACKUP"
    fi
else
    # Restore backup
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        sudo cp "$BACKUP" "$TUNING_FILE"
        sudo rm -f "$BACKUP"
        echo "  Restored original tuning file."
    fi
    echo "  Exited without saving."
fi
