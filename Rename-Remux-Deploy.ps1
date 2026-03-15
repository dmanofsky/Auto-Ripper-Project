# ==============================================================================
# SCRIPT 2: THE SMART PROCESSOR (Rename, Remux, Deploy)
# PURPOSE: Scans raw backups, queries TMDB, remuxes MKVs with TMDB IDs, 
#          uses Robocopy to deploy MKVs and raw backups to TrueNAS, 
#          and automatically cleans up the local NVMe staging folders.
# ==============================================================================

# --- Configuration ---
$tmdbApiKey = "YOUR_TMDB_API_KEY_HERE" # <--- INSERT YOUR KEY HERE
$backupRoot = "D:\media\backups"
$moviesStaging = "D:\media\movies"
$showsStaging = "D:\media\shows"

# TrueNAS Destinations
$truenasMovies = "\\TRUENAS\media\movies"
$truenasShows = "\\TRUENAS\media\shows"
$truenasBackups = "\\TRUENAS\media\backups" # <--- New Backup Destination

$makemkvExe = "C:\Program Files (x86)\MakeMKV\makemkvcon.exe"

Write-Host "=========================================" -ForegroundColor Magenta
Write-Host "     SMART PROCESSOR & DEPLOYER ONLINE   " -ForegroundColor Magenta
Write-Host "=========================================" -ForegroundColor Magenta

$backups = Get-ChildItem -Path $backupRoot -Directory

if ($backups.Count -eq 0) {
    Write-Host "No backups found in $backupRoot. Exiting." -ForegroundColor Yellow
    exit
}

foreach ($folder in $backups) {
    $volumeName = $folder.Name
    $backupPath = $folder.FullName
    $inputUrl = "file:$backupPath"
    
    Write-Host "`n================================================="
    Write-Host "PROCESSING RAW BACKUP: $volumeName" -ForegroundColor Cyan
    
    $cleanQuery = $volumeName -replace '_', ' ' -replace 'AC$|UHD$|BLURAY$|DISC\d', '' | Trim

    # ==========================================================================
    # PHASE 1: TMDB INTERACTIVE SEARCH
    # ==========================================================================
    Write-Host "  > Querying TMDB for: '$cleanQuery'..." -ForegroundColor DarkGray
    
    $uri = "https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=$cleanQuery&language=en-US&page=1"
    $response = Invoke-RestMethod -Uri $uri -ErrorAction SilentlyContinue

    if (-not $response -or $response.results.Count -eq 0) {
        Write-Host "  > [WARNING] TMDB found no results." -ForegroundColor Yellow
        $cleanQuery = Read-Host "Enter manual search term (or press Enter to skip)"
        if ([string]::IsNullOrWhiteSpace($cleanQuery)) { continue }
        $uri = "https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=$cleanQuery&language=en-US&page=1"
        $response = Invoke-RestMethod -Uri $uri
    }

    $results = $response.results | Select-Object -First 5
    Write-Host "`n  --- TMDB Results ---" -ForegroundColor Yellow
    for ($i = 0; $i -lt $results.Count; $i++) {
        $item = $results[$i]
        $title = if ($item.media_type -eq 'movie') { $item.title } else { $item.name }
        $date = if ($item.media_type -eq 'movie') { $item.release_date } else { $item.first_air_date }
        $year = if ($date) { $date.Substring(0,4) } else { "Unknown" }
        Write-Host "  [$($i + 1)] [$($item.media_type.ToUpper())] $title ($year)"
    }
    Write-Host "  [0] Skip this folder entirely."

    $selection = Read-Host "`nSelect the correct match (0-$($results.Count))"
    if ($selection -eq '0' -or [string]::IsNullOrWhiteSpace($selection)) {
        Write-Host "  > Skipping $volumeName." -ForegroundColor DarkGray
        continue
    }

    $chosenIndex = [int]$selection - 1
    $selectedMedia = $results[$chosenIndex]
    
    $finalTitle = if ($selectedMedia.media_type -eq 'movie') { $selectedMedia.title } else { $selectedMedia.name }
    $finalTitle = $finalTitle -replace '[\\/:*?"<>|]', '' 
    $finalDate = if ($selectedMedia.media_type -eq 'movie') { $selectedMedia.release_date } else { $selectedMedia.first_air_date }
    $finalYear = if ($finalDate) { $finalDate.Substring(0,4) } else { "" }
    
    # --- FIX 1: CAPTURE THE TMDB ID ---
    $tmdbId = $selectedMedia.id 

    Write-Host "  > Locked in: $finalTitle ($finalYear) [TMDB-$tmdbId]" -ForegroundColor Green

    # ==========================================================================
    # PHASE 2: JAVA SCAN & TITLE SELECTION
    # ==========================================================================
    Write-Host "  > Scanning backup structure (Java FPL enabled)..." -ForegroundColor DarkGray
    $debugLogPath = Join-Path $backupRoot "$volumeName-JavaDebug.txt"
    & $makemkvExe -r --cache=1 --debug --messages="$debugLogPath" info $inputUrl | Out-Null
    Start-Sleep -Seconds 1
    
    $scanOutput = Get-Content -Path $debugLogPath -ErrorAction SilentlyContinue
    $parsedTitles = @(); $fplTitleId = -1

    foreach ($line in $scanOutput) {
        if ($line -match 'TINFO:(\d+),.*FPL_MainFeature') { $fplTitleId = [int]$matches[1] }
        if ($line -match 'TINFO:(\d+),9,0,"(\d+):(\d+):(\d+)"') {
            $tId = [int]$matches[1]
            $totalSeconds = ([int]$matches[2] * 3600) + ([int]$matches[3] * 60) + [int]$matches[4]
            $parsedTitles += [PSCustomObject]@{ Id = $tId; Duration = $totalSeconds }
        }
    }

    $targetIds = @()

    if ($selectedMedia.media_type -eq 'movie') {
        if ($fplTitleId -ne -1) {
            $targetIds += $fplTitleId
        } else {
            $longestTitle = $parsedTitles | Sort-Object Duration -Descending | Select-Object -First 1
            $targetIds += $longestTitle.Id
        }
    } else {
        $episodes = $parsedTitles | Where-Object { $_.Duration -ge 900 -and $_.Duration -le 5400 } | Sort-Object Id
        Write-Host "    > Found $($episodes.Count) possible TV Episodes on this disc." -ForegroundColor Cyan
        $seasonNum = [int](Read-Host "    > What Season is this disc? (e.g., 1)")
        $startingEp = [int](Read-Host "    > What is the starting Episode Number? (e.g., 1)")
        $targetIds = $episodes.Id
    }

    # ==========================================================================
    # PHASE 3: REMUX & DEPLOYMENT
    # ==========================================================================
    $currentEp = $startingEp
    $localTargetDir = ""

    foreach ($id in $targetIds) {
        
        # --- FIX 1: APPLY TMDB ID TO NAMING CONVENTION ---
        if ($selectedMedia.media_type -eq 'movie') {
            $folderName = "$finalTitle ($finalYear) {tmdb-$tmdbId}"
            $fileName = "$finalTitle ($finalYear) {tmdb-$tmdbId}.mkv"
            $localTargetDir = Join-Path $moviesStaging $folderName
            $truenasTargetDir = Join-Path $truenasMovies $folderName
        } else {
            $folderName = "$finalTitle ($finalYear) {tmdb-$tmdbId}"
            $seasonFolder = "Season $($seasonNum.ToString('D2'))"
            $fileName = "$finalTitle - S$($seasonNum.ToString('D2'))E$($currentEp.ToString('D2')) {tmdb-$tmdbId}.mkv"
            $localTargetDir = Join-Path (Join-Path $showsStaging $folderName) $seasonFolder
            $truenasTargetDir = Join-Path (Join-Path $truenasShows $folderName) $seasonFolder
            $currentEp++
        }

        if (-not (Test-Path $localTargetDir)) { New-Item -ItemType Directory -Path $localTargetDir | Out-Null }
        
        Write-Host "  > Ripping: $fileName" -ForegroundColor Magenta
        
        $filesBefore = @(Get-ChildItem -Path $localTargetDir -Filter "*.mkv")
        & $makemkvExe mkv $inputUrl $id $localTargetDir | Out-Null
        $filesAfter = @(Get-ChildItem -Path $localTargetDir -Filter "*.mkv")
        $newFile = $filesAfter | Where-Object { $filesBefore.FullName -notcontains $_.FullName }
        
        if ($newFile) { 
            Rename-Item -Path $newFile[0].FullName -NewName $fileName 
            
            # --- FIX 3: ROBOCOPY FOR MKV DEPLOYMENT & CLEANUP ---
            Write-Host "  > Deploying MKV to TrueNAS via Robocopy..." -ForegroundColor Cyan
            # /MOV moves files and deletes them from the source. /J uses unbuffered I/O (great for large files). /NP hides progress spam.
            $roboArgs = @("$localTargetDir", "$truenasTargetDir", "$fileName", "/MOV", "/J", "/NP")
            & robocopy @roboArgs | Out-Null
        }
    }
    
    # Clean up the empty local staging folder if Robocopy moved everything successfully
    if ($localTargetDir -ne "" -and (Test-Path $localTargetDir) -and (Get-ChildItem $localTargetDir).Count -eq 0) {
        Remove-Item -Path $localTargetDir -Force
        # Also try removing the parent Show folder if it's now empty
        $parentDir = Split-Path $localTargetDir
        if ((Test-Path $parentDir) -and (Get-ChildItem $parentDir).Count -eq 0) { Remove-Item -Path $parentDir -Force }
    }

    # ==========================================================================
    # PHASE 4: RAW BACKUP DEPLOYMENT & CLEANUP
    # ==========================================================================
    # --- FIX 2: MOVE RAW BDMV FOLDER TO NAS ---
    Write-Host "  > Moving raw backup folder to TrueNAS Backups share..." -ForegroundColor Cyan
    $nasBackupDir = Join-Path $truenasBackups $volumeName
    
    # /MOVE deletes files AND directories from the source after copying. /E copies subdirectories (even empty ones).
    $roboBackupArgs = @("$backupPath", "$nasBackupDir", "/E", "/MOVE", "/J", "/NP")
    & robocopy @roboBackupArgs | Out-Null
    
    # Cleanup the Java log
    Remove-Item -Path $debugLogPath -ErrorAction SilentlyContinue
    
    Write-Host "================================================="
    Write-Host "Finished processing $finalTitle! The raw backup and MKVs have been moved to TrueNAS." -ForegroundColor Green
}