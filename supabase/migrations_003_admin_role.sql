-- Applied 2026-09-05. 'admin' is the system operator, not an elected office:
-- it carries every officer permission without claiming a title the person doesn't hold.
alter table role_assignments drop constraint if exists role_assignments_role_check;
alter table role_assignments add constraint role_assignments_role_check
  check (role in ('admin','chairperson','treasurer','secretary','investment_lead'));

-- Every guard calls has_role('treasurer') etc; admin satisfies all of them,
-- so no other function or policy needed changing.
create or replace function public.has_role(p_role text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from role_assignments r
    where r.member_id = public.me()
      and current_date between r.term_start and r.term_end
      and (r.role = p_role or r.role = 'admin'))
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from role_assignments r
    where r.member_id = public.me() and r.role = 'admin'
      and current_date between r.term_start and r.term_end)
$$;
revoke execute on function public.is_admin() from anon, public;
grant execute on function public.is_admin() to authenticated;
