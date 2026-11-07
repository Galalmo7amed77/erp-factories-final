-- اختبارات: المكافآت والجزاءات، الحضور بأكثر من وردية، حضور الإدارة
-- تُشغَّل كاملة في SQL Editor. النتيجة تظهر كرسالة TEST_REPORT وتُلغى كل البيانات.
create or replace function pg_temp.try_as(p_uid uuid, p_sql text, out ok boolean, out res text)
language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql into res;
    ok := true;
  exception when others then
    ok := false;
    res := sqlstate || ' ' || sqlerrm;
  end;
  execute 'reset role';
end $f$;

create temp table t_res (id serial primary key, name text, pass boolean, detail text);

do $$
declare
  C uuid := '54675bf6-aca8-4633-b717-a60e1019ca6e';
  F uuid := '9b1e2e9e-bb57-4679-9cb2-1e44927fe198';
  T uuid := 'e3c6cb75-138e-488f-9b0c-a524d0c8d670';
  FAT uuid := 'a6402de3-defe-4f71-a5dc-c9a61104ecff';
  FAT_M uuid := 'a0000000-0000-0000-0000-000000000001';
  FAT_N uuid := 'a0000000-0000-0000-0000-000000000002';
  E1 uuid := 'e0000000-0000-0000-0000-000000000001';
  v_bonus uuid; v_pen uuid; v_pen2 uuid; v_applied_b int; v_applied_p int;
begin
  perform set_config('app.finance_op', '', true);
  insert into public.shifts (id, factory_id, name, start_time, end_time, required_hours) values
    (FAT_M, FAT, 'صباحية', '08:00', '16:00', 8), (FAT_N, FAT, 'ليلية', '22:00', '06:00', 8);
  insert into public.employees (id, factory_id, full_name, start_date, shift_id) values (E1, FAT, 'موظف اختبار الفتاحة', '2026-10-01', FAT_M);
  insert into public.employee_factory_assignments (employee_id, factory_id, valid_from, transfer_reason) values (E1, FAT, '2026-10-01', 'تعيين');
  perform set_config('app.finance_op', 'on', true);
  insert into finance.employee_wage_history (employee_id, daily_wage, effective_from, reason, set_by) values (E1, 100, '2026-10-01', 'اختبار', C);
  perform set_config('app.finance_op', '', true);

  insert into t_res(name,pass,detail) select 'Q01 رئيس المجلس يقرأ قائمة المكافآت', (r.ok and r.res like '[%'), r.res from pg_temp.try_as(C, $q$select public.list_adjustments('bonus', null, '2026-11-01'::date, '2026-11-30'::date)::text$q$) r;
  insert into t_res(name,pass,detail) select 'Q02 مدير الفتاحة لا يقرأ قائمة المكافآت', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.list_adjustments('bonus', null, '2026-11-01'::date, '2026-11-30'::date)::text$q$) r;
  insert into t_res(name,pass,detail) select 'Q03 مدير الفتاحة لا يسجل مكافأة', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.add_adjustment('bonus','e0000000-0000-0000-0000-000000000001','2026-11-07'::date,50,'محاولة')::text$q$) r;
  insert into t_res(name,pass,detail) select 'Q04 رئيس المجلس يسجل مكافأة 50 (معلّقة)', r.ok, r.res from pg_temp.try_as(C, $q$select public.add_adjustment('bonus','e0000000-0000-0000-0000-000000000001','2026-11-07'::date,50,'أداء متميز')::text$q$) r;
  insert into t_res(name,pass,detail) select 'Q05 رئيس المجلس يسجل جزاء 40 ثم جزاء 500', (r1.ok and r2.ok), r1.res||' | '||r2.res from pg_temp.try_as(C, $q$select public.add_adjustment('penalty','e0000000-0000-0000-0000-000000000001','2026-11-07'::date,40,'تأخير متكرر')::text$q$) r1, pg_temp.try_as(C, $q$select public.add_adjustment('penalty','e0000000-0000-0000-0000-000000000001','2026-11-08'::date,500,'مخالفة كبيرة')::text$q$) r2;
  select id into v_bonus from finance.bonuses where amount=50;
  select id into v_pen from finance.penalties where amount=40;
  select id into v_pen2 from finance.penalties where amount=500;
  insert into t_res(name,pass,detail) select 'Q06 المكافأة المعلّقة تظهر بحالة pending في القائمة', (r.ok and r.res like '%pending%'), left(r.res,80) from pg_temp.try_as(C, $q$select public.list_adjustments('bonus', null, '2026-11-01'::date, '2026-11-30'::date)::text$q$) r;
  insert into t_res(name,pass,detail) select 'Q07 مدير الفتاحة لا يعتمد المكافأة', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select 'x'::text from (select public.decide_adjustment('bonus','00000000-0000-0000-0000-000000000000'::uuid,true,'محاولة')) s$q$) r;
  insert into t_res(name,pass,detail) select 'Q08 رئيس المجلس يعتمد المكافأة والجزاء 40 ويرفض الجزاء 500', (r1.ok and r2.ok and r3.ok), coalesce(r1.res,'')||'|'||coalesce(r2.res,'')||'|'||coalesce(r3.res,'') from pg_temp.try_as(C, $q$select 'x'::text from (select public.decide_adjustment('bonus','$q$ || v_bonus || $q$'::uuid,true,'موافقة')) s$q$) r1, pg_temp.try_as(C, $q$select 'x'::text from (select public.decide_adjustment('penalty','$q$ || v_pen || $q$'::uuid,true,'موافقة')) s$q$) r2, pg_temp.try_as(C, $q$select 'x'::text from (select public.decide_adjustment('penalty','$q$ || v_pen2 || $q$'::uuid,false,'مرفوض')) s$q$) r3;

  insert into t_res(name,pass,detail) select 'W01 حضور وردية صباحية ليوم 11-07', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-07'::date,'present','2026-11-07 08:00:00+02','2026-11-07 16:00:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'W02 حضور وردية ليلية ثانية في اليوم نفسه (مسموح)', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-11-07'::date,'present','2026-11-07 20:00:00+02','2026-11-08 06:00:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'W03 تكرار الوردية الليلية نفسها ممنوع', (r.ok=false and r.res like '%DUPLICATE%'), r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-11-07'::date,'present','2026-11-07 20:00:00+02','2026-11-08 06:00:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'W04 سجلان لنفس العامل في اليوم نفسه', ((select count(*) from public.attendance where employee_id=E1 and work_date='2026-11-07')=2), (select count(*)::text from public.attendance where employee_id=E1 and work_date='2026-11-07');

  insert into t_res(name,pass,detail) select 'W05 حساب الأسبوع ينجح', r.ok, r.res from pg_temp.try_as(C, $q$select public.calculate_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)::text$q$) r;
  insert into t_res(name,pass,detail)
    select 'W06 الكشف: يوم حضور واحد (100) + مكافأة 50 + جزاء 40 = صافي 110، والجزاء 500 مرفوض لذا لا يُخصم',
           (regular_days=1 and gross_regular=100 and bonuses_total=50 and penalties_total=40 and total_due=150 and net_due=110),
           regular_days||' / '||total_due||' / '||bonuses_total||' / '||penalties_total||' / '||net_due
    from finance.payroll_items where employee_id=E1 and week_start='2026-11-07';
  select count(*) into v_applied_b from finance.bonuses where applied_payroll_item_id is not null;
  select count(*) into v_applied_p from finance.penalties where applied_payroll_item_id is not null;
  insert into t_res(name,pass,detail) values ('W07 ترحيل المكافأة مرة واحدة وترحيل الجزاء المُطبَّق فقط', (v_applied_b=1 and v_applied_p=1), v_applied_b||' / '||v_applied_p);

  insert into t_res(name,pass,detail) select 'M01 رئيس المجلس يسجل حضوره (9:00 إلى 17:30)', r.ok, r.res from pg_temp.try_as(C, $q$select public.record_management_attendance('54675bf6-aca8-4633-b717-a60e1019ca6e','2026-11-07'::date,'2026-11-07 09:00:00+02','2026-11-07 17:30:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'M02 ساعات حضور الإدارة محسوبة داخل القاعدة = 8.5', (worked_hours=8.5), worked_hours::text from public.management_attendance where person_id=C and work_date='2026-11-07';
  insert into t_res(name,pass,detail) select 'M03 مدير الفتاحة لا يسجل حضور الإدارة', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.record_management_attendance('9b1e2e9e-bb57-4679-9cb2-1e44927fe198','2026-11-07'::date,null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'M04 مدير الفتاحة لا يقرأ حضور الإدارة', (r.res='0'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.management_attendance$q$) r;
  insert into t_res(name,pass,detail) select 'M05 رئيس المجلس يقرأ حضور الإدارة', (r.res='1'), r.res from pg_temp.try_as(C, $q$select count(*)::text from public.management_attendance$q$) r;

  raise exception E'TEST_REPORT passed=% failed=%\n%',
    (select count(*) from t_res where pass), (select count(*) from t_res where not pass),
    (select string_agg(name || ' => ' || case when pass then 'PASS' else 'FAIL' end || ' | ' || coalesce(detail,''), E'\n' order by id) from t_res);
end $$;
