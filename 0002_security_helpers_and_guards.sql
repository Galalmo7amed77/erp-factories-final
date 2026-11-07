-- 0002: دوال الهوية والصلاحيات، وحراس الكتابة، والحساب داخل قاعدة البيانات، وسجل العمليات.

-- ===== الهوية والصلاحيات (تعتمد على auth.uid() من JWT الموقّع فقط) =====
create or replace function public.is_chairman()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.role = 'chairman' and p.is_active);
$$;

create or replace function public.my_factory_id()
returns uuid language sql stable security definer set search_path = public as $$
  select p.factory_id from public.profiles p
  where p.id = auth.uid() and p.role = 'factory_manager' and p.is_active;
$$;

create or replace function public.can_access_factory(p_factory uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_chairman() or (p_factory is not null and p_factory = public.my_factory_id());
$$;

create or replace function public.require_actor()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'UNAUTHENTICATED: يتطلب تسجيل دخول' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles p where p.id = v and p.is_active) then
    raise exception 'UNAUTHORIZED: الحساب غير مفعّل' using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function public.require_chairman()
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_actor();
  if not public.is_chairman() then
    raise exception 'FORBIDDEN: هذه العملية لرئيس مجلس الإدارة فقط' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

create or replace function public.require_factory_access(p_factory uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_actor();
  if not public.can_access_factory(p_factory) then
    raise exception 'FORBIDDEN: لا صلاحية على هذا المصنع' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

create or replace function public.require_reason(p_reason text)
returns text language plpgsql immutable as $$
begin
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'REASON_REQUIRED: يجب كتابة سبب موثق للعملية';
  end if;
  return btrim(p_reason);
end $$;

create or replace function public.employee_factory_on(p_employee uuid, p_date date)
returns uuid language sql stable security definer set search_path = public as $$
  select a.factory_id from public.employee_factory_assignments a
  where a.employee_id = p_employee
    and a.valid_from <= p_date
    and (a.valid_to is null or p_date < a.valid_to);
$$;

-- بداية الأسبوع المالي: السبت = isodow 6
create or replace function public.week_start_of(p_date date)
returns date language sql immutable as $$
  select p_date - ((extract(isodow from p_date)::int - 6 + 7) % 7);
$$;

-- قفل الأسبوع: التعديل العادي فقط والأسبوع مفتوح
create or replace function public.assert_week_editable(p_factory uuid, p_date date)
returns void language plpgsql security definer set search_path = public, finance as $$
declare v_status text;
begin
  select pp.status into v_status from finance.payroll_periods pp
  where pp.factory_id = p_factory and pp.week_start = public.week_start_of(p_date);
  if v_status is null or v_status = 'open' then return; end if;
  if current_setting('app.allow_locked_edit', true) is distinct from 'on' then
    raise exception 'WEEK_LOCKED: الأسبوع % (%) غير مفتوح ولا يقبل التعديل العادي',
      public.week_start_of(p_date), v_status using errcode = 'P0001';
  end if;
end $$;

-- ===== حراس الكتابة المالية =====
create or replace function finance.guard_finance_write()
returns trigger language plpgsql security definer set search_path = public, finance as $$
begin
  if current_setting('app.finance_op', true) is distinct from 'on' then
    raise exception 'FINANCE_LOCKED: الكتابة المالية تتم فقط عبر دوال رئيس المجلس المعتمدة';
  end if;
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['employee_wage_history','payroll_periods','payroll_items',
                           'payroll_payments','advance_repayments','bonuses','penalties'] loop
    execute format('create trigger trg_guard_%s before insert or update or delete on finance.%I
                    for each row execute function finance.guard_finance_write()', t, t);
  end loop;
end $$;

-- ===== حراس السلف =====
create or replace function public.guard_advances()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('app.advance_op', true) is distinct from 'on' then
    raise exception 'ADVANCE_LOCKED: تعديل السلف يتم فقط عبر الدوال المعتمدة';
  end if;
  if tg_op = 'UPDATE' and new.balance_remaining > old.balance_remaining
     and current_setting('app.advance_restore', true) is distinct from 'on' then
    raise exception 'BALANCE_INCREASE: لا يمكن زيادة رصيد السلفة';
  end if;
  return coalesce(new, old);
end $$;
create trigger trg_guard_advances before insert or update or delete on public.advances
  for each row execute function public.guard_advances();

-- ===== حراس الحضور: الهوية والمصنع والحساب والقفل =====
create or replace function public.trg_attendance_guard()
returns trigger language plpgsql security definer set search_path = public, finance as $$
declare
  v_actor uuid := public.require_actor();
  v_assigned uuid;
  v_emp_status text;
  s public.shifts%rowtype;
  v_sched_start timestamptz;
  v_sched_end timestamptz;
begin
  if tg_op = 'INSERT' then
    new.recorded_by := v_actor;
    new.recorded_at := now();
    select e.status into v_emp_status from public.employees e where e.id = new.employee_id;
    if v_emp_status <> 'active' then
      raise exception 'EMPLOYEE_INACTIVE: العامل غير نشط';
    end if;
  else
    if new.recorded_by is distinct from old.recorded_by
       or new.recorded_at is distinct from old.recorded_at
       or new.employee_id is distinct from old.employee_id
       or new.factory_id is distinct from old.factory_id
       or new.work_date is distinct from old.work_date
       or new.shift_id is distinct from old.shift_id then
      raise exception 'IMMUTABLE: الحقول الأساسية للحضور لا تتغير بعد التسجيل';
    end if;
    new.updated_by := v_actor;
    new.updated_at := now();
  end if;

  v_assigned := public.employee_factory_on(new.employee_id, new.work_date);
  if v_assigned is null or v_assigned <> new.factory_id then
    raise exception 'FACTORY_MISMATCH: العامل لم يكن مرتبطاً بهذا المصنع في هذا التاريخ';
  end if;

  perform public.assert_week_editable(new.factory_id, new.work_date);

  -- الحساب داخل قاعدة البيانات بتوقيت القاهرة
  select * into s from public.shifts where id = new.shift_id;
  if new.status <> 'present' then
    new.check_in_at := null; new.check_out_at := null;
    new.worked_hours := 0; new.late_minutes := 0;
    new.early_leave_minutes := 0; new.overtime_hours := 0;
  else
    v_sched_start := ((new.work_date + s.start_time)::timestamp at time zone 'Africa/Cairo');
    v_sched_end := ((new.work_date + (case when s.is_night then 1 else 0 end) + s.end_time)::timestamp
                    at time zone 'Africa/Cairo');
    new.late_minutes := 0;
    new.early_leave_minutes := 0;
    new.worked_hours := 0;
    new.overtime_hours := 0;
    if new.check_in_at is not null then
      new.late_minutes := greatest(0, floor(extract(epoch from (new.check_in_at - v_sched_start)) / 60))::int;
    end if;
    if new.check_in_at is not null and new.check_out_at is not null then
      new.worked_hours := round((extract(epoch from (new.check_out_at - new.check_in_at)) / 3600)::numeric, 2);
      new.early_leave_minutes := greatest(0, floor(extract(epoch from (v_sched_end - new.check_out_at)) / 60))::int;
      new.overtime_hours := greatest(0, new.worked_hours - s.required_hours);
    end if;
  end if;
  return new;
end $$;
create trigger trg_attendance_guard before insert or update on public.attendance
  for each row execute function public.trg_attendance_guard();

create or replace function public.trg_attendance_no_delete()
returns trigger language plpgsql as $$
begin
  raise exception 'NO_DELETE: لا يُحذف سجل الحضور، يُصحَّح بالتعديل الموثق';
end $$;
create trigger trg_attendance_no_delete before delete on public.attendance
  for each row execute function public.trg_attendance_no_delete();

-- ===== حراس العمال: تغيير المصنع فقط عبر النقل المعتمد =====
create or replace function public.trg_employee_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'NO_DELETE: لا يُحذف العامل، يُوقف مع الاحتفاظ بسجله';
  end if;
  if new.factory_id is distinct from old.factory_id
     and current_setting('app.transfer_op', true) is distinct from 'on' then
    raise exception 'TRANSFER_LOCKED: النقل يتم فقط عبر دالة transfer_employee';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_employee_guard before update or delete on public.employees
  for each row execute function public.trg_employee_guard();

-- ===== حراس الحسابات: رئيس المجلس محمي =====
create or replace function public.trg_profile_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'NO_DELETE: لا يُحذف حساب، يُوقف تفعيله';
  end if;
  if old.role = 'chairman' then
    if new.is_active is distinct from true or new.role <> 'chairman' or new.id <> old.id then
      raise exception 'CHAIRMAN_PROTECTED: لا يمكن تعطيل حساب رئيس مجلس الإدارة أو تغيير دوره';
    end if;
  end if;
  if (new.role is distinct from old.role or new.factory_id is distinct from old.factory_id)
     and current_setting('app.profile_admin', true) is distinct from 'on' then
    raise exception 'PROFILE_LOCKED: تغيير الدور أو المصنع يتم فقط عبر دالة معتمدة';
  end if;
  return new;
end $$;
create trigger trg_profile_guard before update or delete on public.profiles
  for each row execute function public.trg_profile_guard();

-- ===== سجل العمليات التلقائي =====
create or replace function public.audit_row()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_username text;
  v_factory uuid;
  v_reason text := nullif(btrim(current_setting('app.change_reason', true)), '');
  v_record text;
begin
  if v_actor is not null then
    select username into v_username from public.profiles where id = v_actor;
  else
    v_username := 'system';
  end if;
  v_factory := coalesce((to_jsonb(new)->>'factory_id')::uuid, (to_jsonb(old)->>'factory_id')::uuid);
  v_record := coalesce(to_jsonb(new)->>'id', to_jsonb(old)->>'id', to_jsonb(new)->>'user_id');
  insert into public.audit_logs (actor_id, actor_username, factory_id, action, table_name,
                                 record_id, old_data, new_data, reason)
  values (v_actor, v_username, v_factory, tg_op, tg_table_schema || '.' || tg_table_name, v_record,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          v_reason);
  return coalesce(new, old);
end $$;

do $$
declare r record;
begin
  for r in select * from (values
    ('public','profiles'),('public','factories'),('public','shifts'),('public','employees'),
    ('public','employee_factory_assignments'),('public','attendance'),('public','advances'),
    ('public','employee_notes'),('public','management_attendance'),('public','holidays'),
    ('public','system_settings'),
    ('finance','employee_wage_history'),('finance','payroll_periods'),('finance','payroll_items'),
    ('finance','payroll_payments'),('finance','advance_repayments'),('finance','bonuses'),
    ('finance','penalties')) as x(sch, tbl)
  loop
    execute format('create trigger trg_audit_%s after insert or update or delete on %I.%I
                    for each row execute function public.audit_row()', r.tbl, r.sch, r.tbl);
  end loop;
end $$;
