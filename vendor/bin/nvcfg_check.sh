#!/system/bin/sh

ret=0

cat /proc/mounts | grep "/dev/block/nvcfg"
ret=$?
if [ $ret -ne 0 ]; then
	mkfs.ext4 -d /mnt/vendor/nvcfg /dev/block/nvcfg
	setprop nvcfg.need_remount 1
fi

