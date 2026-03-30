# ==============================================================================
# SCRIPT: TRaSH Extractor (The "Dumb" Ingest Daemon)
# VERSION: 2.0.0 (Robot Mode Edition)
# PURPOSE: Watches the optical drive. When a disc is inserted, parses 
#          MakeMKV's raw robot output to generate a live, in-place progress 
#          bar. Handles errors, ejects, and loops.
# ==============================================================================

param (
    [string]$TargetDrive = "D",
    [string]$DiscId = "disc:0"
)

$backupRoot = "D:\media\backups"
$makemkvExe = "C:\Program Files (x86)\MakeMKV\makemkvcon.exe"

$spinner = @('|', '/', '-', '\')
$counter = 0

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " TRaSH-Extractor Daemon Online" -ForegroundColor Cyan
Write-Host " Node Assigned to Optical Drive: $TargetDrive`:" -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

$fso = New-Object -ComObject Scripting.FileSystemObject

while ($true) {
    $drive = $fso.GetDrive("$TargetDrive`:")
    
    if ($drive.IsReady) {
        # 1. Erase the idle spinner cleanly
        Write-Host "`r                                                                       `r" -NoNewline
        
        $volumeName = $drive.VolumeName
        if ([string]::IsNullOrWhiteSpace($volumeName)) { $volumeName = "UNKNOWN_DISC_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
        
        $backupPath = Join-Path $backupRoot $volumeName
        
        if (Test-Path $backupPath) {
            Write-Host "  > [SKIP] $volumeName is already backed up." -ForegroundColor DarkGray
            Start-Sleep -Seconds 30
            continue
        }

        Write-Host "`n=================================================" -ForegroundColor Magenta
        Write-Host "DISC DETECTED: $volumeName" -ForegroundColor Yellow
        Write-Host "  > Ripping Decrypted Backup to NVMe..." -ForegroundColor Cyan
        
        New-Item -ItemType Directory -Path $backupPath | Out-Null
        
        # --- THE ROBOT MODE PIPELINE ---
        # The '-r' flag forces MakeMKV to output comma-separated data.
        # We read it line-by-line in real time as the disc spins.
        & $makemkvExe backup --decrypt --cache=1 $DiscId $backupPath -r 2>&1 | ForEach-Object {
            $line = $_.ToString()
            
            # PARSER A: Look for Progress Values (PRGV:current,total,max)
            if ($line -match '^PRGV:(\d+),(\d+),(\d+)') {
                $current = [double]$matches[1]
                $total   = [double]$matches[2]
                $max     = [double]$matches[3]
                
                if ($max -gt 0) {
                    $percent = [math]::Round(($total / $max) * 100, 1)
                    
                    # Draw the actual bar
                    $barLength = 40
                    $filled = [math]::Floor(($percent / 100) * $barLength)
                    $empty = $barLength - $filled
                    $bar = "[" + ("#" * $filled) + ("-" * $empty) + "]"
                    
                    # \r snaps to beginning of line, drawing the bar in place at the bottom
                    Write-Host "`r  > Progress: $bar $percent% " -NoNewline -ForegroundColor Green
                }
            }
            # PARSER B: Look for Message Logs to keep the terminal informative
            elseif ($line -match '^MSG:\d+,\d+,\d+,"((?:\\"|[^"])+)') {
                $msg = $matches[1] -replace '\\"', '"'
                
                # Erase the progress bar, print the log, and drop down a line.
                # The next PRGV update will redraw the progress bar on the new bottom line.
                Write-Host "`r                                                                           `r" -NoNewline
                Write-Host "    [MakeMKV] $msg" -ForegroundColor DarkGray
            }
        }
        
        # Push a final newline so the completion text doesn't overwrite our 100% progress bar
        Write-Host "`n"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  > [SUCCESS] Backup complete!" -ForegroundColor Green
        } else {
            Write-Host "  > [ERROR] MakeMKV encountered a fatal error (Hash/Read failure)." -ForegroundColor Red
            Write-Host "  > [CLEANUP] Purging corrupted backup folder..." -ForegroundColor DarkYellow
            if (Test-Path $backupPath) { Remove-Item -Path $backupPath -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Host "  > [CLEANUP] Purged." -ForegroundColor Green
        }

        Write-Host "  > Ejecting disc tray..." -ForegroundColor DarkGray
        (New-Object -COMObject Shell.Application).Namespace(17).ParseName("$TargetDrive`:").InvokeVerb("Eject")
        Write-Host "=================================================" -ForegroundColor Magenta
        
        Start-Sleep -Seconds 10
    } else {
        # The classic propeller spinner
        $frame = $spinner[$counter % 4]
        Write-Host "`r  > Awaiting 4K UHD disc in Drive $TargetDrive`: ... $frame " -NoNewline -ForegroundColor DarkGray
        $counter++
        Start-Sleep -Milliseconds 250
    }
}