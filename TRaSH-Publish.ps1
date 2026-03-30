# ==============================================================================
# SCRIPT: TRaSH Publish (Git Release Manager)
# PURPOSE: Automates staging, committing, tagging, and pushing to GitHub.
# ==============================================================================

param (
    [Parameter(Mandatory=$true)]
    [string]$Message,

    [Parameter(Mandatory=$false)]
    [string]$Tag
)

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "  TRaSH PUBLISH: PREPARING VAULT SYNC    " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# 1. Stage all changed files
Write-Host "  > Staging all modified files..." -ForegroundColor DarkGray
git add .

# 2. Commit with your custom message
Write-Host "  > Committing: '$Message'" -ForegroundColor DarkGray
git commit -m $Message

# 3. Push the code to the main branch
Write-Host "  > Pushing to GitHub (origin main)..." -ForegroundColor Cyan
git push origin main

# 4. Handle optional version tagging
if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    Write-Host "  > Applying Version Tag: $Tag" -ForegroundColor Magenta
    git tag $Tag
    git push --tags
}

Write-Host "=========================================" -ForegroundColor Green
Write-Host "  VAULT SYNC COMPLETE.                   " -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green