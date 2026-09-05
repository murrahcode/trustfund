-- =====================================================================
--  BWANA FAMILY TRUST FUND  —  schema v1
--  Postgres / Supabase migration. Every number from the plan document
--  lives in fund_settings (data), never in code.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. THE CONSTITUTION  (versioned; a new row = a new rule set)
-- ---------------------------------------------------------------------
create table fund_settings (
  id                                uuid primary key default gen_random_uuid(),
  effective_from                    date not null unique,
  fund_start_date                   date not null,
  currency                          text not null default 'TZS',
  -- contributions
  initial_deposit                   numeric(16,2) not null check (initial_deposit >= 0),
  monthly_contribution              numeric(16,2) not null check (monthly_contribution >= 0),
  deposit_day                       smallint not null check (deposit_day between 1 and 28),
  grace_days                        smallint not null default 0,
  late_fine                         numeric(16,2) not null default 0,
  missed_months_before_suspension   smallint not null,
  -- loans
  loan_multiplier                   numeric(6,2)  not null,   -- max loan = multiplier x confirmed contributions
  loan_interest_rate_pct            numeric(6,2)  not null,   -- per month
  loan_interest_method              text not null default 'flat_per_month'
                                    check (loan_interest_method in ('flat_per_month','flat_once')),
  loan_min_term_months              smallint not null default 1,
  loan_max_term_months              smallint not null,
  loan_lockout_months               smallint not null,        -- no loans in the fund's first N months
  -- emergencies
  emergency_withdrawal_pct          numeric(5,2) not null,    -- max % of own shares
  emergency_repayment_months        smallint not null,
  -- governance
  vote_threshold_pct                numeric(5,2) not null,    -- % of eligible voters needed (6/9 = 66.67)
  vote_window_days                  smallint not null default 7,
  large_investment_threshold        numeric(16,2) not null,   -- needs chairperson sign-off above this
  officer_term_months               smallint not null,
  -- investing
  invest_start_balance              numeric(16,2) not null default 0, -- pool size before external investing
  invest_pool_min_pct               numeric(5,2) not null default 0,
  invest_pool_max_pct               numeric(5,2) not null,
  max_single_venture_pct            numeric(5,2) not null,
  -- goal
  target_amount                     numeric(16,2) not null,
  target_date                       date,
  -- meta
  note                              text,
  created_by                        uuid,
  created_at                        timestamptz not null default now()
);

-- Defaults taken from the May 2026 plan. Edit in the app, never here.
insert into fund_settings (
  effective_from, fund_start_date,
  initial_deposit, monthly_contribution, deposit_day, grace_days, late_fine, missed_months_before_suspension,
  loan_multiplier, loan_interest_rate_pct, loan_interest_method, loan_min_term_months, loan_max_term_months, loan_lockout_months,
  emergency_withdrawal_pct, emergency_repayment_months,
  vote_threshold_pct, vote_window_days, large_investment_threshold, officer_term_months,
  invest_start_balance, invest_pool_min_pct, invest_pool_max_pct, max_single_venture_pct,
  target_amount, target_date, note
) values (
  date_trunc('month', current_date)::date, date_trunc('month', current_date)::date,
  150000, 100000, 5, 0, 5000, 2,
  2.00, 10.00, 'flat_per_month', 1, 3, 3,
  50.00, 6,
  66.67, 7, 2000000, 6,
  5000000, 30.00, 50.00, 20.00,
  100000000, (date_trunc('month', current_date) + interval '4 years')::date,
  'Initial rule set from the May 2026 plan document'
);

-- ---------------------------------------------------------------------
-- 2. PEOPLE
-- ---------------------------------------------------------------------
create table members (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid unique references auth.users(id) on delete set null,
  full_name   text not null,
  phone       text unique,
  email       text unique,
  language    text not null default 'sw' check (language in ('en','sw')),
  status      text not null default 'active' check (status in ('active','suspended','exited')),
  joined_on   date not null default current_date,
  exited_on   date,
  created_at  timestamptz not null default now()
);

create table role_assignments (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members(id) on delete cascade,
  role        text not null check (role in ('chairperson','treasurer','secretary','investment_lead')),
  term_start  date not null,
  term_end    date not null check (term_end > term_start),
  created_at  timestamptz not null default now()
);
create index on role_assignments(member_id, role);

-- Link a member row to the auth user when they first sign in (matched by email or phone)
create or replace function public.link_member_on_signup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update members
     set user_id = new.id
   where user_id is null
     and ( (new.email is not null and lower(email) = lower(new.email))
        or (new.phone is not null and phone = new.phone) );
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.link_member_on_signup();

-- ---------------------------------------------------------------------
-- 3. MONEY IN  (member submits -> treasurer confirms; or treasurer records directly)
-- ---------------------------------------------------------------------
create table emergency_withdrawals (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members(id),
  amount      numeric(16,2) not null check (amount > 0),
  reason      text not null,
  status      text not null default 'requested'
              check (status in ('requested','approved','rejected','paid_out','repaid')),
  approved_by uuid references members(id),
  paid_on     date,
  due_by      date,
  note        text,
  created_at  timestamptz not null default now()
);

create table contributions (
  id             uuid primary key default gen_random_uuid(),
  member_id      uuid not null references members(id),
  kind           text not null check (kind in ('initial','monthly','extra','fine','emergency_repayment')),
  period         date check (period is null or period = date_trunc('month', period)::date),  -- month being paid for
  amount         numeric(16,2) not null check (amount > 0),
  paid_on        date not null default current_date,
  channel        text check (channel in ('mpesa','tigo_pesa','airtel_money','halopesa','bank','cash','other')),
  reference      text,
  proof_url      text,
  withdrawal_id  uuid references emergency_withdrawals(id),
  status         text not null default 'submitted' check (status in ('submitted','confirmed','rejected')),
  submitted_by   uuid references members(id),
  confirmed_by   uuid references members(id),
  confirmed_at   timestamptz,
  rejection_reason text,
  note           text,
  created_at     timestamptz not null default now()
);
create index on contributions(member_id, period);
create index on contributions(status);

create table penalties (
  id            uuid primary key default gen_random_uuid(),
  member_id     uuid not null references members(id),
  period        date not null,
  kind          text not null default 'late_deposit' check (kind in ('late_deposit','missed_meeting','other')),
  amount        numeric(16,2) not null check (amount >= 0),
  reason        text,
  status        text not null default 'pending' check (status in ('pending','paid','waived')),
  settled_by    uuid references contributions(id),
  waived_by     uuid references members(id),
  created_at    timestamptz not null default now(),
  unique (member_id, period, kind)
);

-- ---------------------------------------------------------------------
-- 4. LOANS
-- ---------------------------------------------------------------------
create table loans (
  id                uuid primary key default gen_random_uuid(),
  member_id         uuid not null references members(id),
  principal         numeric(16,2) not null check (principal > 0),
  interest_rate_pct numeric(6,2) not null,             -- snapshot of the rule at request time
  interest_method   text not null,
  term_months       smallint not null check (term_months > 0),
  interest_amount   numeric(16,2) not null,
  total_due         numeric(16,2) generated always as (principal + interest_amount) stored,
  purpose           text,
  status            text not null default 'requested'
                    check (status in ('requested','approved','rejected','disbursed','repaid','defaulted','cancelled')),
  requested_at      timestamptz not null default now(),
  decided_by        uuid references members(id),
  decided_at        timestamptz,
  decision_note     text,
  disbursed_on      date,
  due_on            date,
  closed_at         timestamptz,
  created_at        timestamptz not null default now()
);
create index on loans(member_id, status);

create table loan_repayments (
  id            uuid primary key default gen_random_uuid(),
  loan_id       uuid not null references loans(id),
  amount        numeric(16,2) not null check (amount > 0),
  paid_on       date not null default current_date,
  channel       text,
  reference     text,
  proof_url     text,
  status        text not null default 'submitted' check (status in ('submitted','confirmed','rejected')),
  submitted_by  uuid references members(id),
  confirmed_by  uuid references members(id),
  confirmed_at  timestamptz,
  rejection_reason text,
  created_at    timestamptz not null default now()
);
create index on loan_repayments(loan_id, status);

-- ---------------------------------------------------------------------
-- 5. GOVERNANCE  (proposals, votes, meetings)
-- ---------------------------------------------------------------------
create table proposals (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null check (kind in ('investment','settings_change','expense','member_change','other')),
  title            text not null,
  description      text,
  amount           numeric(16,2),
  payload          jsonb,                   -- e.g. new fund_settings values for a settings_change
  proposed_by      uuid not null references members(id),
  opens_at         timestamptz not null default now(),
  closes_at        timestamptz not null,
  threshold_pct    numeric(5,2) not null,   -- snapshot
  eligible_voters  int not null,            -- snapshot
  status           text not null default 'open' check (status in ('open','passed','failed','withdrawn')),
  decided_at       timestamptz,
  tie_broken_by    uuid references members(id),
  created_at       timestamptz not null default now()
);

create table votes (
  proposal_id  uuid not null references proposals(id) on delete cascade,
  member_id    uuid not null references members(id),
  choice       text not null check (choice in ('yes','no','abstain')),
  voted_at     timestamptz not null default now(),
  primary key (proposal_id, member_id)
);

create table meetings (
  id           uuid primary key default gen_random_uuid(),
  held_on      date not null,
  title        text not null,
  agenda       text,
  minutes      text,
  recorded_by  uuid references members(id),
  created_at   timestamptz not null default now()
);

create table meeting_attendance (
  meeting_id  uuid not null references meetings(id) on delete cascade,
  member_id   uuid not null references members(id),
  present     boolean not null default true,
  primary key (meeting_id, member_id)
);

-- ---------------------------------------------------------------------
-- 6. INVESTMENTS & EXPENSES
-- ---------------------------------------------------------------------
create table investments (
  id                          uuid primary key default gen_random_uuid(),
  name                        text not null,
  type                        text not null check (type in ('fixed_deposit','treasury','unit_trust','business','land','stocks','other')),
  institution                 text,
  amount_invested             numeric(16,2) not null check (amount_invested >= 0),
  invested_on                 date,
  expected_annual_return_pct  numeric(6,2),
  maturity_date               date,
  status                      text not null default 'proposed' check (status in ('proposed','active','exited')),
  proposal_id                 uuid references proposals(id),
  managed_by                  uuid references members(id),
  notes                       text,
  created_at                  timestamptz not null default now()
);

create table investment_valuations (
  id             uuid primary key default gen_random_uuid(),
  investment_id  uuid not null references investments(id) on delete cascade,
  valued_on      date not null,
  value          numeric(16,2) not null check (value >= 0),
  note           text,
  created_at     timestamptz not null default now()
);

create table investment_cashflows (
  id             uuid primary key default gen_random_uuid(),
  investment_id  uuid not null references investments(id) on delete cascade,
  direction      text not null check (direction in ('in','out')),      -- in = money back to fund
  kind           text not null check (kind in ('income','principal_return','sale_proceeds','additional_capital','fee')),
  amount         numeric(16,2) not null check (amount > 0),
  occurred_on    date not null,
  reference      text,
  note           text,
  recorded_by    uuid references members(id),
  created_at     timestamptz not null default now()
);

create table fund_expenses (
  id           uuid primary key default gen_random_uuid(),
  description  text not null,
  category     text,
  amount       numeric(16,2) not null check (amount > 0),
  paid_on      date not null default current_date,
  proposal_id  uuid references proposals(id),
  recorded_by  uuid references members(id),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7. AUDIT LOG  (every change on money & rule tables)
-- ---------------------------------------------------------------------
create table audit_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  actor       uuid default auth.uid(),
  table_name  text not null,
  row_id      text,
  action      text not null,
  old_data    jsonb,
  new_data    jsonb
);

create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log(table_name, row_id, action, old_data, new_data)
  values (tg_table_name,
          coalesce((case when tg_op = 'DELETE' then old.id::text else new.id::text end), null),
          tg_op,
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['fund_settings','members','role_assignments','contributions','penalties',
                           'loans','loan_repayments','emergency_withdrawals','proposals',
                           'investments','investment_valuations','investment_cashflows','fund_expenses']
  loop
    execute format('create trigger audit_%1$s after insert or update or delete on %1$s
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 8. HELPERS  (security definer so RLS policies can call them without recursion)
-- ---------------------------------------------------------------------
create or replace function public.current_settings(p_on date default current_date)
returns fund_settings language sql stable as $$
  select * from fund_settings where effective_from <= p_on order by effective_from desc limit 1
$$;

create or replace function public.me()
returns uuid language sql stable security definer set search_path = public as $$
  select id from members where user_id = auth.uid()
$$;

create or replace function public.has_role(p_role text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from role_assignments r
    where r.member_id = public.me() and r.role = p_role
      and current_date between r.term_start and r.term_end)
$$;

create or replace function public.is_officer()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from role_assignments r
    where r.member_id = public.me() and current_date between r.term_start and r.term_end)
$$;

create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid() and status <> 'exited')
$$;

create or replace function public.compute_loan_interest(p_principal numeric, p_rate_pct numeric, p_method text, p_months int)
returns numeric language sql immutable as $$
  select round(case when p_method = 'flat_per_month' then p_principal * p_rate_pct / 100 * p_months
                    else p_principal * p_rate_pct / 100 end, 2)
$$;

-- ---------------------------------------------------------------------
-- 9. VIEWS
-- ---------------------------------------------------------------------

-- Per member: confirmed contributions, outstanding loans, current borrowing limit
create view member_balances with (security_invoker = true) as
select m.id as member_id, m.full_name, m.status,
       coalesce(c.shares, 0)                       as total_shares,      -- initial + monthly + extra
       coalesce(c.fines, 0)                        as fines_paid,
       coalesce(l.outstanding, 0)                  as loans_outstanding,
       coalesce(c.shares, 0) * s.loan_multiplier   as loan_limit,
       greatest(coalesce(c.shares,0) * s.loan_multiplier - coalesce(l.outstanding,0), 0) as available_to_borrow
from members m
cross join public.current_settings() s
left join lateral (
  select sum(amount) filter (where kind in ('initial','monthly','extra')) as shares,
         sum(amount) filter (where kind = 'fine')                       as fines
  from contributions where member_id = m.id and status = 'confirmed') c on true
left join lateral (
  select sum(ln.total_due - coalesce(r.paid, 0)) as outstanding
  from loans ln
  left join lateral (select sum(amount) paid from loan_repayments where loan_id = ln.id and status = 'confirmed') r on true
  where ln.member_id = m.id and ln.status = 'disbursed') l on true;

-- Per member per month: expected vs paid (drives reminders, fines, suspension)
create view member_month_status with (security_invoker = true) as
with months as (
  select m.id as member_id,
         gs::date as period
  from members m
  cross join lateral generate_series(
      greatest((select fund_start_date from public.current_settings()), date_trunc('month', m.joined_on)::date),
      date_trunc('month', current_date)::date, interval '1 month') gs
  where m.status <> 'exited'
)
select mo.member_id, mo.period,
       s.monthly_contribution as expected,
       coalesce(p.paid, 0) as paid,
       case when coalesce(p.paid,0) >= s.monthly_contribution then 'paid'
            when coalesce(p.paid,0) > 0 then 'partial' else 'missing' end as status,
       (mo.period + (s.deposit_day - 1) + s.grace_days)::date as due_on,
       p.first_paid_on > (mo.period + (s.deposit_day - 1) + s.grace_days)::date as was_late
from months mo
cross join lateral public.current_settings(mo.period) s
left join lateral (
  select sum(amount) paid, min(paid_on) first_paid_on
  from contributions where member_id = mo.member_id and period = mo.period
    and kind = 'monthly' and status = 'confirmed') p on true;

-- Whole fund in one row
create view fund_summary with (security_invoker = true) as
with s as (select * from public.current_settings()),
c as (select sum(amount) filter (where kind in ('initial','monthly','extra')) shares,
             sum(amount) filter (where kind = 'fine') fines,
             sum(amount) filter (where kind = 'emergency_repayment') emergency_repaid
      from contributions where status = 'confirmed'),
l as (select sum(principal) filter (where status in ('disbursed','repaid','defaulted')) disbursed,
             sum(total_due - r.paid) filter (where status = 'disbursed') outstanding,
             sum(greatest(r.paid - principal, 0)) interest_earned
      from loans ln
      left join lateral (select coalesce(sum(amount),0) paid from loan_repayments where loan_id = ln.id and status = 'confirmed') r on true),
rp as (select coalesce(sum(amount),0) repaid from loan_repayments where status = 'confirmed'),
ew as (select coalesce(sum(amount),0) paid_out from emergency_withdrawals where status in ('paid_out','repaid')),
inv as (select coalesce(sum(amount_invested) filter (where status = 'active'),0) invested_cost,
               coalesce(sum(coalesce(v.value, i.amount_invested)) filter (where status = 'active'),0) invested_value
        from investments i
        left join lateral (select value from investment_valuations where investment_id = i.id order by valued_on desc limit 1) v on true),
cf as (select coalesce(sum(amount) filter (where direction='in'),0) inflow,
              coalesce(sum(amount) filter (where direction='out'),0) outflow
       from investment_cashflows),
ex as (select coalesce(sum(amount),0) total from fund_expenses)
select
  s.currency,
  coalesce(c.shares,0)              as total_shares,
  coalesce(c.fines,0)               as fines_collected,
  coalesce(l.interest_earned,0)     as loan_interest_earned,
  coalesce(l.outstanding,0)         as loans_outstanding,
  inv.invested_cost,
  inv.invested_value,
  -- cash actually sitting in the group account
  coalesce(c.shares,0) + coalesce(c.fines,0) + coalesce(c.emergency_repaid,0) + rp.repaid + cf.inflow
    - coalesce(l.disbursed,0) - ew.paid_out - inv.invested_cost - cf.outflow - ex.total  as cash_on_hand,
  -- fund value = cash + loans owed to us + investments at latest valuation
  coalesce(c.shares,0) + coalesce(c.fines,0) + coalesce(c.emergency_repaid,0) + rp.repaid + cf.inflow
    - coalesce(l.disbursed,0) - ew.paid_out - inv.invested_cost - cf.outflow - ex.total
    + coalesce(l.outstanding,0) + inv.invested_value                                    as fund_value,
  s.target_amount,
  s.target_date,
  (select count(*) from members where status = 'active') as active_members
from s, c, l, rp, ew, inv, cf, ex;

-- ---------------------------------------------------------------------
-- 10. RULE ENGINE  (RPCs; called from the app, enforce the constitution)
-- ---------------------------------------------------------------------

-- Can this member borrow, and how much?
create or replace function public.loan_eligibility(p_member uuid default public.me())
returns table (eligible boolean, max_loan numeric, reasons text[])
language plpgsql stable security definer set search_path = public as $$
declare s fund_settings; m members; b member_balances; r text[] := '{}'; missed int;
begin
  s := public.current_settings();
  select * into m from members where id = p_member;
  select * into b from member_balances where member_id = p_member;
  if m.status <> 'active' then r := r || ('Member status is ' || m.status); end if;
  if current_date < s.fund_start_date + (s.loan_lockout_months || ' months')::interval then
    r := r || format('No loans until the fund is %s months old', s.loan_lockout_months); end if;
  if exists (select 1 from loans where member_id = p_member and status in ('requested','approved','disbursed')) then
    r := r || 'An existing loan is still open'; end if;
  select count(*) into missed from member_month_status where member_id = p_member and status = 'missing' and period < date_trunc('month', current_date);
  if missed >= s.missed_months_before_suspension then
    r := r || format('%s missed months (limit %s)', missed, s.missed_months_before_suspension); end if;
  if coalesce(b.available_to_borrow,0) <= 0 then r := r || 'No confirmed contributions yet'; end if;
  return query select cardinality(r) = 0, coalesce(b.available_to_borrow,0), r;
end $$;

-- Member asks for a loan
create or replace function public.request_loan(p_principal numeric, p_term_months int, p_purpose text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s fund_settings; e record; v_id uuid;
begin
  s := public.current_settings();
  select * into e from public.loan_eligibility(public.me());
  if not e.eligible then raise exception 'Not eligible: %', array_to_string(e.reasons, '; '); end if;
  if p_principal > e.max_loan then raise exception 'Maximum loan is %', e.max_loan; end if;
  if p_term_months < s.loan_min_term_months or p_term_months > s.loan_max_term_months then
    raise exception 'Term must be between % and % months', s.loan_min_term_months, s.loan_max_term_months; end if;
  insert into loans(member_id, principal, interest_rate_pct, interest_method, term_months, interest_amount, purpose)
  values (public.me(), p_principal, s.loan_interest_rate_pct, s.loan_interest_method, p_term_months,
          public.compute_loan_interest(p_principal, s.loan_interest_rate_pct, s.loan_interest_method, p_term_months), p_purpose)
  returning id into v_id;
  return v_id;
end $$;

-- Treasurer or chairperson approves / rejects
create or replace function public.decide_loan(p_loan uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.has_role('treasurer') or public.has_role('chairperson')) then raise exception 'Treasurer or chairperson only'; end if;
  update loans set status = case when p_approve then 'approved' else 'rejected' end,
                   decided_by = public.me(), decided_at = now(), decision_note = p_note
  where id = p_loan and status = 'requested';
  if not found then raise exception 'Loan is not awaiting a decision'; end if;
end $$;

-- Treasurer records the payout; due date follows the term
create or replace function public.disburse_loan(p_loan uuid, p_date date default current_date)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('treasurer') then raise exception 'Treasurer only'; end if;
  update loans set status = 'disbursed', disbursed_on = p_date,
                   due_on = (p_date + (term_months || ' months')::interval)::date
  where id = p_loan and status = 'approved';
  if not found then raise exception 'Loan must be approved first'; end if;
end $$;

-- Treasurer confirms or rejects a submitted contribution
create or replace function public.review_contribution(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c contributions;
begin
  if not public.has_role('treasurer') then raise exception 'Treasurer only'; end if;
  update contributions
     set status = case when p_approve then 'confirmed' else 'rejected' end,
         confirmed_by = public.me(), confirmed_at = now(), rejection_reason = p_reason
   where id = p_id and status = 'submitted' returning * into c;
  if not found then raise exception 'Contribution is not awaiting review'; end if;
  -- a confirmed fine payment settles the pending penalty for that month
  if p_approve and c.kind = 'fine' and c.period is not null then
    update penalties set status = 'paid', settled_by = c.id
     where member_id = c.member_id and period = c.period and status = 'pending';
  end if;
  -- a confirmed emergency repayment closes the withdrawal once fully repaid
  if p_approve and c.withdrawal_id is not null then
    update emergency_withdrawals w set status = 'repaid'
     where w.id = c.withdrawal_id
       and (select coalesce(sum(amount),0) from contributions where withdrawal_id = w.id and status = 'confirmed') >= w.amount;
  end if;
end $$;

-- Treasurer confirms a loan repayment; loan closes automatically when fully paid
create or replace function public.review_repayment(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r loan_repayments; ln loans; paid numeric;
begin
  if not public.has_role('treasurer') then raise exception 'Treasurer only'; end if;
  update loan_repayments
     set status = case when p_approve then 'confirmed' else 'rejected' end,
         confirmed_by = public.me(), confirmed_at = now(), rejection_reason = p_reason
   where id = p_id and status = 'submitted' returning * into r;
  if not found then raise exception 'Repayment is not awaiting review'; end if;
  if p_approve then
    select * into ln from loans where id = r.loan_id;
    select coalesce(sum(amount),0) into paid from loan_repayments where loan_id = r.loan_id and status = 'confirmed';
    if paid >= ln.total_due then
      update loans set status = 'repaid', closed_at = now() where id = r.loan_id;
    end if;
  end if;
end $$;

-- Open a proposal; threshold and electorate are frozen at creation
create or replace function public.open_proposal(p_kind text, p_title text, p_description text default null,
                                                p_amount numeric default null, p_payload jsonb default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare s fund_settings; v_id uuid; fs fund_summary;
begin
  if not public.is_member() then raise exception 'Members only'; end if;
  s := public.current_settings();
  select * into fs from fund_summary;
  -- investment guard rails from the constitution
  if p_kind = 'investment' and p_amount is not null then
    if fs.fund_value < s.invest_start_balance then
      raise exception 'Fund must reach % before external investing', s.invest_start_balance; end if;
    if p_amount > fs.fund_value * s.max_single_venture_pct / 100 then
      raise exception 'Exceeds %%% single-venture limit (%)', s.max_single_venture_pct, round(fs.fund_value * s.max_single_venture_pct / 100); end if;
  end if;
  insert into proposals(kind, title, description, amount, payload, proposed_by, closes_at, threshold_pct, eligible_voters)
  values (p_kind, p_title, p_description, p_amount, p_payload, public.me(),
          now() + (s.vote_window_days || ' days')::interval, s.vote_threshold_pct,
          (select count(*) from members where status = 'active'))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.cast_vote(p_proposal uuid, p_choice text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from members where id = public.me() and status = 'active') then raise exception 'Active members only'; end if;
  if not exists (select 1 from proposals where id = p_proposal and status = 'open' and now() < closes_at) then
    raise exception 'Voting is closed'; end if;
  insert into votes(proposal_id, member_id, choice) values (p_proposal, public.me(), p_choice)
  on conflict (proposal_id, member_id) do update set choice = excluded.choice, voted_at = now();
end $$;

-- Close and decide. Passes when yes >= threshold% of eligible voters.
-- Chairperson may break an exact yes/no tie with p_chair_says_yes.
create or replace function public.close_proposal(p_proposal uuid, p_chair_says_yes boolean default null)
returns text language plpgsql security definer set search_path = public as $$
declare p proposals; yes int; no int; needed int; passed boolean;
begin
  select * into p from proposals where id = p_proposal and status = 'open';
  if not found then raise exception 'Proposal is not open'; end if;
  if not (public.has_role('chairperson') or public.has_role('secretary') or now() >= p.closes_at) then
    raise exception 'Only an officer can close a proposal before its deadline'; end if;
  select count(*) filter (where choice='yes'), count(*) filter (where choice='no') into yes, no from votes where proposal_id = p_proposal;
  needed := ceil(p.eligible_voters * p.threshold_pct / 100);
  passed := yes >= needed;
  if not passed and yes = no and p_chair_says_yes is not null and public.has_role('chairperson') then
    passed := p_chair_says_yes;
    update proposals set tie_broken_by = public.me() where id = p_proposal;
  end if;
  update proposals set status = case when passed then 'passed' else 'failed' end, decided_at = now() where id = p_proposal;
  -- a passed rule change becomes the new constitution
  if passed and p.kind = 'settings_change' and p.payload is not null then
    insert into fund_settings
    select (jsonb_populate_record(null::fund_settings,
              (to_jsonb(public.current_settings()) - 'id' - 'created_at' - 'created_by')
              || p.payload
              || jsonb_build_object('id', gen_random_uuid(), 'created_by', public.me(), 'created_at', now()))).*;
  end if;
  -- a passed investment proposal activates the investment record
  if passed and p.kind = 'investment' then
    update investments set status = 'active' where proposal_id = p_proposal and status = 'proposed';
  end if;
  return case when passed then 'passed' else 'failed' end;
end $$;

-- Secretary/treasurer runs after the deposit deadline each month (or via pg_cron)
create or replace function public.assess_late_fines(p_period date default date_trunc('month', current_date)::date)
returns int language plpgsql security definer set search_path = public as $$
declare s fund_settings; n int;
begin
  if not (public.has_role('treasurer') or public.has_role('secretary')) then raise exception 'Treasurer or secretary only'; end if;
  s := public.current_settings(p_period);
  if s.late_fine <= 0 then return 0; end if;
  insert into penalties(member_id, period, kind, amount, reason)
  select ms.member_id, ms.period, 'late_deposit', s.late_fine,
         case when ms.status = 'missing' then 'No deposit by ' || ms.due_on else 'Deposit received late' end
  from member_month_status ms
  where ms.period = p_period and current_date > ms.due_on
    and (ms.status <> 'paid' or ms.was_late)
  on conflict (member_id, period, kind) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Suspend borrowing for members over the missed-months limit
create or replace function public.refresh_member_status()
returns int language plpgsql security definer set search_path = public as $$
declare s fund_settings; n int;
begin
  if not public.is_officer() then raise exception 'Officers only'; end if;
  s := public.current_settings();
  update members m set status = 'suspended'
  where m.status = 'active'
    and (select count(*) from member_month_status ms
         where ms.member_id = m.id and ms.status = 'missing' and ms.period < date_trunc('month', current_date))
        >= s.missed_months_before_suspension;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 11. ROW LEVEL SECURITY
--   Family transparency: every member sees fund-wide records.
--   Only the member (or the treasurer) writes their own money records.
--   Emergency withdrawals are private to the member and officers.
-- ---------------------------------------------------------------------
alter table fund_settings          enable row level security;
alter table members                enable row level security;
alter table role_assignments       enable row level security;
alter table contributions          enable row level security;
alter table penalties              enable row level security;
alter table loans                  enable row level security;
alter table loan_repayments        enable row level security;
alter table emergency_withdrawals  enable row level security;
alter table proposals              enable row level security;
alter table votes                  enable row level security;
alter table meetings               enable row level security;
alter table meeting_attendance     enable row level security;
alter table investments            enable row level security;
alter table investment_valuations  enable row level security;
alter table investment_cashflows   enable row level security;
alter table fund_expenses          enable row level security;
alter table audit_log              enable row level security;

-- read for all members
create policy read_all on fund_settings         for select using (public.is_member());
create policy read_all on members               for select using (public.is_member());
create policy read_all on role_assignments      for select using (public.is_member());
create policy read_all on contributions         for select using (public.is_member());
create policy read_all on penalties             for select using (public.is_member());
create policy read_all on loans                 for select using (public.is_member());
create policy read_all on loan_repayments       for select using (public.is_member());
create policy read_all on proposals             for select using (public.is_member());
create policy read_all on votes                 for select using (public.is_member());
create policy read_all on meetings              for select using (public.is_member());
create policy read_all on meeting_attendance    for select using (public.is_member());
create policy read_all on investments           for select using (public.is_member());
create policy read_all on investment_valuations for select using (public.is_member());
create policy read_all on investment_cashflows  for select using (public.is_member());
create policy read_all on fund_expenses         for select using (public.is_member());
create policy read_own_or_officer on emergency_withdrawals for select using (member_id = public.me() or public.is_officer());
create policy read_officers on audit_log        for select using (public.is_officer());

-- settings: chairperson may insert directly (bootstrap); rule changes normally flow through close_proposal
create policy chair_insert on fund_settings for insert with check (public.has_role('chairperson'));

-- members: officers manage; a member may edit their own contact details
create policy officer_write on members for insert with check (public.is_officer());
create policy officer_update on members for update using (public.is_officer());
create policy self_update on members for update using (id = public.me()) with check (id = public.me() and status = (select status from members where id = public.me()));
create policy chair_roles on role_assignments for all using (public.has_role('chairperson')) with check (public.has_role('chairperson'));

-- contributions: member submits own; treasurer records directly as confirmed
create policy member_submit on contributions for insert
  with check (member_id = public.me() and submitted_by = public.me() and status = 'submitted');
create policy treasurer_record on contributions for insert
  with check (public.has_role('treasurer') and submitted_by = public.me()
              and (status = 'submitted' or (status = 'confirmed' and confirmed_by = public.me())));
create policy member_fix_pending on contributions for update
  using (member_id = public.me() and status = 'submitted') with check (member_id = public.me() and status = 'submitted');
create policy treasurer_update on contributions for update using (public.has_role('treasurer'));

create policy officer_penalties on penalties for all
  using (public.has_role('treasurer') or public.has_role('secretary'))
  with check (public.has_role('treasurer') or public.has_role('secretary'));

-- loans change only through the RPCs above; treasurer may annotate
create policy treasurer_loans on loans for update using (public.has_role('treasurer'));

create policy member_repay on loan_repayments for insert
  with check (submitted_by = public.me() and status = 'submitted'
              and exists (select 1 from loans where id = loan_id and member_id = public.me()));
create policy treasurer_repay on loan_repayments for insert
  with check (public.has_role('treasurer') and submitted_by = public.me());
create policy treasurer_repay_update on loan_repayments for update using (public.has_role('treasurer'));

create policy member_request_emergency on emergency_withdrawals for insert
  with check (member_id = public.me() and status = 'requested'
              and amount <= (select total_shares * (select emergency_withdrawal_pct from public.current_settings()) / 100
                             from member_balances where member_id = public.me()));
create policy officer_emergency on emergency_withdrawals for update using (public.is_officer());

-- proposals open through open_proposal(); proposer may withdraw
create policy withdraw_own on proposals for update
  using (proposed_by = public.me() and status = 'open') with check (status in ('open','withdrawn'));

create policy officer_meetings on meetings for all
  using (public.has_role('secretary') or public.has_role('chairperson'))
  with check (public.has_role('secretary') or public.has_role('chairperson'));
create policy officer_attendance on meeting_attendance for all
  using (public.has_role('secretary') or public.has_role('chairperson'))
  with check (public.has_role('secretary') or public.has_role('chairperson'));

create policy invest_write on investments for all
  using (public.has_role('investment_lead') or public.has_role('treasurer'))
  with check (public.has_role('investment_lead') or public.has_role('treasurer'));
create policy invest_val_write on investment_valuations for all
  using (public.has_role('investment_lead') or public.has_role('treasurer'))
  with check (public.has_role('investment_lead') or public.has_role('treasurer'));
create policy invest_cf_write on investment_cashflows for all
  using (public.has_role('treasurer')) with check (public.has_role('treasurer'));
create policy treasurer_expenses on fund_expenses for all
  using (public.has_role('treasurer')) with check (public.has_role('treasurer'));

-- ---------------------------------------------------------------------
-- 12. STORAGE  (payment screenshots)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('proofs', 'proofs', false)
on conflict (id) do nothing;

create policy proofs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy proofs_read on storage.objects for select to authenticated
  using (bucket_id = 'proofs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_officer()));

-- ---------------------------------------------------------------------
-- 13. GRANTS
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
grant insert, update on contributions, loan_repayments, emergency_withdrawals, members, role_assignments,
      penalties, proposals, meetings, meeting_attendance, investments, investment_valuations,
      investment_cashflows, fund_expenses, fund_settings to authenticated;
grant execute on all functions in schema public to authenticated;
