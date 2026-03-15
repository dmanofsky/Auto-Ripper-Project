# ==============================================================================
# SCRIPT 1: AUTO-RIPPER DAEMON (The "Dumb" Ingest)
# PURPOSE: Runs endlessly in the background. Watches the optical drive. 
#          When a disc is inserted, it rips the raw files to the NVMe, 
#          ejects the tray, and waits for the next disc. Zero logic required.
# ==============================================================================

$opticalDrive = "I" 
$backupRoot = "D:\media\backups"
$makemkvExe = "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "      INGEST DAEMON (RIPPER) ONLINE      " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Kill any ghost MakeMKV processes before starting
Stop-Process -Name "makemkv", "makemkvcon" -Force -ErrorAction SilentlyContinue

$fso = New-Object -ComObject Scripting.FileSystemObject

while ($true) {
    $drive = $fso.GetDrive("$opticalDrive`:")
    
    if ($drive.IsReady) {
        $volumeName = $drive.VolumeName
        if ([string]::IsNullOrWhiteSpace($volumeName)) { $volumeName = "UNKNOWN_DISC_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
        
        $backupPath = Join-Path $backupRoot $volumeName
        
        # Check if this folder already exists to prevent an infinite rip loop
        if (Test-Path $backupPath) {
            Write-Host "  > [SKIP] $volumeName is already backed up." -ForegroundColor DarkGray
            Start-Sleep -Seconds 30
            continue
        }

        Write-Host "`nDISC DETECTED: $volumeName" -ForegroundColor Yellow
        Write-Host "  > Ripping Decrypted Backup to NVMe..." -ForegroundColor Cyan
        
        New-Item -ItemType Directory -Path $backupPath | Out-Null
        
        # The actual rip command
        & $makemkvExe backup --decrypt --cache=1 disc:0 $backupPath
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  > [SUCCESS] Backup complete!" -ForegroundColor Green
            Write-Host "  > Ejecting disc tray..." -ForegroundColor DarkGray
            (New-Object -COMObject Shell.Application).Namespace(17).ParseName("$opticalDrive`:").InvokeVerb("Eject")
        } else {
            Write-Host "  > [ERROR] MakeMKV Backup failed. Please check the disc." -ForegroundColor Red
        }
    }
    
    # Rest for 10 seconds before checking the drive again
    Start-Sleep -Seconds 10
}