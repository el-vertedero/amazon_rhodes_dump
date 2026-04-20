#!/vendor/bin/sh

mixer="/system/bin/tinymix"
# Enable Path
ENABLE=1
# Analog PGA Gain: 40: => 20dB, step 0.5dB
A_PGA_L="40"
A_PGA_R="40"
# SPK volume
D_DAC_GAIN="126"
D_DRIVER_GAIN="1"
# Input Differential Gain 0db
INPUT_GAIN_SEL=0
# ADC Mute
MUTE=0
# FPGA Header Reporting
FPGA_HEADER=0

tlv320adc3101_setup() {
	${mixer} "Loopback Enable" ${ENABLE}
}

tlv32dac3203_setup()  {
	# Enable Playback route
	# Note that it's differential signal
	${mixer} "HPL Output Mixer L_DAC Switch" ${ENABLE}
	${mixer} "HPR Output Mixer L_DAC Switch" ${ENABLE}

	# Gain setting
	${mixer} "PCM Playback Volume" ${D_DAC_GAIN} ${D_DAC_GAIN}
	${mixer} "HP Driver Gain Volume" ${D_DRIVER_GAIN} ${D_DRIVER_GAIN}
}


persistentLed_setup() {
    touch /tmp/persistentLedState
    chmod 0776 /tmp/persistentLedState
}

# Mics Setup
tlv320adc3101_setup
# Speakers Setup
tlv32dac3203_setup
# Set up persistent LED file
# persistentLed_setup

# proxy hal enable/disable
# proxy hal enable 1: enabled , 0: disabled
/system/bin/setprop persist.audio.proxy.hal.enable 1