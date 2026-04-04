{ config, lib, pkgs, ... }:

let
  kernelPackages = config.boot.kernelPackages;

  cameraRelayMonitor = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay-monitor";
    version = "1.0";

    src = ../camera-relay;

    nativeBuildInputs = [ pkgs.gcc ];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      gcc -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
    '';

    installPhase = ''
      install -Dm755 camera-relay-monitor $out/bin/camera-relay-monitor
    '';

    meta = with lib; {
      description = "Camera relay monitor for Samsung Galaxy Book4 webcam fix";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  cameraRelayRuntimeInputs = with pkgs; [
    bash
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    kmod
    procps
    systemd
    util-linux
    libcamera
    pipewire
    v4l-utils
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
  ];

  cameraRelay = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay";
    version = "1.0";

    src = ../camera-relay;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    dontConfigure = true;
    dontFixup = true;

    installPhase = ''
      install -Dm755 camera-relay $out/share/camera-relay/camera-relay

      substituteInPlace $out/share/camera-relay/camera-relay \
        --replace "/usr/local/bin/camera-relay-monitor" "${cameraRelayMonitor}/bin/camera-relay-monitor" \
        --replace "/usr/local/bin/camera-relay" "$out/bin/camera-relay"

      mkdir -p $out/bin
      makeWrapper $out/share/camera-relay/camera-relay $out/bin/camera-relay \
        --set PATH ${lib.makeBinPath cameraRelayRuntimeInputs}
    '';

    meta = with lib; {
      description = "On-demand libcamera to v4l2loopback relay for Samsung Galaxy Book4";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  ivscModules = [
    "mei-vsc"
    "mei-vsc-hw"
    "ivsc-ace"
    "ivsc-csi"
  ];

  wireplumberLuaRule = ''
    -- Disable raw Intel IPU6 ISYS V4L2 nodes in PipeWire.
    -- The camera is accessed through the libcamera SPA plugin instead.
    rule = {
      matches = {
        {
          { "node.name", "matches", "v4l2_input.pci-0000_00_05*" },
        },
      },
      apply_properties = {
        ["node.disabled"] = true,
      },
    }
    table.insert(v4l2_monitor.rules, rule)
  '';

  wireplumberConfRule = ''
    # Disable raw Intel IPU6 ISYS V4L2 nodes in PipeWire.
    # The camera is accessed through the libcamera SPA plugin instead.
    monitor.v4l2.rules = [
      {
        matches = [
          { node.name = "~v4l2_input.pci-0000_00_05*" }
        ]
        actions = {
          update-props = {
            node.disabled = true
          }
        }
      }
    ]
  '';
in
{
  boot.initrd.kernelModules = ivscModules;
  boot.extraModulePackages = [ kernelPackages.v4l2loopback ];

  environment.systemPackages = [ cameraRelay ];

  environment.etc."modules-load.d/ivsc.conf".text = lib.concatStringsSep "\n" ivscModules + "\n";
  environment.etc."modprobe.d/ivsc-camera.conf".text = ''
    # Ensure IVSC modules are loaded before the camera sensor probes.
    # Without this, ov02c10 hits -EPROBE_DEFER and may fail to bind.
    softdep ov02c10 pre: mei-vsc mei-vsc-hw ivsc-ace ivsc-csi
  '';
  environment.etc."modprobe.d/99-camera-relay-loopback.conf".text = ''
    options v4l2loopback devices=1 exclusive_caps=0 card_label="Camera Relay"
  '';

  environment.etc."wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua".text = wireplumberLuaRule;
  environment.etc."wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf".text = wireplumberConfRule;

  systemd.user.services.camera-relay = {
    description = "Camera Relay (on-demand libcamera to v4l2loopback)";
    after = [ "pipewire.service" "wireplumber.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${cameraRelay}/bin/camera-relay start --on-demand";
      ExecStop = "${cameraRelay}/bin/camera-relay stop";
      Restart = "on-failure";
      RestartSec = 5;
    };
    environment = {
      LIBCAMERA_IPA_MODULE_PATH = "${pkgs.libcamera}/lib/libcamera/ipa";
      GST_PLUGIN_PATH = lib.makeSearchPath "lib/gstreamer-1.0" [
        pkgs.libcamera
        pkgs.gst_all_1.gst-plugins-base
        pkgs.gst_all_1.gst-plugins-good
        pkgs.gst_all_1.gst-plugins-bad
      ];
      LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.libcamera ];
    };
  };
}