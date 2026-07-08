{ pkgs, ... }:

{
  # ALSA sequencer for capturing USB-MIDI from the piano.
  boot.kernelModules = [ "snd-seq" ];
  environment.systemPackages = [ pkgs.alsa-utils ];
}
