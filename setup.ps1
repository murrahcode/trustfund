# Bwana Family Fund - one-time setup
# Run from the project folder:  powershell -ExecutionPolicy Bypass -File setup.ps1

$ErrorActionPreference = "Stop"
$repo = "https://github.com/murrahcode/trustfund.git"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host "Git is not installed. Get it from https://git-scm.com/download/win then run this again." -ForegroundColor Red
  exit 1
}

Write-Host "Setting up in $PWD" -ForegroundColor Cyan

if (-not (Test-Path ".git")) { git init -b main | Out-Null; Write-Host "  git initialised" }
else { git checkout -B main | Out-Null; Write-Host "  git already present" }

if (git remote | Select-String -Quiet "^origin$") { git remote set-url origin $repo }
else { git remote add origin $repo }
Write-Host "  remote -> $repo"

git add -A
if (git diff --cached --quiet 2>$null) { Write-Host "  nothing new to commit" }
else { git commit -m "Family trust fund PWA: contributions, loans, voting, bilingual UI" | Out-Null; Write-Host "  committed" }

Write-Host "`nPushing to GitHub (sign in if a browser window opens)..." -ForegroundColor Cyan
git push -u origin main --force-with-lease

Write-Host "`nDone. Vercel will build from this push - check your project dashboard." -ForegroundColor Green
Write-Host "Reminder: Supabase > Authentication > Sign In / Providers > Email > turn OFF 'Confirm email'." -ForegroundColor Yellow
