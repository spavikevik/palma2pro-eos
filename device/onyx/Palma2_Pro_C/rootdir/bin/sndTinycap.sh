#!/system/bin/sh
#only works for sm6350
#succees:return 0

#str_testCase=main_mic
#str_playSeconds=5
#path_audioFile=/sdcard/Download/tinycap.wav
str_testCase=$1
str_playSeconds=$2
path_audioFile=$3
#logPath=/sdcard/Download
logPath=/onyxconfig

str_sampleRate=16000
str_bits=16
str_Volume=102
str_VolumeEnhance=108

echo "----- onyx_tinycap: testcase:$str_testCase seconds:$str_playSeconds path:$path_audioFile-----" | tee $logPath/tinycap.log
function pre_tinycap_main_mic() {
tinymix 'TX_CDC_DMA_TX_3 Channels' One
tinymix 'TX_AIF1_CAP Mixer DEC0' 1
tinymix 'TX DEC0 MUX' MSM_DMIC
tinymix 'TX DMIC MUX0' DMIC0
tinymix 'TX_DEC0 Volume' $str_VolumeEnhance
tinymix 'MultiMedia1 Mixer TX_CDC_DMA_TX_3' 1
}
function pre_tinycap_sec_mic() {
tinymix 'TX_CDC_DMA_TX_3 Channels' One
tinymix 'TX_AIF1_CAP Mixer DEC0' 1
tinymix 'TX DEC0 MUX' MSM_DMIC
tinymix 'TX DMIC MUX0' DMIC2
tinymix 'TX_DEC0 Volume' $str_Volume
tinymix 'MultiMedia1 Mixer TX_CDC_DMA_TX_3' 1
}
function post_tinycap_main_mic() {
tinymix 'MultiMedia1 Mixer TX_CDC_DMA_TX_3' 0
tinymix 'TX_DEC0 Volume' 84
#tinymix 'TX DMIC MUX0' ZERO
#tinymix 'TX DEC0 MUX' MSM_DMIC
tinymix 'TX_AIF1_CAP Mixer DEC0' 0
#tinymix 'TX_CDC_DMA_TX_3 Channels' One
}
function post_tinycap_sec_mic() {
post_tinycap_main_mic
}

audio_detect() {
        if [ $str_testCase == "main_mic" ]; then
            echo "onyx_tinycap:main_mic" | tee -a $logPath/tinycap.log
			pre_tinycap_main_mic
			tinycap $path_audioFile -r $str_sampleRate -b $str_bits -T $str_playSeconds
			post_tinycap_main_mic
			chmod 666 $path_audioFile
			exit 0
			
        fi
        if [ $str_testCase == "main_mic2" ]; then
            echo "onyx_tinycap:main_mic2" | tee -a $logPath/tinycap.log
			pre_tinycap_main_mic
			tinymix 'TX DMIC MUX0' DMIC1
			tinycap $path_audioFile -r $str_sampleRate -b $str_bits -T $str_playSeconds
			post_tinycap_main_mic
			chmod 666 $path_audioFile
			exit 0
        fi
	if [ $str_testCase == "sec_mic" ]; then
            echo "onyx_tinycap:sec_mic" | tee -a $logPath/tinycap.log
			pre_tinycap_sec_mic
			tinycap $path_audioFile -r $str_sampleRate -b $str_bits -T $str_playSeconds
			post_tinycap_sec_mic
			chmod 666 $path_audioFile
			exit 0
        fi
	if [ $str_testCase == "sec_mic2" ]; then
            echo "onyx_tinycap:sec_mic2" | tee -a $logPath/tinycap.log
			pre_tinycap_sec_mic
			tinymix 'TX DMIC MUX0' DMIC3
			tinycap $path_audioFile -r $str_sampleRate -b $str_bits -T $str_playSeconds
			post_tinycap_sec_mic
			chmod 666 $path_audioFile
			exit 0
        fi
		echo "onyx_tinycap:invalid testCase:$str_testCase" | tee -a $logPath/tinycap.log
		exit 255
}
audio_detect
