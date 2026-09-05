# Bwana Family Trust Fund — project context

A progressive web app for a 9-member (growing) Tanzanian family savings and
investment group. Members contribute monthly, borrow from the pool with
interest, vote on investments, and track progress toward a shared target.
Interface is bilingual: Kiswahili (default) and English.

## Golden rule
**No financial number is ever hardcoded.** Amounts, interest rates, loan
limits, vote thresholds, fines, and targets all live in the `fund_settings`
table and are read at runtime. If you find yourself typing `100000` or `10%`
or `9 members` into code, stop — it belongs in settings. The group must be
able to change contributions, add members, and amend rules without a deploy.

## Stack
- **Frontend**: one file, `index.html`. No build step, no framework, no npm.
  Vanilla JS + Supabase UMD client from CDN. Installable PWA (`manifest.webmanifest`, `sw.js`).
- **Backend**: Supabase project **Youth Fund Hub** (`bbvizypslemcczsrfkhs`, eu-west-1),
  under the Murrah LLC organisation. Postgres + RLS + RPCs + one edge function.
- **Hosting**: Vercel, auto-deploying from the `main` branch of
  `github.com/murrahcode/trustfund`. Static only — `vercel.json` just sets headers.

## Database shape (`supabase/trust_fund_schema_v1.sql` is the applied migration)
- `fund_settings` — the constitution, **versioned by `effective_from`**. A rule
  change inserts a new row; it never updates the old one, so past months keep
  the rules that applied then. `current_settings(date)` returns the row in force.
- `members`, `role_assignments` — people and time-boxed officer terms
  (chairperson, treasurer, secretary, investment_lead), plus `admin`.
  **`admin` is the system operator, not an elected office.** `has_role(x)`
  returns true for an admin whatever `x` is, so admin passes every officer
  guard and policy without holding a title. Admin terms have no real end date;
  officer terms run for `officer_term_months`.
- `contributions` — every deposit. `status`: submitted → confirmed/rejected.
  Members submit their own; the treasurer either confirms or records directly
  as confirmed. `penalties` holds late fines.
- `loans`, `loan_repayments` — request → approve → disburse → repay. Interest
  rate and method are **snapshotted onto the loan** at request time.
- `proposals`, `votes`, `meetings` — governance. A passed `settings_change`
  proposal writes the new `fund_settings` row automatically.
- `investments`, `investment_valuations`, `investment_cashflows`, `fund_expenses`.
- `audit_log` — triggers on every money and rule table.

### Views (all `security_invoker`, so RLS applies)
- `member_balances` — shares, outstanding loans, current borrowing limit.
- `member_month_status` — expected vs paid per member per month; drives
  reminders, fines, and suspensions.
- `fund_summary` — one row: cash on hand, fund value, progress to target.

### RPCs enforce the rules — call these, don't write the tables directly
`loan_eligibility`, `request_loan`, `decide_loan`, `disburse_loan`,
`review_contribution`, `review_repayment`, `open_proposal`, `cast_vote`,
`close_proposal`, `assess_late_fines`, `refresh_member_status`.

## Auth
Username + 6-digit PIN. Usernames map to hidden `username@fund.local` addresses
in Supabase Auth (so "Confirm email" must stay **off** in the dashboard). A
trigger on `auth.users` refuses sign-up for any username not already on the
member list — that is the access gate. Two edge functions hold the service
role key: `reset-pin` (officers reset a forgotten PIN) and `update-member`
(edit name/phone/username/status; officers for anyone, members for themselves).
**Never change a signed-up member's `username` with a plain table update** —
the login email must change with it, and a DB trigger (`guard_username`)
blocks it. Always go through `update-member`.

## Frontend conventions in index.html
- `STR.en` / `STR.sw` hold every string; `t(key)` looks up the current language.
  **Add both languages whenever you add a string.**
- `S` is the app state (session, me, roles, settings, current tab).
- `render()` redraws the whole view; each tab is an async function that fetches
  and writes HTML. Escape all interpolated data with `esc()`.
- `money()` formats using the currency from settings.
- Views: `homeView`, `moneyView`, `loansView`, `voteView`, `moreView`.
- Design tokens are CSS variables at the top; green `--primary` is the fund's
  colour. Tap targets stay at least 44px — this is used on phones, mostly Android.

## Not built yet
Emergency withdrawals UI, meetings and minutes, expenses UI, in-app triggering
of `assess_late_fines` / `refresh_member_status` (currently run from SQL),
push or SMS reminders, PDF statements, projection modelling.

## Working on this
Schema changes go through a new numbered SQL file in `supabase/`
(`migrations_002_guard_username.sql` is the pattern) and are applied as a
Supabase migration — never edit `trust_fund_schema_v1.sql` after the fact.
Edge function source lives in `supabase/functions/<name>/index.ts`; deploy with
`supabase functions deploy <name>` after editing.
After any schema change, check the Supabase security advisors for new RLS or
function-exposure warnings.
