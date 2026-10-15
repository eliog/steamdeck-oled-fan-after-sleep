param([int]$Seconds = 120, [string]$Label = "cycle", [switch]$NoRecover)
# One instrumented sleep cycle: suspend over SSH, audible cue after $Seconds, poll for wake, read result + hook samples.
# If faulted and -NoRecover not given: run a quick recovery cycle (8 s) with its own cue.
$log = "$PSScriptRoot\..\..\LOG.md"
function Cue($msg) { 1..3 | ForEach-Object { [console]::beep(1200,400); Start-Sleep -Milliseconds 150 }; try { (New-Object -ComObject SAPI.SpVoice).Speak($msg) | Out-Null } catch {} }
function Pre() { ssh -o BatchMode=yes -o ConnectTimeout=5 deck 'echo "pre $(date +%H:%M:%S): fan=$(cat /sys/class/hwmon/hwmon3/fan1_input) fault=$(cat /sys/class/hwmon/hwmon3/fan1_fault) apu=$(( $(cat /sys/class/hwmon/hwmon6/temp1_input)/1000 ))C bat=$(cat /sys/class/power_supply/BAT1/status) cur=$(cat /sys/class/power_supply/BAT1/current_now)uA ac=$(cat /sys/class/power_supply/ACAD/online) limit=$(cat /sys/class/hwmon/hwmon3/max_battery_charge_level)% game=$(pgrep -c Sifu)"; sudo -n systemctl suspend' 2>&1 | Select-Object -First 1 }
function Post() {
  $deadline = (Get-Date).AddSeconds(90); $out = $null
  while ((Get-Date) -lt $deadline) {
    $out = ssh -o BatchMode=yes -o ConnectTimeout=2 deck 'sleep 6; echo "post $(date +%H:%M:%S): fan=$(cat /sys/class/hwmon/hwmon3/fan1_input) fault=$(cat /sys/class/hwmon/hwmon3/fan1_fault) apu=$(( $(cat /sys/class/hwmon/hwmon6/temp1_input)/1000 ))C bat=$(cat /sys/class/power_supply/BAT1/status)"; journalctl -b --no-pager -g "suspend entry|suspend exit" -o short 2>/dev/null | tail -2 | awk "{print \$3, \$NF, \$(NF-1)}" | tr "\n" " "; echo; echo "hook t=0: $(tac /home/deck/sleephook.log | awk "/^===== post/{print; exit} {print}" | tac | grep -E "^ *[0-9]+ \|" | sed -n 1p)"; echo "hook t=1.1s: $(tac /home/deck/sleephook.log | awk "/^===== post/{print; exit} {print}" | tac | grep -E "^ *[0-9]+ \|" | sed -n 6p)"; echo "hook t=4.9s: $(tac /home/deck/sleephook.log | awk "/^===== post/{print; exit} {print}" | tac | grep -E "^ *[0-9]+ \|" | tail -1)"' 2>$null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 2
  }
  if (-not $out) { $out = "Deck not reachable within 90 s of cue" }
  return $out
}
"### $Label : ${Seconds}s sleep" | Add-Content $log
$p = Pre; $p; "- $p" | Add-Content $log
Start-Sleep -Seconds ([Math]::Max($Seconds - 2, 1))
Cue "Wake the Steam Deck now"; "cue at $(Get-Date -Format 'HH:mm:ss') PC time"
$r = Post; $r; ($r | ForEach-Object { "- $_" }) | Add-Content $log
$faulted = ($r -join "`n") -match 'post .*fault=1'
if ($faulted) { "RESULT: FAIL (fault=1)"; "- RESULT: FAIL" | Add-Content $log } else { "RESULT: PASS"; "- RESULT: PASS" | Add-Content $log }
if ($faulted -and -not $NoRecover) {
  Start-Sleep -Seconds 3
  "--- recovery cycle" ; "- recovery cycle (8 s):" | Add-Content $log
  $p2 = Pre; $p2; "- $p2" | Add-Content $log
  Start-Sleep -Seconds 7
  Cue "Wake the Steam Deck again"; "cue at $(Get-Date -Format 'HH:mm:ss') PC time"
  $r2 = Post; $r2; ($r2 | ForEach-Object { "- $_" }) | Add-Content $log
  if (($r2 -join "`n") -match 'post .*fault=0') { "RECOVERED"; "- recovered" | Add-Content $log } else { "STILL FAULTED after recovery cycle"; "- STILL FAULTED" | Add-Content $log }
}
