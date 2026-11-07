-- 0003: سحب الصلاحيات الافتراضية، ومنح القراءة حسب الدور، وسياسات RLS.

-- سحب الصلاحيات الافتراضية
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema finance revoke all on tables from anon, authenticated, public;

revoke all on all tables in schema public from anon, authenticated, public;
revoke all on all sequences in schema public from anon, authenticated, public;
revoke all on all functions in schema public from anon, authenticated, public;
revoke all on all tables in schema finance from anon, authenticated, public;
revoke all on schema finance from anon, authenticated, public;

-- قراءة محدودة للمستخدم المسجل (RLS يحدد ما يراه كل دور)
grant usage on schema public to authenticated;
grant select on public.factories, public.profiles, public.shifts, public.employees,
  public.employee_factory_assignments, public.attendance, public.advances,
  public.employee_notes, public.holidays, public.system_settings,
  public.management_attendance, public.audit_logs
  to authenticated;
-- لا منح للكتابة المباشرة على أي جدول، ولا منح DELETE أبداً

-- تفعيل RLS
alter table public.factories enable row level security;
alter table public.profiles enable row level security;
alter table public.shifts enable row level security;
alter table public.employees enable row level security;
alter table public.employee_factory_assignments enable row level security;
alter table public.attendance enable row level security;
alter table public.advances enable row level security;
alter table public.employee_notes enable row level security;
alter table public.management_attendance enable row level security;
alter table public.holidays enable row level security;
alter table public.system_settings enable row level security;
alter table public.audit_logs enable row level security;
alter table finance.employee_wage_history enable row level security;
alter table finance.payroll_periods enable row level security;
alter table finance.payroll_items enable row level security;
alter table finance.payroll_payments enable row level security;
alter table finance.advance_repayments enable row level security;
alter table finance.bonuses enable row level security;
alter table finance.penalties enable row level security;

-- السياسات
create policy factories_select on public.factories for select to authenticated
  using (public.is_chairman() or id = public.my_factory_id());
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_chairman());
create policy shifts_select on public.shifts for select to authenticated
  using (public.can_access_factory(factory_id));
create policy employees_select on public.employees for select to authenticated
  using (public.can_access_factory(factory_id));
create policy assignments_select on public.employee_factory_assignments for select to authenticated
  using (public.can_access_factory(factory_id));
create policy attendance_select on public.attendance for select to authenticated
  using (public.can_access_factory(factory_id));
create policy advances_select on public.advances for select to authenticated
  using (public.can_access_factory(factory_id));
create policy employee_notes_select on public.employee_notes for select to authenticated
  using (public.can_access_factory(factory_id));
create policy holidays_select on public.holidays for select to authenticated
  using (public.require_actor() is not null);
create policy system_settings_select on public.system_settings for select to authenticated
  using (public.is_chairman());
create policy management_attendance_select on public.management_attendance for select to authenticated
  using (public.is_chairman());
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (public.is_chairman());

-- الجداول المالية: سياسة لرئيس المجلس كطبقة دفاع إضافية (لا منح أصلاً)
create policy wage_history_chairman on finance.employee_wage_history for select to authenticated using (public.is_chairman());
create policy payroll_periods_chairman on finance.payroll_periods for select to authenticated using (public.is_chairman());
create policy payroll_items_chairman on finance.payroll_items for select to authenticated using (public.is_chairman());
create policy payroll_payments_chairman on finance.payroll_payments for select to authenticated using (public.is_chairman());
create policy advance_repayments_chairman on finance.advance_repayments for select to authenticated using (public.is_chairman());
create policy bonuses_chairman on finance.bonuses for select to authenticated using (public.is_chairman());
create policy penalties_chairman on finance.penalties for select to authenticated using (public.is_chairman());
