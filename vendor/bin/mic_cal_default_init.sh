#!/vendor/bin/sh

#Rhodes HVT = 4 mics
RHODES_HVT_ID="01D0000100110021"
BOARD_ID=`cat /proc/idme/board_id`

#Read Mic Calibration data from IDME
#if Mic Calibration data is zero from IDME, write deafult calibration data
defaul_mic_cal=16384

#MIC-0
miccal0=`/vendor/bin/idme print miccal.0`
if [ "$miccal0" -eq 0 ]; then
    echo "IDME miccal.0 is Zero"
    /vendor/bin/idme miccal.0 $defaul_mic_cal
else
    echo "IDME miccal.0 has valid data"
fi
#MIC-1
miccal1=`/vendor/bin/idme print miccal.1`
if [ "$miccal1" -eq 0 ]; then
    echo "IDME miccal.1 is Zero"
    /vendor/bin/idme miccal.1 $defaul_mic_cal
else
    echo "IDME miccal.1 has valid data"
fi
#MIC-2
miccal2=`/vendor/bin/idme print miccal.2`
if [ "$miccal2" -eq 0 ]; then
    echo "IDME miccal.2 is Zero"
    /vendor/bin/idme miccal.2 $defaul_mic_cal
else
    echo "IDME miccal.2 has valid data"
fi
#MIC-3
miccal3=`/vendor/bin/idme print miccal.3`
if [ "$miccal3" -eq 0 ]; then
    echo "IDME miccal.3 is Zero"
    /vendor/bin/idme miccal.3 $defaul_mic_cal
else
    echo "IDME miccal.3 has valid data"
fi
#MIC-4
miccal4=`/vendor/bin/idme print miccal.4`
if [ $BOARD_ID != $RHODES_HVT_ID ]; then
    if [ "$miccal4" -eq 0 ]; then
        echo "IDME miccal.4 is Zero"
        /vendor/bin/idme miccal.4 $defaul_mic_cal
    else
        echo "IDME miccal.4 has valid data"
    fi
fi
#MIC-5
miccal5=`/vendor/bin/idme print miccal.5`
if [ $BOARD_ID != $RHODES_HVT_ID ]; then
    if [ "$miccal5" -eq 0 ]; then
        echo "IDME miccal.5 is Zero"
        /vendor/bin/idme miccal.5 $defaul_mic_cal
    else
        echo "IDME miccal.5 has valid data"
    fi
fi

MIC_NUM=`/vendor/bin/getprop persist.asp.mic.count`
# For Rhodes HVT, set mic count to 6 if idme miccal4 and miccal5 are non-zero
if [ $BOARD_ID == $RHODES_HVT_ID ]; then
    if [ "$miccal4" -ne 0 ] && [ "$miccal5" -ne 0 ]; then
        /vendor/bin/setprop persist.asp.mic.count 6
    else
        /vendor/bin/setprop persist.asp.mic.count 4
    fi
else
#for Rhodes EVT/DVT/PVT set mic count to 6
    if [ -z "${MIC_NUM}" ]; then
        /vendor/bin/setprop persist.asp.mic.count 6
    fi
fi
