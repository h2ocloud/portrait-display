#!/bin/bash

if [[ `id -u` != "0" ]] ; then
	if [ -d "/Applications/USB Display Device.app" ]; then
		osascript -e "tell application \"Finder\" to delete POSIX file \"/Applications/USB Display Device.app\""
	fi

	echo 'Most components require root privileges to uninstall. We are about to run those commands using "sudo", please enter your password if asked.'
	sudo /bin/bash "$0" AUTO "$@"
	exit 0
else
	if [ "AUTO" != "$1" ]; then
		echo "WARNING: Please run this script without \'sudo\', the script will automatically request admin privileges for the relevant items"
		exit 1
	fi
fi

echo Unloading daemons
if [ -f "/Library/LaunchDaemons/tw.com.mct.TriggerDriver.plist" ] ; then
	launchctl unload /Library/LaunchDaemons/tw.com.mct.TriggerDriver.plist
fi
rm -rf /Library/LaunchDaemons/tw.com.mct.TriggerDriver.plist
if [ -f "/Library/LaunchDaemons/eu.dennis-jordan.virtualdisplay.service.plist" ]; then
	launchctl unload /Library/LaunchDaemons/eu.dennis-jordan.virtualdisplay.service.plist
fi
rm -rf /Library/LaunchDaemons/eu.dennis-jordan.virtualdisplay.service.plist
if [ -f "/Library/LaunchAgents/eu.dennis-jordan.virtualdisplay.agent.plist" ]; then
	launchctl unload /Library/LaunchAgents/eu.dennis-jordan.virtualdisplay.agent.plist
fi
rm -rf /Library/LaunchAgents/eu.dennis-jordan.virtualdisplay.agent.plist
rm -rf /Library/LaunchAgents/tw.com.mct.USBDisplayDriverAppLauncher.plist

rm -rf "/Library/Application Support/VirtualDisplayDriver"
rm -rf "/Library/Application Support/USBDisplayDriver"
rm -rf "/Applications/USB Display.app"
rm -rf "/Library/Audio/Plug-Ins/HAL/MCTT6Audio.driver"
rm -rf "/Library/Extensions/MCTTrigger6USB.kext"
rm -rf "/Library/Extensions/MCTTriggerGraphics.plugin"
rm -rf "/Library/Extensions/Trigger5Core.kext"
rm -rf "/Library/Extensions/MCTTrigger6USB.kext"
rm -rf "/Library/Extensions/MCTDisplay.kext"
rm -rf "/Library/Extensions/DJTVirtualDisplayDriver.kext"
rm -rf "/usr/local/libexec/MCTTriggerDriver"

rm -rf "/Library/Extensions/AX88179_178A.kext"
rm -rf "/Library/Extensions/AX88179_178A_Catalina.kext"


# TODO uninstall legacy items

