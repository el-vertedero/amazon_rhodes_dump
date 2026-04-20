#!/vendor/bin/sh

echo "running a4b_factory_reset.sh" > /dev/kmsg

ENABLE_STRING="Enable"
DISABLE_STRING="Disable"

# Get the existing dev flags
IDME_DEV_FLAGS=`idme print dev_flags 2>/dev/null`

# Ensure input is only hexadecimal
in_size=${#IDME_DEV_FLAGS}

IDME_DEV_FLAGS=${IDME_DEV_FLAGS//[!^a-fA-F0-9]/}

# If size differs, there might be something wrong
if [ ${#IDME_DEV_FLAGS} -ne $in_size ]; then
    IDME_DEV_FLAGS=0
fi
# If empty, set safe value
if [[ ! $IDME_DEV_FLAGS ]];then
    IDME_DEV_FLAGS=0
fi

# Prefix 0x to flags for operations
IDME_DEV_FLAGS=0x$IDME_DEV_FLAGS

# Value used for setting/clearing 19th bit
hex_value=0x80000

if [ $# -ne 0 ] ; then
ARG=$1
	if [ "${ARG}" == "${DISABLE_STRING}" ] ; then
		# Set the bit now (OR with existing dev_flag value)
		new_dec_val=$(($IDME_DEV_FLAGS | $hex_value))

		# Get the value back in hex to write dev_flags
		final_hex_val=$(printf "%x\n" $new_dec_val)

		# Write the flags
		idme dev_flags $final_hex_val

		# Check if command executed successfully
		if [ "$?" -eq  0 ]; then
			echo "Idme dev flags set successfully to disable FR"
		else
			echo "Idme dev flags not set correctly to disable FR"
			exit 1
		fi
	else
		if [ "${ARG}" == "${ENABLE_STRING}" ] ; then
			# Clear the bit
			new_dec_val=$(($IDME_DEV_FLAGS & ~$hex_value))

			# Get the value back in hex to write dev_flags
			final_hex_val=$(printf "%x\n" $new_dec_val)

			# Write the flags
			idme dev_flags $final_hex_val

			# Check if command executed successfully
			if [ "$?" -eq  0 ]; then
				echo "Idme dev flags set successfully to enable FR"
			else
				echo "Idme dev flags not set correctly to enable FR"
				exit 1
			fi
		fi
	fi
else
	echo "Insufficient arguments"
	exit 1
fi
exit 0
