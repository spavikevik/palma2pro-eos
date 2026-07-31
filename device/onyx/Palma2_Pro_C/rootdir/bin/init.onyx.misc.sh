#!/system/bin/sh

# Copyright (c) 2012-2013,2016,2018 The Linux Foundation. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of The Linux Foundation nor
#       the names of its contributors may be used to endorse or promote
#       products derived from this software without specific prior written
#       permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NON-INFRINGEMENT ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

#
# save log
#
root_dir=/storage/emulated/0
log_dir=${root_dir}/.log
log_path=${log_dir}/boot_logcat.log
kernel_log=${log_dir}/boot_kernel.log
#10MB
rotatekbytes=10240
rotateCount=8

buildvariant=`getprop ro.build.type`
if [ "$buildvariant" == "user" ]; then
    rotateCount=4
fi

function rename_log() {
    for log in `ls $1*`
    do
        logwrapper echo "===mv ${log} to ${log}.old==="
        mv ${log} ${log}.old
    done
}

function check_previous_log
{
    if [ ! -d $log_dir ];then
        logwrapper echo "===create $log_dir directory==="
        mkdir -p $log_dir
    else
        rm -rf ${log_dir}/*.old
        rename_log $log_path
        rename_log $kernel_log
    fi
}

function start_save_log
{
    logwrapper echo "===start saving log==="
    cp -r /sys/fs/pstore ${log_dir}
    logcat -v threadtime -b kernel -r $rotatekbytes -n $rotateCount -f ${log_dir}/boot_kernel.log &
    logcat -v threadtime -b main -b system -b crash -b events -b radio -r $rotatekbytes -n $rotateCount -f ${log_dir}/boot_logcat.log
}

# 150 x 2 = 300s = 5minutes
# If the internal storage has not been mounted within 5 minutes,
# i think that there is a problem with the data partition mounting, so the log cannot be saved.
i=150
while [ i -gt 0 ]
do
    if [ "`ls -A ${root_dir}`" = "" ];then
        logwrapper echo "===${root_dir} directory does not exist==="
        sleep 2
    else
        check_previous_log
        start_save_log
        break;
    fi
    i=$(($i-1))
done
