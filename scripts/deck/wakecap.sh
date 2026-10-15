#!/bin/bash
# Runs on the Deck right after SSH comes back post-resume. Captures fan state + EC memory.
H=/sys/class/hwmon/hwmon3
G=$(ls /sys/class/drm/card*/device/gpu_busy_percent | head -1)
T=/sys/class/hwmon/hwmon6/temp1_input
read_state() {
  echo "$(date +%H:%M:%S.%3N) fan=$(cat $H/fan1_input) fault=$(cat $H/fan1_fault) target=$(cat $H/fan1_target) apu=$(( $(cat $T)/1000 ))C gpu=$(cat $G)%"
}
echo "=== CONNECTED $(date +%H:%M:%S.%3N)"
read_state
echo "=== last resume: $(journalctl -b --no-pager -g 'PM: suspend exit' -o short 2>/dev/null | tail -1)"
echo "=== EC MMIO snapshot immediately after wake"
sudo -n python3 -I /home/deck/ecmmio.py 2>&1
echo "=== 45 s of samples (1 s)"
for i in $(seq 1 45); do read_state; sleep 1; done
echo "=== EC MMIO snapshot at +45 s"
sudo -n python3 -I /home/deck/ecmmio.py 2>&1
echo "=== EC RAM (ec_sys) at +45 s"
sudo -n xxd /sys/kernel/debug/ec/ec0/io 2>&1
echo "=== journal around suspend/resume"
journalctl --no-pager --since "-10 min" -o short -g "suspend|resume|PM: |EC:|fan|jupiter|thermal|vpower" 2>&1 | tail -40
echo "=== DONE $(date +%H:%M:%S)"
