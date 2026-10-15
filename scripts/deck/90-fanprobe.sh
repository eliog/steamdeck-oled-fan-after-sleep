#!/bin/bash
# pre: snapshot at suspend entry. post: 5 s of 200 ms samples right after resume, then full snapshot.
L=/home/deck/sleephook.log
{
  echo "===== $1 $2 $(date +%H:%M:%S.%3N)"
  echo "fan=$(cat /sys/class/hwmon/hwmon3/fan1_input) fault=$(cat /sys/class/hwmon/hwmon3/fan1_fault) target=$(cat /sys/class/hwmon/hwmon3/fan1_target) apu=$(( $(cat /sys/class/hwmon/hwmon6/temp1_input)/1000 ))C"
  grep -E "STATUS|CAPACITY=|CURRENT_NOW|VOLTAGE_NOW" /sys/class/power_supply/BAT1/uevent | tr "\n" " "; echo
  echo "ac=$(cat /sys/class/power_supply/ACAD/online) limit=$(cat /sys/class/hwmon/hwmon3/max_battery_charge_level)"
  if [ "$1" = "post" ]; then python3 -I /home/deck/ecfast.py 5; fi
  python3 -I /home/deck/ecmmio.py
} >> $L 2>&1
