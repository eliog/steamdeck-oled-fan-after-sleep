$out = "$PSScriptRoot\wake-capture.txt"
$sshOpts = @('-o','BatchMode=yes','-o','ConnectTimeout=2','-o','ServerAliveInterval=5','deck')

"watcher started $(Get-Date -Format 'HH:mm:ss')" | Set-Content $out
$attempt = 0
while ($true) {
    $attempt++
    $r = & ssh @sshOpts 'echo CONNECTED $(date +%H:%M:%S.%N); echo "fan=$(cat /sys/class/hwmon/hwmon3/fan1_input) rpm fault=$(cat /sys/class/hwmon/hwmon3/fan1_fault) target=$(cat /sys/class/hwmon/hwmon3/fan1_target) apu=$(( $(cat /sys/class/hwmon/hwmon6/temp1_input)/1000 ))C acpitz=$(( $(cat /sys/class/hwmon/hwmon1/temp1_input)/1000 ))C gpu=$(cat /sys/class/drm/card*/device/gpu_busy_percent | head -1)%"' 2>&1
    if ($LASTEXITCODE -eq 0) {
        "connected on attempt $attempt at $(Get-Date -Format 'HH:mm:ss') (PC time)" | Add-Content $out
        $r | Add-Content $out
        break
    }
    Start-Sleep -Seconds 2
}

"--- 60s of samples (every 2s): time | fan rpm | fault | APU C | acpitz C | gpu %" | Add-Content $out
& ssh -o BatchMode=yes -o ConnectTimeout=5 deck 'for i in $(seq 1 30); do echo "$(date +%H:%M:%S) | $(cat /sys/class/hwmon/hwmon3/fan1_input) | $(cat /sys/class/hwmon/hwmon3/fan1_fault) | $(( $(cat /sys/class/hwmon/hwmon6/temp1_input)/1000 )) | $(( $(cat /sys/class/hwmon/hwmon1/temp1_input)/1000 )) | $(cat /sys/class/drm/card*/device/gpu_busy_percent | head -1)"; sleep 2; done' 2>&1 | Add-Content $out

"--- fan control service" | Add-Content $out
& ssh -o BatchMode=yes -o ConnectTimeout=5 deck 'systemctl is-active jupiter-fan-control; systemctl is-enabled jupiter-fan-control; echo; echo "=== top procs"; ps -eo pcpu,comm --sort=-pcpu | head -5' 2>&1 | Add-Content $out

"--- journal since 19:26 (suspend/resume/fan/hwmon/errors)" | Add-Content $out
& ssh -o BatchMode=yes -o ConnectTimeout=5 deck 'journalctl --no-pager --since "2026-10-14 19:26:00" -o short -g "suspend|resume|PM: |hwmon|fan|jupiter|thermal|error|fail" 2>&1 | tail -80' 2>&1 | Add-Content $out

"--- full kernel log since 19:26" | Add-Content $out
& ssh -o BatchMode=yes -o ConnectTimeout=5 deck 'journalctl -k --no-pager --since "2026-10-14 19:26:00" -o short 2>&1 | tail -120' 2>&1 | Add-Content $out

"DONE $(Get-Date -Format 'HH:mm:ss')" | Add-Content $out
