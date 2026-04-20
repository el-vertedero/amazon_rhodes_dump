#!/vendor/bin/sh
## Copyright (c) 2017 - 2023 Amazon.com, Inc. or its affiliates.  All rights reserved.
##
## PROPRIETARY/CONFIDENTIAL.  USE IS SUBJECT TO LICENSE TERMS.

LOGSRC="wifi"
LOGNAME="wifi_log_levels"
METRICSTAG="metrics.$LOGNAME"
LOGCATTAG="main.$LOGNAME"
DELAY=110 # every 2 minutes including 10 seconds for traffic_report and noise histogram
INTERVAL=10
LOOPSTILMETRICS=29 # Should send to metrics buffer every hour
DEFAULT_RSSI_THD="-75,-71,-68,-61"
currentLoop=0
IWPRIV=/vendor/bin/iwpriv
IFCONFIG=/vendor/bin/ifconfig
IW=/vendor/bin/iw
ARP_FILE=/proc/net/arp
TOOLBOX=/vendor/bin/toybox_vendor
noise_array=( -55 -57 -62 -67 -72 -77 -81 -84 -87 -90 -92 )
WLANINTF="Down"
CHIPNSS="2"
PREVIOUS_NOISEBAR=0
PREVIOUS_INTERFACE=""
GETPROP=/vendor/bin/getprop
SETPROP=/vendor/bin/setprop
ECHO=/vendor/bin/echo
GREP=/vendor/bin/grep
SLEEP=/vendor/bin/sleep
CAT=/vendor/bin/cat
CPU_LOAD_WEIGHT=95
SKIP_TIME_LIMIT=3
# CPU_STRING is used to get current cup load info, it's soc dependent, current path is for mt8695
CPU_STRING="/sys/devices/system/cpu/rq-stats/cpu_normalized_load"
SKIP_RX_BMC_TIME_LIMIT=30 #1 hour limit
SKIP_RX_BMC_RUN_COUNTER=0
MAX_RX_BMCCIPHERMISMATCH=0
MAX_RX_BMCICVERROR=0
MAX_RX_BMCPKT=0
MAX_TOTAL_BMC_FAILURES=0
MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE=0
# CHIPRESET_COUNTER is used to keep track of the previous status of chip reset.
# index:reason_code value:count; For each reason, its previous total occurrence count
CHIPRESET_COUNTER=( 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 )

RESTART_ENABLED=false
RESTART_THRESHOLD=0
RESTART_COUNTER=0;

source  /vendor/bin/wifi_metrics_common.sh

if [ ! -x $IWPRIV ] ; then
    exit
fi

if [ ! -x $IW ] ; then
    exit
fi

function set_wlan_interface ()
{
    WLAN_INTERFACE=`$GETPROP wifi.interface`
    WLAN_INTERFACE_UP=`$IFCONFIG | $GREP wlan`
    WLAN_STATUS=`$IW $WLAN_INTERFACE link | head -n1 | cut -d " " -f1`
    P2P_INTERFACE=`$IFCONFIG |grep p2p- |cut -d " " -f1`
    P2P_STATUS=`$IW $P2P_INTERFACE link | head -n1 | cut -d " " -f1`

    ## disable this check and use wlan0 for all stats (except ifconfig) until proper p2p stats were available
#    # check wlan and p2p connection status to decide which interface to get stats
#    if [[ ( "$WLAN_STATUS" != "Connected" ) && ( "$P2P_STATUS" = "Connected" ) ]]; then
#        WLAN_INTERFACE=$P2P_INTERFACE
#    fi
}

function iwpriv_conn_status ()
{
    IFS=$'\t\n'
    CONN_STATUS=`$IW $WLAN_INTERFACE link | head -n1 | cut -d " " -f1`
    unset IFS
}

function iwpriv_traffic_noise_report ()
{
    IFS=$'\t\n'

    # disable power saving mode
    $IWPRIV $WLAN_INTERFACE driver "SET_CHIP KeepFullPwr 1" > /dev/null

    # enable noise histogram collection
    $IWPRIV $WLAN_INTERFACE driver "noise_histogram enable" > /dev/null
#        $IWPRIV $WLAN_INTERFACE driver "noise_histogram reset" > /dev/null

    # enable traffic report
    $IWPRIV $WLAN_INTERFACE driver "traffic_report enable"  > /dev/null
#        $IWPRIV $WLAN_INTERFACE driver "traffic_report reset" > /dev/null

    # wait for $INTERVAL seconds to collect result
    $SLEEP $INTERVAL
    TRAFFIC_REPORT=($($IWPRIV $WLAN_INTERFACE driver "traffic_report get"))

    # disable traffic report
    $IWPRIV $WLAN_INTERFACE driver "traffic_report disable" > /dev/null

    # collect noise histogram
    if [ $CHIPNSS = "2" ]; then
        NOISE_HISTOGRAM=($($IWPRIV $WLAN_INTERFACE driver "noise_histogram get2"))
    else
        NOISE_HISTOGRAM=($($IWPRIV $WLAN_INTERFACE driver "noise_histogram get"))
    fi

    # disable noise histogram collection
    $IWPRIV $WLAN_INTERFACE driver "noise_histogram disable" > /dev/null

    # restore power saving mode from Android
    $IWPRIV $WLAN_INTERFACE driver "SET_CHIP KeepFullPwr 0" > /dev/null

    ((j=0))
    ((WF1_NOISE_FLAG=0))
    for line in ${NOISE_HISTOGRAM[@]}; do
        if [ $CHIPNSS = "2" ]; then
            if [ $line = *"WF1"* ]; then
                ((WF1_NOISE_FLAG=1))
            fi
        fi

        if [[ $line = *"Power"* ]]; then
            if [ $j -gt 10 ]; then
                NOISE_FLOOR2[$j-11]=${line##* }
            else
                NOISE_FLOOR[$j]=${line##* }
            fi
            ((j = j + 1))
        fi
    done

    for line in ${TRAFFIC_REPORT[@]}; do
        case $line in
            "CCK false"*)
                    CCK_ERR=${line#*: }
                    ;;
            "OFDM false"*)
                    OFDM_ERR=${line#*: }
                    ;;
            "CCK Sig"*)
                    CCK_CRC=${line#*: }
                    ;;
            "OFDM Sig"*)
                    OFDM_CRC=${line#*: }
                    ;;
            "Total packet transmitted"*)
                    TX_TOTAL=${line#*: }
                    ;;
            "Total tx ok packet"*)
                    TX_OK=${line#*: }
                    ;;
            "Total tx failed packet"*)
                    TX_FAIL=${line#*: }
                    ;;
            "Total tx retried packet"*)
                    TX_RETRY=${line#*: }
                    ;;
            "Total rx mpdu"*)
                    RX_OK=${line#*: }
                    ;;
            "Total rx fcs"*)
                    RX_FCS=${line#*: }
                    ;;
            "ch_busy"*)
                    CH_BUSY=${line#*ch_busy }
                    CH_BUSY=${CH_BUSY%% us*}
                    CH_IDLE=${line#*ch_idle }
                    CH_IDLE=${CH_IDLE%% us*}
                    CH_TOTAL=${line#*total_period }
                    CH_TOTAL=${CH_TOTAL%% us*}
                    ;;
            "my_data_rx_time"*)
                    RX_TIME=${line#*: }
                    RX_TIME=${RX_TIME%% us*}
                    RX_PERCENT=${line##*: }
                    ;;
            "my_tx_time"*)
                    TX_TIME=${line#* }
                    TX_TIME=${TX_TIME%% us*}
                    TX_PERCENT=${line##*: }
                    ;;
        esac
    done
    unset IFS
}

function ifconfig_kernel_stat ()
{
    IFS=$'\t\n'
    if [[ ( "$WLAN_STATUS" != "Connected" ) && ( "$P2P_STATUS" = "Connected" ) ]]; then
        STAT=($($IFCONFIG $P2P_INTERFACE))
    else
        STAT=($($IFCONFIG $WLAN_INTERFACE))
    fi
    for line in ${STAT[@]}; do
        $ECHO $line
        case $line in
            *"RX packets"*)
                    RXPACKETS=`$ECHO $line | cut -d ":" -f2 | cut -d " " -f1`
                    RXERRORS=`$ECHO $line | cut -d ":" -f3 | cut -d " " -f1`
                    RXDROPPED=`$ECHO $line | cut -d ":" -f4 | cut -d " " -f1`
                    ;;
            *"TX packets"*)
                    TXPACKETS=`$ECHO $line | cut -d ":" -f2 | cut -d " " -f1`
                    TXERRORS=`$ECHO $line | cut -d ":" -f3 | cut -d " " -f1`
                    TXDROPPED=`$ECHO $line | cut -d ":" -f4 | cut -d " " -f1`
                    ;;
            *"bytes"*)
                    RXBYTES=`$ECHO $line | cut -d ":" -f2 | cut -d " " -f1`
                    TXBYTES=`$ECHO $line | cut -d ":" -f3 | cut -d " " -f1`
                    ;;
        esac
    done
    unset IFS
}

function arp_check ()
{
    ##check if gateway address is valid in arp table
    GATEWAY=`$GETPROP dhcp.$WLAN_INTERFACE.gateway`
    ARP_FLAG=`$GREP "$GATEWAY " $ARP_FILE | cut -c 30-32`
    if [ -z $ARP_FLAG ]; then
        arp_flag="arp=no_entry"
    elif [ $ARP_FLAG = 0x0 ]; then
        arp_flag="arp=incomplete"
    elif [ $ARP_FLAG = 0x2 ]; then
        arp_flag="arp=complete"
    elif [ $ARP_FLAG = 0x6 ]; then
        arp_flag="arp=permanent"
    else
        arp_flag="arp=$ARP_FLAG"
    fi
}

function iwpriv_stat_tokens ()
{
    IFS=$'\t\n'
    STAT=($($IWPRIV $WLAN_INTERFACE driver stat))

    for line in ${STAT[@]}; do
        case $line in
            "Tx Total cnt"*)
                TXFRAMES=${line#*= }
                ;;
            "Tx Fail Cnt"*)
                TXFAIL=${line#*= }
                ;;
            "RX Success"*)
                RXFRAMES=${line#*= }
                ;;
            "RX with CRC"*)
                RXCRC=${line#*= }
                RXCRC=${RXCRC%%,*}
                RXPER=${line#*PER = }
                RXPER=${RXPER%%,*}
                ;;
            "RX drop FIFO full"*)
                RXDROP=${line#*= }
                ;;
            "RateTable"*)
                PHYMODE=${line#*= }
                PHYMODE=${PHYMODE%%_*}
                ;;
            "Beacon RSSI"*)
                BEACONRSSI=${line#*= }
                ;;
            "NOISE"*)
                NOISE=${line#*= }
                ;;
            "LinkSpeed"*)
                PHYRATE=${line#*= }
                ;;
            "AR TX Rate"*)
                ARTXRATE=${line#*= }
                ;;
            "Last TX Rate"*)
                TXRATE=${line#*= }
                STRING=${TXRATE#*,}
                RATE1=${TXRATE%,"$STRING"}
                RATE1+="_"
                SUBSTRING=${STRING#*,}
                BW1=`$ECHO ${STRING%,"$SUBSTRING"} | cut -d " " -f2`
                LASTTXRATE=$RATE1$BW1
                ;;
            "Chip Out TX Power"*)
                LASTTXPOWER=${line#*= }
                ;;
            "Last RX Rate"*)
                RXRATE=${line#*= }
                STRING=${RXRATE#*,}
                RATE1=${RXRATE%,"$STRING"}
                RATE1+="_"
                SUBSTRING=${STRING#*,}
                BW1=`$ECHO ${STRING%,"$SUBSTRING"} | cut -d " " -f2`
                LASTRXRATE=$RATE1$BW1
                ;;
            "Last RX Data RSSI"*)
                RSSI=${line#*= }
                ;;
            "DBDC0"*)
                TXAGG=${line#*: }
                ;;
        esac
    done

    unset IFS
}

# Rx BMC or bmc
function iwpriv_driver_get_mib () {

    # Ensure the HostAp is supported
    HostApSupported=`$GETPROP vendor.sys.hostap.support`
    if [ -z $HostApSupported ]; then
        return 0
    fi

    if (( HostApSupported == 0 )); then
        return 0
    fi

    # Ensure the HostAp is enabled or not
    HostApSsid=`$GETPROP wifi.ro.hostapd.pid`
    if [ -z $HostApSsid ]; then
        return 0
    fi

    if (( HostApSsid == 0 )); then
        clear_RX_BMC_stats
        return 0
    fi

    STAT=`$IWPRIV $WLAN_INTERFACE driver get_mib | $GREP BMC`

    if [ -z $STAT ]; then
        return 0
    fi

    IFS=$'\t\n'
    for line in ${STAT[@]}; do
        case $line in
            "Rx BMC cipher mismatch"*)
                RxBmcCipherMismatch=${line#*=}
                ;;
            "Rx BMC ICV error"*)
                RxBmcIcvError=${line#*=}
                ;;
            "Rx BMC Pkt"*)
                RxBmcPkt=${line#*=}
                ;;
        esac
    done

    logStr="RxBmcCipherMismatch=$RxBmcCipherMismatch;RxBmcIcvError=$RxBmcIcvError;RxBmcPkt=$RxBmcPkt;SKIP_RX_BMC_RUN_COUNTER=$SKIP_RX_BMC_RUN_COUNTER;"
    log -t $LOGCATTAG $logStr

    TotalBMCFailures=$(($RxBmcCipherMismatch+$RxBmcIcvError))
    BroadcastPacketsErrorPercentage=0
    if (( RxBmcPkt != 0 )); then
        BroadcastPacketsErrorPercentage=$((100*$TotalBMCFailures/$RxBmcPkt))
    fi

    # Find all the max value
    MAX_RX_BMCCIPHERMISMATCH=$(($RxBmcCipherMismatch > $MAX_RX_BMCCIPHERMISMATCH ? $RxBmcCipherMismatch : $MAX_RX_BMCCIPHERMISMATCH))
    MAX_RX_BMCICVERROR=$(($RxBmcIcvError > $MAX_RX_BMCICVERROR ? $RxBmcIcvError : $MAX_RX_BMCICVERROR))
    MAX_RX_BMCPKT=$(($RxBmcPkt > $MAX_RX_BMCPKT ? $RxBmcPkt : $MAX_RX_BMCPKT))
    MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE=$(($BroadcastPacketsErrorPercentage > $MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE ? $BroadcastPacketsErrorPercentage : $MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE))
    MAX_TOTAL_BMC_FAILURES=$(($TotalBMCFailures > $MAX_TOTAL_BMC_FAILURES ? $TotalBMCFailures : $MAX_TOTAL_BMC_FAILURES))

    logStr="MAX_RX_BMCCIPHERMISMATCH=$MAX_RX_BMCCIPHERMISMATCH;MAX_RX_BMCICVERROR=$MAX_RX_BMCICVERROR;MAX_RX_BMCPKT=$MAX_RX_BMCPKT;MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE=$MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE;MAX_TOTAL_BMC_FAILURES=$MAX_TOTAL_BMC_FAILURES"
    log -t $LOGCATTAG $logStr

    if [[ "$SKIP_RX_BMC_RUN_COUNTER" -ge "$SKIP_RX_BMC_TIME_LIMIT" ]]; then
        SKIP_RX_BMC_RUN_COUNTER=0
        logStr="Do as skipping $SKIP_RX_BMC_TIME_LIMIT times in row"
        log -t $LOGCATTAG $logStr
        #1. key: (Rx BMC cipher mismatch + Rx BMC ICV error)/(Rx BMC Pkt)
        #2. metadata: Rx BMC cipher mismatch
        #3. metadata1: Rx BMC ICV error
        #4. metadata2: (Rx BMC cipher mismatch + Rx BMC ICV error)
        if (( MAX_TOTAL_BMC_FAILURES >= 10 )) && (( MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE >= 90 )); then
            log_to_kdm_minerva "operation=BmcErrorStat;key=${MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE};metadata=${MAX_RX_BMCCIPHERMISMATCH};metadata1=${MAX_RX_BMCICVERROR};metadata2=${MAX_TOTAL_BMC_FAILURES}"
        fi
        clear_RX_BMC_stats #clear all Max value for next iteration
    fi

    ((SKIP_RX_BMC_RUN_COUNTER++))
    unset IFS
}

function clear_RX_BMC_stats () {
    MAX_RX_BMCCIPHERMISMATCH=0
    MAX_RX_BMCICVERROR=0
    MAX_RX_BMCPKT=0
    MAX_TOTAL_BMC_FAILURES=0
    MAX_BROADCAST_PACKETS_ERROR_PERCENTAGE=0
}

function get_max_signal_stats
{
    maxNoise=0
    maxNoise2=0
    maxSnr=0

    maxRssi=$BEACONRSSI
    dataRssi=${RSSI% *}

    #skip >57 dBm for now
    NOISE_FLOOR[0]=0
    NOISE_FLOOR[1]=0
    ((j=0))
    ((maxN=0))
    maxIndex=0
    for n in ${NOISE_FLOOR[@]}; do
        if (( n >= maxN )); then
            maxN=$n
            maxIndex=$j
        fi
        ((j = j + 1))
    done
    maxNoise=(`$ECHO ${noise_array[$maxIndex]}`)

    # update noise property
    $SETPROP 'vendor.wifi.wlan0.noise' $maxNoise

    if [ $CHIPNSS = "2" ]; then # second chain
        dataRssi2=${RSSI#* }
        NOISE_FLOOR2[0]=0
        NOISE_FLOOR2[1]=0
        ((j=0))
        ((maxN=0))
        maxIndex=0
        for n in ${NOISE_FLOOR2[@]}; do
            if (( n >= maxN )); then
                maxN=$n
                maxIndex=$j
            fi
            ((j = j + 1))
        done
    fi

    if [ WF1_NOISE_FLAG == 1 ]; then
        maxNoise2=(`$ECHO ${noise_array[$maxIndex]}`)
    else
        maxNoise2=$maxNoise
    fi

    if (( maxRssi != 0 && maxNoise != 0 )); then
        maxSnr=$(($maxRssi - $maxNoise))
    fi
}

function iwpriv_show_channel
{
    CHANNEL=`$IWPRIV $WLAN_INTERFACE driver get_cnm | $GREP channels | cut -d " " -f4`
}

function log_metrics_phymode
{
    if [ "$PHYMODE" ] ; then
        mode=${PHYMODE}
        logStr="$LOGSRC:$LOGNAME:WifiMode$mode=1;CT;1:NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr

        BANDWIDTH=${ARTXRATE#*BW}
        BANDWIDTH=${BANDWIDTH%%,*}"MHz"
        logStr="$LOGSRC:$LOGNAME:ChannelBandwidth$BANDWIDTH=1;CT;1:NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi
}

function log_metrics_rssi
{
    # dev rssi
    if [ "$maxRssi" -eq 0 ]; then
        return 0
    fi
    logStr="$LOGSRC:$LOGNAME:RssiLevel$maxRssi=1;CT;1:NR"
    $TOOLBOX log -m -t $METRICSTAG $logStr
}

function log_metrics_snr
{
    # dev snr
    if [ "$maxSnr" -eq 0 ]; then
        return 0
    fi
    logStr="$LOGSRC:$LOGNAME:SnrLevel$maxSnr=1;CT;1:NR"
    $TOOLBOX log -m -t $METRICSTAG $logStr
}


function log_metrics_noise
{
    # dev noise
    if [ "$maxNoise" -eq 0 ]; then
        return 0
    fi
    logStr="$LOGSRC:$LOGNAME:NoiseLevel$maxNoise=1;CT;1:NR"
    $TOOLBOX log -m -t $METRICSTAG $logStr
}


function log_metrics_mcs
{
    #dev mcs
    mcs=${LASTRXRATE/,*/}
    if [ "$mcs" ] ; then
        logStr="$LOGSRC:$LOGNAME:$mcs=1;CT;1:NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi
}


function log_connstatus_metrics
{
    if [[ $CONN_STATUS = "Connected" ]]; then
        logStr="$LOGSRC:$LOGNAME:ConnStatusConnected=1;CT;1;NR"
    else
        logStr="$LOGSRC:$LOGNAME:ConnStatusDisconnected=1;CT;1;NR"
    fi
    $TOOLBOX log -m -t $METRICSTAG $logStr
}

function log_metrics_chnstat
{
    if (( CH_TOTAL != 0 )); then
        logStr="$LOGSRC:$LOGNAME:ChanBusy$ChanBusy=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:ChanTx$ChanTx=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:ChanRx$ChanRx=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi

    if (( TX_TOTAL != 0 )); then
        logStr="$LOGSRC:$LOGNAME:TxGood$TxGood=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:TxBad$TxBad=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:TxRetry$TxRetry=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi

    if (( RX_OK != 0 )); then
        logStr="$LOGSRC:$LOGNAME:RxGood$RxGood=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
        logStr="$LOGSRC:$LOGNAME:RxBad$RxBad=1;CT;1;NR"
        $TOOLBOX log -m -t $METRICSTAG $logStr
    fi
}

function kdm_rssi_level()
{
    if [[ "$1" -lt "${RSSITHD[0]}" ]]; then
        RSSIBAR=0
    elif [[ "$1" -lt "${RSSITHD[1]}" ]]; then
        RSSIBAR=1
    elif [[ "$1" -lt "${RSSITHD[2]}" ]]; then
        RSSIBAR=2
    elif [[ "$1" -lt "${RSSITHD[3]}" ]]; then
        RSSIBAR=3
    elif [[ "$1" -lt "-40" ]]; then
        RSSIBAR=4
    elif [[ "$1" -lt "-20" ]]; then
        RSSIBAR=5
    else
        RSSIBAR=6
    fi
}

function log_kdm_rssi_level
{

    #get bandwidth
    if [ ! "$BANDWIDTH" ] ; then
        # Device is 11a/b/g which only has 20 MHz bandwidth
        BANDWIDTH="20MHz"
    fi

    kdm_rssi_level ${maxRssi}
    beacon_rssibar=$RSSIBAR

    kdm_rssi_level ${dataRssi}
    rssibar=$RSSIBAR

    ## Dual-chain metrics are only enabled on Mantis
    if [ $CHIPNSS = "2" ]; then
        kdm_rssi_level ${dataRssi2}
        rssibar2=$RSSIBAR
        log_to_kdm_minerva "operation=RSSILevel;key=${CHANNEL};metadata=${rssibar} bar;metadata1=${rssibar2} bar;metadata2=${BANDWIDTH};metadata3=Data"
    else
        log_to_kdm_minerva "operation=RSSILevel;key=${CHANNEL};metadata=${rssibar} bar;metadata2=${BANDWIDTH};metadata3=Data"
    fi

    log_to_kdm_minerva "operation=RSSILevel;key=${CHANNEL};metadata=${beacon_rssibar} bar;metadata2=${BANDWIDTH};metadata3=Beacon"
}


function kdm_noise_level()
{
    if [[ "$1" -lt "${RSSITHD[0]}" ]]; then
        NOISEBAR=0
    elif [[ "$1" -lt "${RSSITHD[1]}" ]]; then
        NOISEBAR=1
    elif [[ "$1" -lt "${RSSITHD[2]}" ]]; then
        NOISEBAR=2
    elif [[ "$1" -lt "${RSSITHD[3]}" ]]; then
        NOISEBAR=3
    elif [[ "$1" -lt "-40" ]]; then
        NOISEBAR=4
    elif [[ "$1" -lt "-20" ]]; then
        NOISEBAR=5
    else
        NOISEBAR=$PREVIOUS_NOISEBAR
    fi
    PREVIOUS_NOISEBAR=$NOISEBAR
}

function log_kdm_noise_level
{
    kdm_noise_level ${maxNoise}
    noisebar=$NOISEBAR
    TVStatus="Unknown"
    CoexFlag="Unknown"
    ## Dual-chain metrics are only enabled on Mantis
    if [ $CHIPNSS = "2" ]; then
        kdm_noise_level ${maxNoise2}
        noisebar2=$NOISEBAR
        log_to_kdm_minerva "operation=NoiseLevel;key=${CHANNEL};metadata=${noisebar} bar;metadata1=${noisebar2} bar;metadata2=${TVStatus};metadata3=${CoexFlag}"
    else
        log_to_kdm_minerva "operation=NoiseLevel;key=${CHANNEL};metadata=${noisebar} bar"
    fi
}

function kdm_snr_level()
{
    if [[ "$1" -lt "5" ]]; then
        SNRBAR=0
    elif [[ "$1" -lt "10" ]]; then
        SNRBAR=1
    elif [[ "$1" -lt "15" ]]; then
        SNRBAR=2
    elif [[ "$1" -lt "20" ]]; then
        SNRBAR=3
    elif [[ "$1" -lt "25" ]]; then
        SNRBAR=4
    elif [[ "$1" -lt "30" ]]; then
        SNRBAR=5
    else
        SNRBAR=6
    fi
}

function log_kdm_snr_level
{
    #dev mcs
    mcs=${LASTRXRATE/,*/}

    snr=$(($rssi - $maxNoise))
    kdm_snr_level ${snr}
    snrbar=$SNRBAR

    ## Dual-chain metrics are only enabled on Mantis
    if [ $CHIPNSS = "2" ]; then
        snr=$(($rssi2 - $maxNoise2))
        kdm_snr_level ${snr}
        snrbar2=$SNRBAR
        log_to_kdm_minerva "operation=SNRLevel;key=${CHANNEL};metadata=${snrbar} bar;metadata1=${rssibar} bar;metadata2=${mcs};metadata3=${snrbar2} bar"
    else
        log_to_kdm_minerva "operation=SNRLevel;key=${CHANNEL};metadata=${rssibar} bar;metadata1=${snrbar} bar;metadata2=${mcs}"
    fi
}

function log_kdm_band
{

    #get bandwidth
    if [ ! "$BANDWIDTH" ] ; then
        # Device is 11a/b/g which only has 20 MHz bandwidth
        BANDWIDTH="20MHz"
    fi

    if [[ "$PHYMODE" == "AC" ]] ; then
        wifimode="11ac"
    elif [[ "$PHYMODE" == "G" ]] ; then
        wifimode="11g"
    elif [[ "$PHYMODE" == "A" ]] ; then
        wifimode="11a"
    elif [[ "$PHYMODE" == "B" ]] ; then
        wifimode="11b"
    else
        wifimode="11n"
    fi

    log_to_kdm_minerva "operation=Band;key=${CHANNEL};metadata=${BANDWIDTH};metadata1=${wifimode}"
}

function log_kdm_phyrate
{
    log_to_kdm_minerva "operation=PhyRate;key=Tx;metadata=${LASTTXRATE};metadata1=${rssibar} bar;metadata2=${snrbar} bar;metadata3=${wifimode}"
    log_to_kdm_minerva "operation=PhyRate;key=Rx;metadata=${LASTRXRATE};metadata1=${rssibar} bar;metadata2=${snrbar} bar;metadata3=${wifimode}"
}

function log_kdm_txop
{
    log_to_kdm_minerva "operation=Txop;key=${CHANNEL};metadata=${TXOPSCALE};metadata2=${rssibar} bar"
}

function log_wifi_metrics
{
    log_metrics_rssi
    log_metrics_snr
    log_metrics_noise
    log_metrics_mcs
    log_metrics_phymode
    log_metrics_chnstat

    log_kdm_rssi_level
    log_kdm_noise_level
    log_kdm_snr_level
    log_kdm_band
    log_kdm_phyrate
    log_kdm_txop
}

function log_logcat
{
    TXPER=0
    if [[ ${TXFRAMES} -ne 0 ]] ; then
        TXPER=$((${TXFAIL} * 100 / ${TXFRAMES}))
    fi
    if [ $CHIPNSS = "2" ]; then
        logStr="$LOGNAME:$WLAN_INTERFACE:rssi=$dataRssi;rssi2=$dataRssi2;noise=$maxNoise;noise2=$maxNoise2;channel=$CHANNEL;"
    else
        logStr="$LOGNAME:$WLAN_INTERFACE:rssi=$dataRssi;noise=$maxNoise;channel=$CHANNEL;"
    fi
    logStr=$logStr"txframes=$TXFRAMES;txfails=$TXFAIL;txper=$TXPER%;"
    logStr=$logStr"txaggr=$TXAGG;"
    logStr=$logStr"rxframes=$RXFRAMES;rxcrc=$RXCRC;rxper=$RXPER;rxdrop=$RXDROP;"
    logStr=$logStr"phymode=$PHYMODE;phyrate=$PHYRATE;lasttxrate=$LASTTXRATE;lastrxrate=$LASTRXRATE;"
    log -t $LOGCATTAG $logStr

    log_kernel_stat
    log_maxmin_signals
    log_traffic_report
    log_mcs_per
}

# Log the airtime utilization and short-term TX/RX statstic
function log_traffic_report
{
    ChanBusy=0
    ChanIdle=0
    ChanTx=0
    ChanRx=0
    TxGood=0
    TxBad=0
    TxRetry=0
    RxGood=0
    RxBad=0
    TXOPSCALE=0

    if (( CH_TOTAL != 0 )); then
        ChanBusy=$((100*$CH_BUSY/$CH_TOTAL))
        ChanIdle=$((100-$ChanBusy))
        ChanTx=$((100*$TX_TIME/$CH_TOTAL))
        ChanRx=$((100*$RX_TIME/$CH_TOTAL))
        # available TXOP
        TXOPSCALE=$(( 10*($CH_TOTAL-$CH_BUSY-$TX_TIME-$RX_TIME)/$CH_TOTAL ))

        # update congestion property
        $SETPROP 'vendor.wifi.wlan0.congest' $ChanBusy
    fi

    if (( TX_TOTAL != 0 )); then
        TxGood=$((100*$TX_OK/$TX_TOTAL))
        TxBad=$((100-$TxGood))
        TxRetry=$((100*$TX_RETRY/$TX_TOTAL))
    fi

    if (( RX_OK != 0 )); then
        RxGood=$((100*$RX_OK/($RX_OK + $RX_FCS)))
        RxBad=$((100-$RxGood))
    fi

    logStr="$LOGNAME:ch_busy=$ChanBusy%;ch_idle=$ChanIdle%;"
    logStr=$logStr"ch_tx=$ChanTx%;ch_rx=$ChanRx%;"
    logStr=$logStr"tx_ok=$TxGood%;tx_fail=$TxBad%;tx_retry=$TxRetry%;rx_ok=$RxGood%;rx_fcs=$RxBad%;"
    logStr=$logStr"tx_ok=$TX_OK;tx_fail=$TX_FAIL;tx_retry=$TX_RETRY;rx_ok=$RX_OK;rx_fcs=$RX_FCS;"
    logStr=$logStr"cck_false=$CCK_ERR;cck_crc=$CCK_CRC;ofdm_false=$OFDM_ERR;ofdm_crc=$OFDM_CRC;"
    log -t $LOGCATTAG $logStr
}

# Log the maximum and minimum values regarding signal quality
function log_maxmin_signals
{
    if [[ ! "$PREVIOUS_CHANNEL" ]] ; then
        PREVIOUS_CHANNEL=$CHANNEL
    elif [[ $PREVIOUS_CHANNEL != $CHANNEL ]] ; then
        PREVIOUS_CHANNEL=$CHANNEL
        MAX_RSSI=''
        MIN_RSSI=''
        MAX_NOISE=''
        MIN_NOISE=''
    fi

    if [[ ! "$PREVIOUS_INTERFACE" ]] ; then
        PREVIOUS_INTERFACE=$WLAN_INTERFACE
    elif [[ $PREVIOUS_INTERFACE != $WLAN_INTERFACE ]] ; then
        PREVIOUS_INTERFACE=$WLAN_INTERFACE
        MAX_RSSI=''
        MIN_RSSI=''
        MAX_NOISE=''
        MIN_NOISE=''
    fi

    if [[ ! "$MAX_RSSI" && ! "$MIN_RSSI" && ! "$maxRssi" -eq 0 ]] ; then
        MAX_RSSI=$maxRssi
        MIN_RSSI=$maxRssi
    fi

    if [[ ! "$MAX_NOISE" && ! "$MIN_NOISE" && ! "$maxNoise" -eq 0 ]] ; then
        MAX_NOISE=$maxNoise
        MIN_NOISE=$maxNoise
    fi


    if [[ ! $maxRssi -eq 0 ]] ; then
        if [ $maxRssi -gt $MAX_RSSI ] ; then
            MAX_RSSI=$maxRssi
        fi

        if [ $maxRssi -lt $MIN_RSSI ] ; then
            MIN_RSSI=$maxRssi
        fi
    fi

    if [[ ! $maxNoise -eq 0 ]] ; then
        if [ $maxNoise -gt $MAX_NOISE ] ; then
            MAX_NOISE=$maxNoise
        fi

        if [ $maxNoise -lt $MIN_NOISE ] ; then
            MIN_NOISE=$maxNoise
        fi
    fi


    logStr="max_rssi=$MAX_RSSI;min_rssi=$MIN_RSSI;max_noise=$MAX_NOISE;min_noise=$MIN_NOISE;"
    logStr=$logStr"noise histogram=${NOISE_FLOOR[@]}"
    log -t $LOGCATTAG $logStr
}

function clear_stale_stats
{
    BEACONRSSI=""
    NOISE=""
    RSSI=""
}

function log_mcs_per
{
    IFS=$'\n'
    TOTAL=10
    logStr=""
    # collect PER per MCS
    MCS_STATS=($($IWPRIV $WLAN_INTERFACE driver "GET_MCS_INFO"))

    for line in ${MCS_STATS[@]}; do
        if [[ $line == *"*" ]]; then
            string_trimmed_star=${line%%\**}
            STAR_NUM=$((${#line}-${#string_trimmed_star}))
            PERCENT=$((100*$STAR_NUM/$TOTAL))
            string_trimmed_star=`$ECHO "$string_trimmed_star" | xargs`
            if [[ $line == *"PER"* ]]; then
                PER=${string_trimmed_star: -4:3}
                PER=${PER%%\]}
                RATE=${string_trimmed_star%%\ \[*}
                logStr=$logStr"TXRATE=$RATE; PER=$PER; PERCNT=$PERCENT%;"
            else
                logStr=$logStr"RXRATE=$string_trimmed_star; PERCNT=$PERCENT%;"
            fi
        fi
    done
    unset IFS
    log -t $LOGCATTAG $logStr
}

function log_kernel_stat
{
    logStr="tx_packets=$TXPACKETS;tx_bytes=$TXBYTES;tx_errors=$TXERRORS;tx_dropped=$TXDROPPED;"
    logStr=$logStr"rx_packets=$RXPACKETS;rx_bytes=$RXBYTES;rx_errors=$RXERRORS;rx_dropped=$RXDROPPED;"
    # logStr=$logStr$arp_flag
    log -t $LOGCATTAG $logStr
}

function log_chipreset_metrics
{
    local RESETCODE=0
    local CHIPRESET_REPORT="Chip Reset Report: "
    CHIPSTAT=`$IWPRIV $WLAN_INTERFACE driver GET_FW_RESET_CNT | $GREP -Eo =.* | $GREP -Eo [0-9]+`
    if [ $? -ne 0 ]; then
        return $?
    fi
    for line in ${CHIPSTAT[@]}; do
        if [ $line -gt ${CHIPRESET_COUNTER[$RESETCODE]} ]; then
            current=$(($line - ${CHIPRESET_COUNTER[$RESETCODE]}))
            CHIPRESET_REPORT=$CHIPRESET_REPORT$RESETCODE-$current\;
            CHIPRESET_COUNTER[$RESETCODE]=$line
            log_to_kdm_minerva "operation=conn-num-chipreset;key=${RESETCODE};value=${current}"
        else
            CHIPRESET_REPORT+=$RESETCODE-0\;
        fi
        RESETCODE=$((RESETCODE + 1))
    done
    log -t $LOGCATTAG $CHIPRESET_REPORT
}

function run ()
{
    set_wlan_interface
    RSSI_THRESHOLDS=`$GETPROP persist.wifi.rssi.thresholds`

    if [[ "$RSSI_THRESHOLDS" == "" ]] ; then
        RSSI_THRESHOLDS=$DEFAULT_RSSI_THD
    fi

    typeset IFS=","
    i=0
    for thd in $RSSI_THRESHOLDS; do
        RSSITHD[i++]=$thd
    done
    unset IFS

    if [[ -n $WLAN_INTERFACE_UP ]]; then
        if [[ $WLANINTF = "Down" ]]; then
            WLANINTF="Up"
            chip_nss=`$IWPRIV $WLAN_INTERFACE driver "get_cfg Nss"`
            CHIPNSS=${chip_nss#*:}
            $IWPRIV $WLAN_INTERFACE driver "set_fwlog 0 2 1" > /dev/null
            # enable PER per MCS
            $IWPRIV $WLAN_INTERFACE driver "GET_MCS_INFO START" > /dev/null
        fi
        iwpriv_show_channel
        iwpriv_stat_tokens
        iwpriv_driver_get_mib
        ifconfig_kernel_stat
        iwpriv_traffic_noise_report
        get_max_signal_stats
        # arp_check
        log_logcat

        if [[ $currentLoop -ge $LOOPSTILMETRICS ]] && [[ "$WLAN_INTERFACE" !=  *"p2p"* ]]; then
            iwpriv_conn_status
            log_connstatus_metrics

            if [[ $CONN_STATUS = "Connected" ]]; then
                log_wifi_metrics
                log_chipreset_metrics
            fi
            currentLoop=0
        else
            ((currentLoop++))
        fi

        clear_stale_stats
    else
        WLANINTF="Down"
    fi
}

function check_cpu_load_and_run
{
    IFS=$''
    local n=0
    local cpu_load=0
    #number is to calulate all cpu loads on each core and core numbers, it looks like (360, 4)
    local number=`$CAT $CPU_STRING |$GREP cpu | cut -d "=" -f2 | cut -d "/" -f2 |awk '{sum+=$1; i++} END {print sum, i}'`
    cpu_load=`$ECHO $number |cut -d " " -f1`
    n=`$ECHO $number |cut -d " " -f2`
    unset IFS
    if [[ -z $cpu_load ]] || [[ -z $n ]]; then
        logStr="cpu_load/core_number check null. $cpu_load/$n"
        log -t $LOGCATTAG $logStr
        return 0
    fi
    local cpu_total=$((${n} * 100))
    local threshold=$((${cpu_total} * ${CPU_LOAD_WEIGHT} / 100))
    if [[ "$cpu_load" -lt "$threshold" ]]; then
        run
        SKIP_RUN_COUNTER=0
    else
        #skip due to high cpu load; but if skip for 3 times in row, we'll do it
        ((SKIP_RUN_COUNTER++))
        if [[ "$SKIP_RUN_COUNTER" -ge "$SKIP_TIME_LIMIT" ]]; then
            run
            SKIP_RUN_COUNTER=0
            logStr="Do as skipping $SKIP_TIME_LIMIT times in row"
            log -t $LOGCATTAG $logStr
        else
            logStr="Skip this time due to cpu load > $CPU_LOAD_WEIGHT%"
            log -t $LOGCATTAG $logStr
        fi
    fi

}

USAGE="
Syntax: $(basename "$0") [-h|r]
Options:
-h                  Print this help message
-r [hours]          Restart the script periodically
"

function init ()
{
    while getopts ":r:h" opt; do
        case ${opt} in
            r )
                RESTART_ENABLED=true
                period=${OPTARG}
                RESTART_THRESHOLD=$(($LOOPSTILMETRICS*$period+$period))
                ;;
            h ) # print help
                echo "$USAGE" >&2
                exit 1
                ;;
        esac
    done
    OPTIND=1
}

init $@

# Run the collection repeatedly, pushing all output through to the metrics log.
SKIP_RUN_COUNTER=0
local build_type=`$GETPROP ro.build.type`

while true ; do
    if [[ $build_type = "user" ]] && [[ -f $CPU_STRING ]]; then
       check_cpu_load_and_run
    else
       run
    fi
    $SLEEP $DELAY

    if $RESTART_ENABLED ; then
        if [[ $RESTART_COUNTER -ge $RESTART_THRESHOLD ]]; then
            if [[ "$WLAN_INTERFACE" ==  *"p2p"* ]] || [[ $currentLoop -eq 0 ]]; then
                echo "restarting..."
                $TOOLBOX log -t $LOGCATTAG "restarting..."
                exit 0
            fi
        else
            ((RESTART_COUNTER++))
        fi
    fi
done
