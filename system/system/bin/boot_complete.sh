#!/system/bin/sh

/system/bin/setprop sys.audio.bootanim "stopped"
echo "boot_complete:  ${sys.audio.bootanim}" > /dev/kmsg

