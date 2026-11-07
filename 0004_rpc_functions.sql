-- 0004: دوال RPC الآمنة. كل كتابة تمر منها، والهوية من auth.uid() فقط.

-- تعديل الحارس: زيادة الرصيد مسموحة فقط عند إعادة فتح أسبوع
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

create or replace function finance.wage_on(p_employee uuid, p_date date)
returns numeric language plpgsql stable security definer set search_path = public, finance as $$
declare v numeric;
begin
  select w.daily_wage into v from finance.employee_wage_history w
  where w.employee_id = p_employee and w.effective_from <= p_date
  order by w.effective_from desc limit 1;
  if v is null then
    raise exception 'MISSING_WAGE: لا توجد يومية مسجلة للعامل بتاريخ %', p_date;
  end if;
  return v;
end $$;

-- ===== إدارة الحسابات (رئيس المجلس) =====
create or replace function public.link_manager_account(p_user uuid, p_username text, p_full_name text, p_factory uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_actor uuid := public.require_chairman();
begin
  perform public.require_reason(p_reason);
  if not exists (select 1 from auth.users u where u.id = p_user) then
    raise exception 'USER_NOT_FOUND: الحساب غير موجود في Auth';
  end if;
  if not exists (select 1 from public.factories f where f.id = p_factory and f.is_active) then
    raise exception 'FACTORY_NOT_FOUND';
  end if;
  perform set_config('app.change_reason', btrim(p_reason), true);
  insert into public.profiles (id, username, full_name, role, factory_id, is_active, created_by)
  values (p_user, p_username, btrim(p_full_name), 'factory_manager', p_factory, true, v_actor);
  return p_user;
end $$;

create or replace function public.set_manager_status(p_user uuid, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_chairman();
  perform public.require_reason(p_reason);
  if p_user = auth.uid() then raise exception 'SELF_CHANGE: لا يمكن تغيير حالة حسابك بنفسك'; end if;
  perform set_config('app.profile_admin', 'on', true);
  perform set_config('app.change_reason', btrim(p_reason), true);
  update public.profiles set is_active = p_active
  where id = p_user and role = 'factory_manager';
  if not found then raise exception 'NOT_FOUND: مدير غير موجود'; end if;
end $$;

create or replace function public.change_manager_factory(p_user uuid, p_factory uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_chairman();
  perform public.require_reason(p_reason);
  if not exists (select 1 from public.factories f where f.id = p_factory and f.is_active) then
    raise exception 'FACTORY_NOT_FOUND';
  end if;
  perform set_config('app.profile_admin', 'on', true);
  perform set_config('app.change_reason', btrim(p_reason), true);
  update public.profiles set factory_id = p_factory
  where id = p_user and role = 'factory_manager';
  if not found then raise exception 'NOT_FOUND: مدير غير موجود'; end if;
end $$;

create or replace function public.set_system_setting(p_key text, p_value jsonb, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor uuid := public.require_chairman();
begin
  perform public.require_reason(p_reason);
  if p_key not in ('overtime_policy','late_deduction_policy','leave_policy','mission_policy') then
    raise exception 'UNKNOWN_SETTING';
  end if;
  perform set_config('app.change_reason', btrim(p_reason), true);
  insert into public.system_settings (key, value, updated_by) values (p_key, p_value, v_actor)
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
end $$;

-- ===== العمال والنقل =====
create or replace function public.create_employee(p_factory uuid, p_full_name text, p_job_title text, p_phone text,
  p_start_date date, p_shift uuid, p_notes text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_actor uuid := public.require_factory_access(p_factory); v_id uuid;
begin
  if length(btrim(coalesce(p_full_name,''))) = 0 then raise exception 'NAME_REQUIRED'; end if;
  insert into public.employees (factory_id, full_name, job_title, phone, start_date, shift_id, notes, created_by)
  values (p_factory, btrim(p_full_name), nullif(btrim(p_job_title),''), nullif(btrim(p_phone),''),
          p_start_date, p_shift, nullif(btrim(p_notes),''), v_actor)
  returning id into v_id;
  insert into public.employee_factory_assignments (employee_id, factory_id, valid_from, transfer_reason, performed_by)
  values (v_id, p_factory, p_start_date, 'تعيين', v_actor);
  return v_id;
end $$;

create or replace function public.update_employee(p_id uuid, p_full_name text, p_job_title text, p_phone text,
  p_shift uuid, p_status text, p_notes text)
returns void language plpgsql security definer set search_path = public as $$
declare v_factory uuid;
begin
  select e.factory_id into v_factory from public.employees e where e.id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.require_factory_access(v_factory);
  if p_status not in ('active','suspended','resigned') then raise exception 'INVALID_STATUS'; end if;
  update public.employees set
    full_name = btrim(p_full_name), job_title = nullif(btrim(p_job_title),''),
    phone = nullif(btrim(p_phone),''), shift_id = p_shift, status = p_status,
    notes = nullif(btrim(p_notes),'')
  where id = p_id;
end $$;

create or replace function public.transfer_employee(p_employee uuid, p_to_factory uuid, p_effective_date date, p_reason text)
returns uuid language plpgsql security definer set search_path = public, finance as $$
declare
  v_actor uuid := public.require_chairman();
  v_emp public.employees%rowtype;
  v_cur public.employee_factory_assignments%rowtype;
begin
  perform public.require_reason(p_reason);
  if extract(isodow from p_effective_date) <> 6 then
    raise exception 'TRANSFER_DATE: النقل يسري من يوم السبت (بداية الأسبوع المالي) فقط';
  end if;
  select * into v_emp from public.employees where id = p_employee for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_emp.status = 'resigned' then raise exception 'EMPLOYEE_RESIGNED: لا يمكن نقل عامل مستقيل'; end if;
  select * into v_cur from public.employee_factory_assignments
  where employee_id = p_employee and valid_to is null;
  if not found then raise exception 'NO_CURRENT_ASSIGNMENT'; end if;
  if v_cur.factory_id = p_to_factory then raise exception 'SAME_FACTORY'; end if;
  if v_cur.valid_from > p_effective_date then raise exception 'TRANSFER_BEFORE_ASSIGNMENT'; end if;
  if not exists (select 1 from public.factories where id = p_to_factory and is_active) then
    raise exception 'FACTORY_NOT_FOUND';
  end if;
  if exists (select 1 from finance.payroll_items where employee_id = p_employee and week_start >= p_effective_date) then
    raise exception 'TRANSFER_BLOCKED: توجد كشوف رواتب بعد تاريخ النقل';
  end if;
  if exists (select 1 from public.attendance where employee_id = p_employee and work_date >= p_effective_date) then
    raise exception 'TRANSFER_BLOCKED: يوجد حضور مسجل بعد تاريخ النقل';
  end if;

  perform set_config('app.transfer_op', 'on', true);
  perform set_config('app.change_reason', btrim(p_reason), true);
  update public.employee_factory_assignments set valid_to = p_effective_date where id = v_cur.id;
  insert into public.employee_factory_assignments (employee_id, factory_id, valid_from, transfer_reason, performed_by)
  values (p_employee, p_to_factory, p_effective_date, btrim(p_reason), v_actor);
  update public.employees set factory_id = p_to_factory, shift_id = null where id = p_employee;
  return p_employee;
end $$;

create or replace function public.set_daily_wage(p_employee uuid, p_wage numeric, p_effective_from date, p_reason text)
returns uuid language plpgsql security definer set search_path = public, finance as $$
declare
  v_actor uuid := public.require_chairman();
  v_locked_until date;
  v_id uuid;
begin
  perform public.require_reason(p_reason);
  if p_wage is null or p_wage < 0 then raise exception 'INVALID_WAGE'; end if;
  if not exists (select 1 from public.employees where id = p_employee) then raise exception 'NOT_FOUND'; end if;
  select max(pp.week_end) into v_locked_until
  from finance.payroll_items pi join finance.payroll_periods pp on pp.id = pi.payroll_period_id
  where pi.employee_id = p_employee and pp.status in ('approved','closed');
  if v_locked_until is not null and p_effective_from <= v_locked_until then
    raise exception 'WAGE_LOCKED: لا يؤثر تغيير اليومية على أسبوع معتمد (آخر أسبوع معتمد ينتهي %)', v_locked_until;
  end if;
  perform set_config('app.finance_op', 'on', true);
  perform set_config('app.change_reason', btrim(p_reason), true);
  insert into finance.employee_wage_history (employee_id, daily_wage, effective_from, reason, set_by)
  values (p_employee, p_wage, p_effective_from, btrim(p_reason), v_actor)
  returning id into v_id;
  return v_id;
end $$;

-- ===== الحضور والانصراف =====
create or replace function public.record_attendance(p_employee uuid, p_shift uuid, p_work_date date, p_status text,
  p_check_in timestamptz, p_check_out timestamptz, p_notes text)
returns uuid language plpgsql security definer set search_path = public, finance as $$
declare v_actor uuid := public.require_actor(); v_factory uuid; v_id uuid;
begin
  v_factory := public.employee_factory_on(p_employee, p_work_date);
  if v_factory is null then raise exception 'NOT_ASSIGNED: العامل غير مرتبط بمصنع في هذا التاريخ'; end if;
  perform public.require_factory_access(v_factory);
  begin
    insert into public.attendance (factory_id, employee_id, shift_id, work_date, status,
                                   check_in_at, check_out_at, notes, recorded_by)
    values (v_factory, p_employee, p_shift, p_work_date, p_status,
            p_check_in, p_check_out, nullif(btrim(p_notes),''), v_actor)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'DUPLICATE_ATTENDANCE: تم تسجيل حضور هذا العامل في هذه الوردية لهذا اليوم';
  end;
  return v_id;
end $$;

create or replace function public.record_attendance_bulk(p_rows jsonb)
returns int language plpgsql security definer set search_path = public, finance as $$
declare r jsonb; v_count int := 0;
begin
  perform public.require_actor();
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'INVALID_INPUT: يجب أن تكون القائمة مصفوفة'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    perform public.record_attendance(
      (r->>'employee_id')::uuid, (r->>'shift_id')::uuid, (r->>'work_date')::date, r->>'status',
      nullif(r->>'check_in_at','')::timestamptz, nullif(r->>'check_out_at','')::timestamptz, r->>'notes');
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

create or replace function public.update_attendance(p_id uuid, p_status text, p_check_in timestamptz,
  p_check_out timestamptz, p_notes text, p_reason text)
returns void language plpgsql security definer set search_path = public, finance as $$
declare
  a public.attendance%rowtype;
  v_week_status text;
begin
  perform public.require_actor();
  select * into a from public.attendance where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.require_factory_access(a.factory_id);
  select pp.status into v_week_status from finance.payroll_periods pp
  where pp.factory_id = a.factory_id and pp.week_start = public.week_start_of(a.work_date);
  if v_week_status is not null and v_week_status <> 'open' then
    perform public.require_chairman();
    perform public.require_reason(p_reason);
    perform set_config('app.allow_locked_edit', 'on', true);
  end if;
  perform set_config('app.change_reason', coalesce(btrim(p_reason), ''), true);
  update public.attendance set status = p_status, check_in_at = p_check_in,
    check_out_at = p_check_out, notes = nullif(btrim(p_notes),'')
  where id = p_id;
end $$;

create or replace function public.get_week_status(p_factory uuid, p_date date)
returns text language plpgsql stable security definer set search_path = public, finance as $$
declare v text;
begin
  perform public.require_factory_access(p_factory);
  select pp.status into v from finance.payroll_periods pp
  where pp.factory_id = p_factory and pp.week_start = public.week_start_of(p_date);
  return coalesce(v, 'open');
end $$;

create or replace function public.add_employee_note(p_employee uuid, p_type text, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_factory uuid; v_actor uuid; v_id uuid;
begin
  select e.factory_id into v_factory from public.employees e where e.id = p_employee;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_actor := public.require_factory_access(v_factory);
  insert into public.employee_notes (factory_id, employee_id, note_type, body, created_by)
  values (v_factory, p_employee, p_type, btrim(p_body), v_actor)
  returning id into v_id;
  return v_id;
end $$;

-- ===== السلف =====
create or replace function public.create_advance(p_employee uuid, p_amount numeric, p_given_on date, p_reason text,
  p_method text, p_weekly numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := public.require_actor();
  v_factory uuid;
  v_id uuid;
begin
  select coalesce(public.employee_factory_on(p_employee, p_given_on), e.factory_id)
    into v_factory from public.employees e where e.id = p_employee;
  if v_factory is null then raise exception 'NOT_FOUND'; end if;
  perform public.require_factory_access(v_factory);
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;
  if p_method = 'full' and p_weekly is not null then raise exception 'INVALID_METHOD'; end if;
  if p_method = 'installments' and (p_weekly is null or p_weekly <= 0 or p_weekly > p_amount) then
    raise exception 'INVALID_WEEKLY: مبلغ الخصم الأسبوعي غير صالح';
  end if;
  perform set_config('app.advance_op', 'on', true);
  insert into public.advances (factory_id, employee_id, amount, given_on, reason, deduction_method,
                               weekly_deduction, balance_remaining, recorded_by)
  values (v_factory, p_employee, p_amount, p_given_on, nullif(btrim(p_reason),''), p_method,
          case when p_method = 'installments' then p_weekly else null end, p_amount, v_actor)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.cancel_advance(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_chairman();
  perform public.require_reason(p_reason);
  if exists (select 1 from finance.advance_repayments where advance_id = p_id) then
    raise exception 'ADVANCE_HAS_REPAYMENTS: لا يمكن إلغاء سلفة بها خصومات مسجلة';
  end if;
  perform set_config('app.advance_op', 'on', true);
  perform set_config('app.change_reason', btrim(p_reason), true);
  update public.advances set status = 'cancelled' where id = p_id and status = 'open';
  if not found then raise exception 'NOT_OPEN: السلفة ليست مفتوحة'; end if;
end $$;

-- ===== الجزاءات والمكافآت (رئيس المجلس فقط) =====
create or replace function public.add_adjustment(p_kind text, p_employee uuid, p_event_date date,
  p_amount numeric, p_reason text)
returns uuid language plpgsql security definer set search_path = public, finance as $$
declare
  v_actor uuid := public.require_chairman();
  v_factory uuid;
  v_id uuid;
begin
  perform public.require_reason(p_reason);
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;
  select coalesce(public.employee_factory_on(p_employee, p_event_date), e.factory_id)
    into v_factory from public.employees e where e.id = p_employee;
  if v_factory is null then raise exception 'NOT_FOUND'; end if;
  perform set_config('app.finance_op', 'on', true);
  if p_kind = 'bonus' then
    insert into finance.bonuses (factory_id, employee_id, event_date, reason, amount, recorded_by)
    values (v_factory, p_employee, p_event_date, btrim(p_reason), p_amount, v_actor) returning id into v_id;
  elsif p_kind = 'penalty' then
    insert into finance.penalties (factory_id, employee_id, event_date, reason, amount, recorded_by)
    values (v_factory, p_employee, p_event_date, btrim(p_reason), p_amount, v_actor) returning id into v_id;
  else
    raise exception 'INVALID_KIND';
  end if;
  return v_id;
end $$;

create or replace function public.decide_adjustment(p_kind text, p_id uuid, p_approve boolean, p_reason text)
returns void language plpgsql security definer set search_path = public, finance as $$
declare v_actor uuid := public.require_chairman(); v_status text;
begin
  perform public.require_reason(p_reason);
  perform set_config('app.finance_op', 'on', true);
  perform set_config('app.change_reason', btrim(p_reason), true);
  if p_kind = 'bonus' then
    select b.approval_status into v_status from finance.bonuses b where b.id = p_id for update;
    if v_status is distinct from 'pending' then raise exception 'NOT_PENDING'; end if;
    update finance.bonuses set approval_status = case when p_approve then 'approved' else 'rejected' end,
      approved_by = v_actor, approved_at = now() where id = p_id;
  elsif p_kind = 'penalty' then
    select b.approval_status into v_status from finance.penalties b where b.id = p_id for update;
    if v_status is distinct from 'pending' then raise exception 'NOT_PENDING'; end if;
    update finance.penalties set approval_status = case when p_approve then 'approved' else 'rejected' end,
      approved_by = v_actor, approved_at = now() where id = p_id;
  else
    raise exception 'INVALID_KIND';
  end if;
end $$;

-- ===== حساب الأسبوع (كل الحساب داخل قاعدة البيانات) =====
create or replace function public.calculate_payroll_week(p_factory uuid, p_week_start date)
returns jsonb language plpgsql security definer set search_path = public, finance as $$
declare
  v_actor uuid := public.require_chairman();
  v_period finance.payroll_periods%rowtype;
  v_week_end date := p_week_start + 6;
  v_emp record;
  v_row record;
  v_day date;
  v_p boolean; v_m boolean; v_l boolean; v_a boolean;
  v_wage numeric;
  v_gross_reg numeric; v_gross_fri numeric; v_lm numeric; v_ot numeric;
  v_bonus numeric; v_pen numeric; v_other numeric; v_adv numeric;
  v_total numeric; v_net numeric;
  v_reg int; v_fri int; v_abs int; v_leave int; v_mission int;
  v_late_min int;
  v_item_id uuid;
  v_count int := 0;
  v_ot_enabled boolean; v_ot_rate numeric;
  v_late_enabled boolean; v_late_rate numeric;
  v_leave_factor numeric; v_mission_factor numeric;
  v_bon_ids uuid[]; v_pen_ids uuid[];
  v_adv_ids uuid[]; v_adv_amts numeric[];
  v_due numeric; v_ded numeric;
  i int;
begin
  if extract(isodow from p_week_start) <> 6 then raise exception 'WEEK_START: الأسبوع يبدأ يوم السبت'; end if;
  if not exists (select 1 from public.factories where id = p_factory and is_active) then
    raise exception 'FACTORY_NOT_FOUND';
  end if;

  perform set_config('app.finance_op', 'on', true);
  perform set_config('app.advance_op', 'on', true);
  perform set_config('app.change_reason', 'حساب الكشف الأسبوعي', true);

  select * into v_period from finance.payroll_periods
  where factory_id = p_factory and week_start = p_week_start for update;
  if not found then
    insert into finance.payroll_periods (factory_id, week_start, status)
    values (p_factory, p_week_start, 'open') returning * into v_period;
  end if;
  if v_period.status <> 'open' then
    raise exception 'PERIOD_NOT_OPEN: حالة الأسبوع الحالية %', v_period.status;
  end if;

  v_ot_enabled := coalesce((select (s.value->>'enabled')::boolean from public.system_settings s where s.key='overtime_policy'), false);
  v_ot_rate := coalesce((select (s.value->>'rate_multiplier')::numeric from public.system_settings s where s.key='overtime_policy'), 1);
  v_late_enabled := coalesce((select (s.value->>'enabled')::boolean from public.system_settings s where s.key='late_deduction_policy'), false);
  v_late_rate := coalesce((select (s.value->>'per_minute')::numeric from public.system_settings s where s.key='late_deduction_policy'), 0);
  v_leave_factor := coalesce((select (s.value->>'paid_factor')::numeric from public.system_settings s where s.key='leave_policy'), 0);
  v_mission_factor := coalesce((select (s.value->>'paid_factor')::numeric from public.system_settings s where s.key='mission_policy'), 0);

  for v_emp in
    select distinct a.employee_id from public.attendance a
    where a.factory_id = p_factory and a.work_date between p_week_start and v_week_end
    order by a.employee_id
  loop
    v_gross_reg := 0; v_gross_fri := 0; v_lm := 0; v_ot := 0;
    v_reg := 0; v_fri := 0; v_abs := 0; v_leave := 0; v_mission := 0;
    v_bon_ids := '{}'; v_pen_ids := '{}'; v_adv_ids := '{}'; v_adv_amts := '{}';

    for v_day in select generate_series(p_week_start, v_week_end, interval '1 day')::date loop
      select bool_or(a.status='present'), bool_or(a.status='mission'),
             bool_or(a.status='leave'), bool_or(a.status='absent')
        into v_p, v_m, v_l, v_a
      from public.attendance a
      where a.employee_id = v_emp.employee_id and a.factory_id = p_factory and a.work_date = v_day;

      if coalesce(v_p, false) then
        v_wage := finance.wage_on(v_emp.employee_id, v_day);
        if extract(isodow from v_day) = 5 then
          v_gross_fri := v_gross_fri + round(v_wage * 1.5, 4); v_fri := v_fri + 1;
        else
          v_gross_reg := v_gross_reg + round(v_wage, 4); v_reg := v_reg + 1;
        end if;
      elsif coalesce(v_m, false) then
        v_wage := finance.wage_on(v_emp.employee_id, v_day);
        v_lm := v_lm + round(v_wage * v_mission_factor, 4); v_mission := v_mission + 1;
      elsif coalesce(v_l, false) then
        v_wage := finance.wage_on(v_emp.employee_id, v_day);
        v_lm := v_lm + round(v_wage * v_leave_factor, 4); v_leave := v_leave + 1;
      elsif coalesce(v_a, false) then
        v_abs := v_abs + 1;
      end if;
    end loop;

    if v_ot_enabled then
      for v_row in
        select a.work_date, a.overtime_hours, s.required_hours
        from public.attendance a join public.shifts s on s.id = a.shift_id
        where a.employee_id = v_emp.employee_id and a.factory_id = p_factory
          and a.work_date between p_week_start and v_week_end
          and a.status = 'present' and a.overtime_hours > 0
      loop
        v_ot := v_ot + round(v_row.overtime_hours * finance.wage_on(v_emp.employee_id, v_row.work_date)
                             / v_row.required_hours * v_ot_rate, 4);
      end loop;
    end if;

    select coalesce(sum(b.amount), 0), coalesce(array_agg(b.id), '{}')
      into v_bonus, v_bon_ids
    from finance.bonuses b
    where b.employee_id = v_emp.employee_id and b.approval_status = 'approved' and b.applied_payroll_item_id is null;

    v_total := v_gross_reg + v_gross_fri + v_lm + v_bonus + v_ot;

    v_other := 0;
    if v_late_enabled then
      select coalesce(sum(a.late_minutes), 0) into v_late_min from public.attendance a
      where a.employee_id = v_emp.employee_id and a.factory_id = p_factory
        and a.work_date between p_week_start and v_week_end and a.status = 'present';
      v_other := round(v_late_min * v_late_rate, 4);
    end if;
    v_other := least(v_other, v_total);

    v_pen := 0;
    for v_row in
      select p.id, p.amount from finance.penalties p
      where p.employee_id = v_emp.employee_id and p.approval_status = 'approved'
        and p.applied_payroll_item_id is null
      order by p.event_date, p.created_at
    loop
      if v_pen + v_row.amount <= v_total - v_other then
        v_pen := v_pen + v_row.amount;
        v_pen_ids := array_append(v_pen_ids, v_row.id);
      end if;
    end loop;

    v_adv := 0;
    for v_row in
      select sa.id, sa.deduction_method, sa.weekly_deduction, sa.balance_remaining
      from public.advances sa
      where sa.employee_id = v_emp.employee_id and sa.status = 'open' and sa.balance_remaining > 0
      order by sa.given_on, sa.created_at
    loop
      if v_row.deduction_method = 'full' then v_due := v_row.balance_remaining;
      else v_due := least(v_row.weekly_deduction, v_row.balance_remaining); end if;
      v_ded := least(v_due, v_total - v_other - v_pen - v_adv);
      if v_ded > 0 then
        v_adv := v_adv + v_ded;
        v_adv_ids := array_append(v_adv_ids, v_row.id);
        v_adv_amts := array_append(v_adv_amts, v_ded);
      end if;
    end loop;

    v_net := v_total - v_other - v_pen - v_adv;

    insert into finance.payroll_items (
      payroll_period_id, factory_id, employee_id, week_start,
      regular_days, friday_days, absent_days, leave_days, mission_days,
      gross_regular, gross_friday, leave_mission_pay, bonuses_total, overtime_total, total_due,
      advance_deduction, penalties_total, other_deductions, net_due,
      paid_total, remaining_due, payment_status)
    values (
      v_period.id, p_factory, v_emp.employee_id, p_week_start,
      v_reg, v_fri, v_abs, v_leave, v_mission,
      v_gross_reg, v_gross_fri, v_lm, v_bonus, v_ot, v_total,
      v_adv, v_pen, v_other, v_net,
      0, v_net, case when v_net = 0 then 'paid' else 'unpaid' end)
    returning id into v_item_id;

    if array_length(v_bon_ids, 1) is not null then
      update finance.bonuses set applied_payroll_item_id = v_item_id where id = any(v_bon_ids);
    end if;
    if array_length(v_pen_ids, 1) is not null then
      update finance.penalties set applied_payroll_item_id = v_item_id where id = any(v_pen_ids);
    end if;
    for i in 1 .. coalesce(array_length(v_adv_ids, 1), 0) loop
      insert into finance.advance_repayments (advance_id, payroll_item_id, factory_id, amount)
      values (v_adv_ids[i], v_item_id, p_factory, v_adv_amts[i]);
      update public.advances set balance_remaining = balance_remaining - v_adv_amts[i],
        status = case when balance_remaining - v_adv_amts[i] = 0 then 'settled' else status end
      where id = v_adv_ids[i];
    end loop;

    v_count := v_count + 1;
  end loop;

  update finance.payroll_periods set status = 'calculated', calculated_by = v_actor, calculated_at = now()
  where id = v_period.id;

  return jsonb_build_object('period_id', v_period.id, 'week_start', p_week_start, 'items', v_count);
end $$;

create or replace function public.approve_payroll_week(p_factory uuid, p_week_start date)
returns void language plpgsql security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  perform set_config('app.finance_op', 'on', true);
  update finance.payroll_periods set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where factory_id = p_factory and week_start = p_week_start and status = 'calculated';
  if not found then raise exception 'INVALID_TRANSITION: يُعتمد الأسبوع بعد حسابه فقط'; end if;
end $$;

create or replace function public.close_payroll_week(p_factory uuid, p_week_start date)
returns void language plpgsql security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  perform set_config('app.finance_op', 'on', true);
  update finance.payroll_periods set status = 'closed', closed_by = auth.uid(), closed_at = now()
  where factory_id = p_factory and week_start = p_week_start and status = 'approved';
  if not found then raise exception 'INVALID_TRANSITION: يُغلق الأسبوع بعد اعتماده فقط'; end if;
end $$;

create or replace function public.reopen_payroll_week(p_factory uuid, p_week_start date, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, finance as $$
declare
  v_period finance.payroll_periods%rowtype;
  v_rep record;
  v_pay int;
begin
  perform public.require_chairman();
  perform public.require_reason(p_reason);
  select * into v_period from finance.payroll_periods
  where factory_id = p_factory and week_start = p_week_start for update;
  if not found or v_period.status = 'open' then raise exception 'NOT_REOPENABLE'; end if;

  select count(*) into v_pay from finance.payroll_payments p
  join finance.payroll_items i on i.id = p.payroll_item_id
  where i.payroll_period_id = v_period.id;
  if v_pay > 0 then
    raise exception 'PAYMENTS_EXIST: لا يُعاد فتح أسبوع فيه دفعات مسجلة';
  end if;

  perform set_config('app.finance_op', 'on', true);
  perform set_config('app.advance_op', 'on', true);
  perform set_config('app.advance_restore', 'on', true);
  perform set_config('app.change_reason', btrim(p_reason), true);

  for v_rep in
    select r.id, r.advance_id, r.amount from finance.advance_repayments r
    join finance.payroll_items i on i.id = r.payroll_item_id
    where i.payroll_period_id = v_period.id
  loop
    update public.advances set balance_remaining = balance_remaining + v_rep.amount, status = 'open'
    where id = v_rep.advance_id;
    delete from finance.advance_repayments where id = v_rep.id;
  end loop;
  update finance.bonuses set applied_payroll_item_id = null
  where applied_payroll_item_id in (select id from finance.payroll_items where payroll_period_id = v_period.id);
  update finance.penalties set applied_payroll_item_id = null
  where applied_payroll_item_id in (select id from finance.payroll_items where payroll_period_id = v_period.id);
  delete from finance.payroll_items where payroll_period_id = v_period.id;
  update finance.payroll_periods set status = 'open', calculated_by = null, calculated_at = null,
    approved_by = null, approved_at = null, closed_by = null, closed_at = null
  where id = v_period.id;

  return jsonb_build_object('reopened', true, 'week_start', p_week_start);
end $$;

-- ===== الدفعات (داخل Transaction مع قفل صف الكشف) =====
create or replace function public.record_payroll_payment(p_item uuid, p_amount numeric, p_method text,
  p_reference text, p_notes text, p_idempotency_key text)
returns uuid language plpgsql security definer set search_path = public, finance as $$
declare
  v_actor uuid := public.require_chairman();
  v_item finance.payroll_items%rowtype;
  v_period_status text;
  v_existing uuid;
  v_id uuid;
begin
  if p_idempotency_key is null or length(p_idempotency_key) < 8 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  select id into v_existing from finance.payroll_payments where idempotency_key = p_idempotency_key;
  if v_existing is not null then return v_existing; end if;

  select * into v_item from finance.payroll_items where id = p_item for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select status into v_period_status from finance.payroll_periods where id = v_item.payroll_period_id;
  if v_period_status not in ('approved','closed') then
    raise exception 'NOT_APPROVED: لا يُصرف الراتب قبل اعتماد الأسبوع';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;
  if p_amount > v_item.remaining_due then
    raise exception 'OVERPAY: المبلغ يتجاوز المتبقي (%)', v_item.remaining_due;
  end if;

  perform set_config('app.finance_op', 'on', true);
  perform set_config('app.change_reason', 'صرف راتب', true);
  insert into finance.payroll_payments (payroll_item_id, factory_id, amount, method, reference_no, notes,
                                        idempotency_key, recorded_by)
  values (p_item, v_item.factory_id, p_amount, p_method, nullif(btrim(p_reference),''),
          nullif(btrim(p_notes),''), p_idempotency_key, v_actor)
  returning id into v_id;

  update finance.payroll_items set
    paid_total = paid_total + p_amount,
    remaining_due = remaining_due - p_amount,
    payment_status = case when remaining_due - p_amount = 0 then 'paid' else 'partial' end
  where id = p_item;
  return v_id;
end $$;

create or replace function public.confirm_payroll_receipt(p_payment uuid, p_signature_path text)
returns void language plpgsql security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  perform set_config('app.finance_op', 'on', true);
  update finance.payroll_payments set employee_confirmed = true, employee_confirmed_at = now(),
    signature_storage_path = nullif(btrim(p_signature_path),'')
  where id = p_payment;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- ===== حضور الإدارة (رئيس المجلس) =====
create or replace function public.record_management_attendance(p_person uuid, p_work_date date,
  p_check_in timestamptz, p_check_out timestamptz, p_notes text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_actor uuid := public.require_chairman(); v_id uuid;
begin
  insert into public.management_attendance (person_id, factory_id, work_date, check_in_at, check_out_at,
                                            worked_hours, notes, recorded_by)
  values (p_person, (select p.factory_id from public.profiles p where p.id = p_person), p_work_date,
          p_check_in, p_check_out,
          case when p_check_in is not null and p_check_out is not null
               then round((extract(epoch from (p_check_out - p_check_in)) / 3600)::numeric, 2) else 0 end,
          nullif(btrim(p_notes),''), v_actor)
  returning id into v_id;
  return v_id;
end $$;

-- ===== قراءات رئيس المجلس المالية =====
create or replace function public.get_payroll_week(p_factory uuid, p_week_start date)
returns setof finance.payroll_items language plpgsql stable security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  return query select i.* from finance.payroll_items i
    where i.factory_id = p_factory and i.week_start = p_week_start
    order by i.employee_id;
end $$;

create or replace function public.get_finance_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  return jsonb_build_object(
    'by_factory', coalesce((
      select jsonb_agg(x order by x.code) from (
        select f.code, f.name_ar,
          coalesce(sum(i.total_due), 0) as total_due,
          coalesce(sum(i.net_due), 0) as net_due,
          coalesce(sum(i.paid_total), 0) as paid,
          coalesce(sum(i.remaining_due), 0) as remaining,
          coalesce(sum(i.bonuses_total), 0) as bonuses,
          coalesce(sum(i.penalties_total), 0) as penalties,
          coalesce(sum(i.advance_deduction), 0) as advances_deducted,
          coalesce(sum(i.overtime_total), 0) as overtime
        from public.factories f
        left join finance.payroll_items i on i.factory_id = f.id and i.week_start between p_from and p_to
        group by f.id, f.code, f.name_ar
      ) x), '[]'::jsonb),
    'outstanding_advances', (select coalesce(sum(a.balance_remaining), 0) from public.advances a where a.status = 'open')
  );
end $$;

create or replace function public.get_wage_history(p_employee uuid)
returns setof finance.employee_wage_history language plpgsql stable security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  return query select w.* from finance.employee_wage_history w
    where w.employee_id = p_employee order by w.effective_from desc;
end $$;

create or replace function public.export_backup()
returns jsonb language plpgsql stable security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  return jsonb_build_object(
    'exported_at', now(),
    'factories', (select coalesce(jsonb_agg(t), '[]') from public.factories t),
    'shifts', (select coalesce(jsonb_agg(t), '[]') from public.shifts t),
    'employees', (select coalesce(jsonb_agg(t), '[]') from public.employees t),
    'employee_factory_assignments', (select coalesce(jsonb_agg(t), '[]') from public.employee_factory_assignments t),
    'attendance', (select coalesce(jsonb_agg(t), '[]') from public.attendance t),
    'advances', (select coalesce(jsonb_agg(t), '[]') from public.advances t),
    'employee_notes', (select coalesce(jsonb_agg(t), '[]') from public.employee_notes t),
    'management_attendance', (select coalesce(jsonb_agg(t), '[]') from public.management_attendance t),
    'holidays', (select coalesce(jsonb_agg(t), '[]') from public.holidays t),
    'system_settings', (select coalesce(jsonb_agg(t), '[]') from public.system_settings t),
    'audit_logs', (select coalesce(jsonb_agg(t), '[]') from public.audit_logs t),
    'wage_history', (select coalesce(jsonb_agg(t), '[]') from finance.employee_wage_history t),
    'payroll_periods', (select coalesce(jsonb_agg(t), '[]') from finance.payroll_periods t),
    'payroll_items', (select coalesce(jsonb_agg(t), '[]') from finance.payroll_items t),
    'payroll_payments', (select coalesce(jsonb_agg(t), '[]') from finance.payroll_payments t),
    'advance_repayments', (select coalesce(jsonb_agg(t), '[]') from finance.advance_repayments t),
    'bonuses', (select coalesce(jsonb_agg(t), '[]') from finance.bonuses t),
    'penalties', (select coalesce(jsonb_agg(t), '[]') from finance.penalties t)
  );
end $$;

-- ===== منح التنفيذ: للدوال المعلنة فقط =====
revoke all on all functions in schema public from anon, authenticated, public;
revoke all on all functions in schema finance from anon, authenticated, public;

grant execute on function public.is_chairman() to authenticated;
grant execute on function public.my_factory_id() to authenticated;
grant execute on function public.can_access_factory(uuid) to authenticated;
grant execute on function public.require_actor() to authenticated;

grant execute on function
  public.link_manager_account(uuid,text,text,uuid,text),
  public.set_manager_status(uuid,boolean,text),
  public.change_manager_factory(uuid,uuid,text),
  public.set_system_setting(text,jsonb,text),
  public.create_employee(uuid,text,text,text,date,uuid,text),
  public.update_employee(uuid,text,text,text,uuid,text,text),
  public.transfer_employee(uuid,uuid,date,text),
  public.set_daily_wage(uuid,numeric,date,text),
  public.record_attendance(uuid,uuid,date,text,timestamptz,timestamptz,text),
  public.record_attendance_bulk(jsonb),
  public.update_attendance(uuid,text,timestamptz,timestamptz,text,text),
  public.get_week_status(uuid,date),
  public.add_employee_note(uuid,text,text),
  public.create_advance(uuid,numeric,date,text,text,numeric),
  public.cancel_advance(uuid,text),
  public.add_adjustment(text,uuid,date,numeric,text),
  public.decide_adjustment(text,uuid,boolean,text),
  public.calculate_payroll_week(uuid,date),
  public.approve_payroll_week(uuid,date),
  public.close_payroll_week(uuid,date),
  public.reopen_payroll_week(uuid,date,text),
  public.record_payroll_payment(uuid,numeric,text,text,text,text),
  public.confirm_payroll_receipt(uuid,text),
  public.record_management_attendance(uuid,date,timestamptz,timestamptz,text),
  public.get_payroll_week(uuid,date),
  public.get_finance_summary(date,date),
  public.get_wage_history(uuid),
  public.export_backup()
to authenticated;
