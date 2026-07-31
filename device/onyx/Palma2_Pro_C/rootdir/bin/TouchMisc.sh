#!/system/bin/sh

WACOM_TS_NODE="/sys/wacom_ts/caldata"
WACOM_FWVER="/sys/onyx_misc/stylus_fwver"
USER_CALDATA="/onyxconfig/pointercal"

#Once We found the wacom driver exists, will do nothing for Hanvon EMTP
#Just check the calibration data and write it to the driver interface.
if [ ! -e $WACOM_TS_NODE ]; then
    echo "Not wacom driver"
    exit 0
fi
# Process user calibration data
if [ -e $USER_CALDATA ]; then
    FILESIZE=`stat -c "%s" $USER_CALDATA`
    if [ $FILESIZE -gt 10 ]; then
        echo "Check calibration data pass and write to driver now"
        cat $USER_CALDATA > $WACOM_TS_NODE
    else
        echo "Calibartion data check Failed!!!"
        rm -rf $USER_CALDATA
    fi
    exit 0
fi
echo "No user calibration data"
# Process preset calibration data
VERSION=`cat $WACOM_FWVER`
echo "The current wacom firmware version is $VERSION"
VERSION=`echo ${VERSION#*0x}`
PRESET_CALDATA="/system/etc/$VERSION"
if [ ! -e $PRESET_CALDATA ]; then
    echo "No preset calibration data"
    exit 0
fi
echo "Found preset calibration data"
cat $PRESET_CALDATA > $WACOM_TS_NODE
