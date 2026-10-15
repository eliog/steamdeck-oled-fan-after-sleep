param([string]$Label = "wake", [string]$DeckIP = "192.168.x.x")  # DeckIP: your Deck's LAN address
$out = "$PSScriptRoot\$Label-capture.txt"
"watcher started $(Get-Date -Format 'HH:mm:ss') (PC time); waiting for Deck to go to sleep" | Set-Content $out
# Phase 1: wait until the Deck drops off the network (3 consecutive failed pings, to ignore a single lost packet)
$misses = 0
while ($misses -lt 3) {
    $up = Test-Connection $DeckIP -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue
    if ($up) { $misses = 0 } else { $misses++ }
    Start-Sleep -Seconds 1
}
"deck went down at $(Get-Date -Format 'HH:mm:ss') (PC time); now retrying ssh every 2 s" | Add-Content $out
# Phase 2: retry ssh every 2 s until it answers
$attempt = 0
while ($true) {
    $attempt++
    & ssh -o BatchMode=yes -o ConnectTimeout=2 deck 'true' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        "ssh back on attempt $attempt at $(Get-Date -Format 'HH:mm:ss') (PC time)" | Add-Content $out
        break
    }
    Start-Sleep -Seconds 2
}
& ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 deck 'bash /home/deck/wakecap.sh' 2>&1 | Add-Content $out
"WATCHER DONE $(Get-Date -Format 'HH:mm:ss')" | Add-Content $out
