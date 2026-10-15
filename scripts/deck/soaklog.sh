#!/bin/bash
while true; do
  echo "=== $(date +%H:%M:%S) fan=$(cat /sys/class/hwmon/hwmon3/fan1_input) fault=$(cat /sys/class/hwmon/hwmon3/fan1_fault) apu=$(( $(cat /sys/class/hwmon/hwmon6/temp1_input)/1000 ))C bat=$(cat /sys/class/power_supply/BAT1/status) cap=$(cat /sys/class/power_supply/BAT1/capacity)% cur=$(cat /sys/class/power_supply/BAT1/current_now)uA volt=$(cat /sys/class/power_supply/BAT1/voltage_now)uV ac=$(cat /sys/class/power_supply/ACAD/online) pd=$(cat /sys/class/hwmon/hwmon3/in0_input)mV/$(cat /sys/class/hwmon/hwmon3/curr1_input)mA limit=$(cat /sys/class/hwmon/hwmon3/max_battery_charge_level)%"
  sudo -n python3 -I /home/deck/ecmmio.py
  sleep 300
done
