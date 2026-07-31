#!/system/bin/sh
#v1.2
#succees:return 0
#please keep screen on but no animation

#eg: calibrate_cyttsp5 1-0024
function calibrate_cyttsp5() {
	#please keep screen on, no animation
	path_sendcmd=/sys/bus/i2c/devices/$1/command
	path_getresponse=/sys/bus/i2c/devices/$1/response

	ls $path_getresponse || return 255 #check if node exists
	drvName=`cat /sys/bus/i2c/devices/$1/name`
	if [ $drvName != "cyttsp5_i2c_adapter" -a $drvName != "pt_i2c_adapter" ]; then 
		echo "not cyttsp5/parade driver"
		return 255 #check if driver matches
	fi
	echo "-------------------$drvName calibrate start----------------"
	
	#cmd_pin_ic="04 00 05 00 2f 00 00"
	cmd_scanning_off="04 00 05 00 2f 00 03"
	cmd_calibrate_self="04 00 06 00 2f 00 28 02"
	cmd_calibrate_mutual="04 00 06 00 2f 00 28 00"
	cmd_scanning_on="04 00 05 00 2f 00 04"
	
	#pin ic
	#echo $cmd_pin_ic > $path_sendcmd
	
	#SUSPEND SCANNING
	echo $cmd_scanning_off > $path_sendcmd
	sleep 0.5
	cat $path_getresponse | tee /onyxconfig/calibrate_cyttps5
	
	#CALIBRATE SELF
	echo $cmd_calibrate_self > $path_sendcmd
	sleep 1
	cat $path_getresponse | tee -a /onyxconfig/calibrate_cyttps5
	
	#CALIBRATE MUTUAL
	echo $cmd_calibrate_mutual > $path_sendcmd
	sleep 1
	cat $path_getresponse | tee -a /onyxconfig/calibrate_cyttps5
	
	#RESUME SCANNING
	echo $cmd_scanning_on > $path_sendcmd
	sleep 0.5
	cat $path_getresponse | tee -a /onyxconfig/calibrate_cyttps5

	echo "-------------------$drvName calibrate end----------------"
	exit 0
}

#eg: calibrate_elan 1-0010
function calibrate_elan() {
	path_sendcmd=/sys/bus/i2c/devices/$1/elan_ktf/calibrate

	ls $path_sendcmd || return 255 #check if node exists
	drvName=`cat /sys/bus/i2c/devices/$1/name`
	if [ $drvName != "ektf" ]; then 
		echo "not elan driver"
		return 255 #check if driver matches
	fi

	echo "-------------------$drvName calibrate start----------------"
	echo 1 > $path_sendcmd
	echo "-------------------$drvName calibrate end----------------"
	exit 0
}

function drv_detect() {
	#devicePath=/sys/bus/i2c/devices
	#debugPath=/sys/kernel/debug
	i2cAddr=`cat /sys/onyx_misc/onyx_tp_info | sed -n '3p' | cut -c15-20`
	if [ `echo $i2cAddr | grep 24` ]; then
		echo "cyttsp5 detected"
		calibrate_cyttsp5 $i2cAddr
	fi
	if [ `echo $i2cAddr | grep 10` ]; then
		echo "elan detected"
		calibrate_elan $i2cAddr
	fi

	exit 255
}

drv_detect
