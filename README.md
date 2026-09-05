# Bwana Family Fund — app

A single-file progressive web app for the family trust fund, backed by the
Supabase project **Youth Fund Hub**. Every rule (amounts, rates, limits,
vote thresholds) is read from the `fund_settings` table, never hardcoded.

## Files
- `index.html` — the whole app (Supabase URL + publishable key are inside, near the top)
- `manifest.webmanifest`, `sw.js`, `icon*.png` — make it installable on Android/iOS home screens
- `supabase/trust_fund_schema_v1.sql` — the database schema already applied to the project
- `supabase/functions/reset-pin/index.ts` — the officer-only PIN reset function already deployed
- `CLAUDE.md` — project context for Claude Code
- `setup.ps1` / `setup.sh` — one-time git + GitHub wiring

## Setup and deploy
The repo is `github.com/murrahcode/trustfund`, and Vercel builds from its
`main` branch — so **pushing to GitHub deploys the app**.

First time, from this folder:

    powershell -ExecutionPolicy Bypass -File setup.ps1     # Windows
    ./setup.sh                                             # Git Bash / WSL / macOS

After that, every change ships with:

    git add -A && git commit -m "what changed" && git push

Open the Vercel URL on a phone → browser menu → "Add to Home screen".

## One-time Supabase setting
Authentication → Sign In / Providers → Email → turn **off** "Confirm email".
(Usernames are mapped to hidden `username@fund.local` accounts, so no real
email is ever sent.)

## First sign-in
Julius: open the app → "First time here? Set your PIN" → username `juliusbwana`
→ choose a 6-digit PIN. You are chairperson + treasurer until March 2027.

## Adding the family
More → Members → Add a member (name + username). Send them the link; they tap
"First time here", enter their username and pick their own PIN. Nobody who is
not on the member list can create an account.

## Monthly routine (treasurer / secretary)
- Deposits → Awaiting confirmation: confirm what members submitted.
- Deposits → Who has paid this month: chase the rest.
- After the deposit deadline, run late fines from the Supabase SQL editor
  (or schedule it with pg_cron):  `select assess_late_fines();`
- Same for suspensions:            `select refresh_member_status();`
  (Both are also callable from the app in a later version.)

## Changing the rules
Vote → New proposal → "Rule change" → fill only the fields you want to change
→ open for voting. When it passes, the new rule set takes effect automatically.

## Free-tier note
Supabase pauses free projects after 7 days without traffic. Normal weekly use
keeps it awake; if it ever pauses, restore it from the Supabase dashboard.
