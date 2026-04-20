#!/system/bin/sh
if ! applypatch -c EMMC:/dev/block/recovery:16873472:a64e0bad6571cdaad561c64815b6e83837d29653; then
  applypatch  EMMC:/dev/block/boot:11640832:fd58abc2605c60f462ddf5f66f9dbb74866dc89f EMMC:/dev/block/recovery af0a580abc2eea709cdd26aceace53bb75e1b08c 16871424 fd58abc2605c60f462ddf5f66f9dbb74866dc89f:/system/recovery-from-boot.p && installed=1 && log -t recovery "Installing new recovery image: succeeded" || log -t recovery "Installing new recovery image: failed"
  [ -n "$installed" ] && dd if=/system/recovery-sig of=/dev/block/recovery bs=1 seek=16871424 && sync && log -t recovery "Install new recovery signature: succeeded" || log -t recovery "Installing new recovery signature: failed"
else
  log -t recovery "Recovery image already installed"
fi
