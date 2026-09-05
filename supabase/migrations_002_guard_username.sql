-- Applied 2026-09-05. A signed-up member's username is their login; only server-side code
-- (the update-member edge function) may change it, so the auth email is updated in step.
create or replace function public.guard_username_change()
returns trigger language plpgsql as $$
begin
  if new.username is distinct from old.username
     and old.user_id is not null
     and current_user not in ('postgres','service_role','supabase_admin') then
    raise exception 'This member has already signed up; change their username from the Members screen so their login is updated too.';
  end if;
  return new;
end $$;
drop trigger if exists guard_username on members;
create trigger guard_username before update of username on members
  for each row execute function public.guard_username_change();
revoke execute on function public.guard_username_change() from authenticated, anon, public;
