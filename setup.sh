#!/usr/bin/env bash
# Bwana Family Fund - one-time setup (Git Bash / WSL / macOS)
set -euo pipefail
REPO="https://github.com/murrahcode/trustfund.git"

command -v git >/dev/null || { echo "Git is not installed."; exit 1; }
echo "Setting up in $PWD"

[ -d .git ] && git checkout -B main >/dev/null || git init -b main >/dev/null
git remote get-url origin >/dev/null 2>&1 && git remote set-url origin "$REPO" || git remote add origin "$REPO"
echo "  remote -> $REPO"

git add -A
git diff --cached --quiet || git commit -m "Family trust fund PWA: contributions, loans, voting, bilingual UI" >/dev/null
echo "Pushing to GitHub..."
git push -u origin main --force-with-lease
echo "Done. Vercel will build from this push."
echo "Reminder: Supabase > Authentication > Email > turn OFF 'Confirm email'."
