#!/vendor/bin/sh

idme_device_type_id=`/vendor/bin/cat /proc/idme/device_type_id`
echo "devcfg: device_type_id: $idme_device_type_id" > /dev/kmsg

#Rhodes
case "$idme_device_type_id" in
    "A1EIANJ7PNB0Q7" )
        /vendor/bin/setprop ro.vendor.nrdp.modelgroup FTVESHOW2022
        /vendor/bin/setprop ro.vendor.nrdp.validation ninja_8
        /vendor/bin/setprop ro.vendor.nrdp.audio.mixer.buffersize 1024
        ;;
        *)
        echo "devcfg: unknown device_type_id - $idme_device_type_id" > /dev/kmsg
        ;;
esac
