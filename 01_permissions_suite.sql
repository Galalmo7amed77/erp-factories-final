-- اختبارات الصلاحيات والعزل والحساب والاعتماد والنقل والحماية
-- المعرّفات الثابتة تخص الحسابات الحالية. التقرير يظهر كرسالة TEST_REPORT وتُلغى كل البيانات.
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

create or replace function pg_temp.reset_flags()
returns void language plpgsql as $f$
begin
  perform set_config('app.finance_op', '', true);
  perform set_config('app.advance_op', '', true);
  perform set_config('app.advance_restore', '', true);
  perform set_config('app.allow_locked_edit', '', true);
  perform set_config('app.profile_admin', '', true);
  perform set_config('app.transfer_op', '', true);
  perform set_config('app.change_reason', '', true);
end $f$;

create temp table t_res (id serial primary key, name text, pass boolean, detail text);

do $$
declare
  C uuid := '54675bf6-aca8-4633-b717-a60e1019ca6e';
  F uuid := '9b1e2e9e-bb57-4679-9cb2-1e44927fe198';
  T uuid := 'e3c6cb75-138e-488f-9b0c-a524d0c8d670';
  S uuid := 'f9ae1a1f-6294-4ad3-b69d-3d2c17067105';
  FAT uuid := 'a6402de3-defe-4f71-a5dc-c9a61104ecff';
  TEX uuid := 'babed44d-e4bc-48ad-aa1b-68a054e619ae';
  FAT_M uuid := 'a0000000-0000-0000-0000-000000000001';
  FAT_N uuid := 'a0000000-0000-0000-0000-000000000002';
  TEX_M uuid := 'a0000000-0000-0000-0000-000000000003';
  E1 uuid := 'e0000000-0000-0000-0000-000000000001';
  E2 uuid := 'e0000000-0000-0000-0000-000000000002';
  v_item text; v_pay1 text; v_att text;
begin
  -- ===== الإعداد =====
  perform pg_temp.reset_flags();
  insert into public.shifts (id, factory_id, name, start_time, end_time, required_hours) values
    (FAT_M, FAT, 'صباحية', '08:00', '16:00', 8), (FAT_N, FAT, 'ليلية', '22:00', '06:00', 8), (TEX_M, TEX, 'صباحية', '08:00', '16:00', 8);
  insert into public.employees (id, factory_id, full_name, start_date, shift_id) values
    (E1, FAT, 'موظف اختبار الفتاحة', '2026-10-01', FAT_M), (E2, TEX, 'موظف اختبار النسيج', '2026-10-01', TEX_M);
  insert into public.employee_factory_assignments (employee_id, factory_id, valid_from, transfer_reason)
    values (E1, FAT, '2026-10-01', 'تعيين'), (E2, TEX, '2026-10-01', 'تعيين');
  perform set_config('app.finance_op', 'on', true);
  insert into finance.employee_wage_history (employee_id, daily_wage, effective_from, reason, set_by)
    values (E1, 100, '2026-10-01', 'اختبار', C), (E2, 200, '2026-10-01', 'اختبار', C);
  perform pg_temp.reset_flags();

  -- ===== R: العزل والقراءة =====
  insert into t_res(name,pass,detail) select 'R01 رئيس المجلس يرى المصانع الثلاثة', (r.res='3'), r.res from pg_temp.try_as(C, $q$select count(*)::text from public.factories$q$) r;
  insert into t_res(name,pass,detail) select 'R02 مدير الفتاحة يرى مصنعه فقط', (r.res='1'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.factories$q$) r;
  insert into t_res(name,pass,detail) select 'R03 مدير الفتاحة يرى عامله (تحقق إيجابي)', (r.res='1'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.employees where id='e0000000-0000-0000-0000-000000000001'$q$) r;
  insert into t_res(name,pass,detail) select 'R04 مدير الفتاحة لا يرى عامل النسيج', (r.res='0'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.employees where id='e0000000-0000-0000-0000-000000000002'$q$) r;
  insert into t_res(name,pass,detail) select 'R05 مدير النسيج لا يرى ورديات الفتاحة', (r.res='0'), r.res from pg_temp.try_as(T, $q$select count(*)::text from public.shifts where factory_id='a6402de3-defe-4f71-a5dc-c9a61104ecff'$q$) r;
  insert into t_res(name,pass,detail) select 'R06 مدير الفتاحة لا يرى حسابات غيره', (r.res='1'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.profiles where role='factory_manager'$q$) r;
  insert into t_res(name,pass,detail) select 'R07 مدير الغزل لا يرى سجل العمليات', (r.res='0'), r.res from pg_temp.try_as(S, $q$select count(*)::text from public.audit_logs$q$) r;
  insert into t_res(name,pass,detail) select 'R08 رئيس المجلس يرى سجل العمليات', (r.ok and r.res::int > 0), r.res from pg_temp.try_as(C, $q$select count(*)::text from public.audit_logs$q$) r;
  insert into t_res(name,pass,detail) select 'R09 مدير الفتاحة لا يرى حضور الإدارة', (r.res='0'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.management_attendance$q$) r;

  -- ===== F: الجداول المالية مغلقة =====
  insert into t_res(name,pass,detail) select 'F01 مدير الفتاحة لا يقرأ اليوميات مباشرة', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$select count(*)::text from finance.employee_wage_history$q$) r;
  insert into t_res(name,pass,detail) select 'F02 مدير الفتاحة لا يقرأ الرواتب مباشرة', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$select count(*)::text from finance.payroll_items$q$) r;
  insert into t_res(name,pass,detail) select 'F03 مدير النسيج لا يقرأ الدفعات مباشرة', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(T, $q$select count(*)::text from finance.payroll_payments$q$) r;
  insert into t_res(name,pass,detail) select 'F04 مدير الغزل لا يقرأ الجزاءات مباشرة', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(S, $q$select count(*)::text from finance.penalties$q$) r;
  insert into t_res(name,pass,detail) select 'F05 رئيس المجلس لا يقرأ الجدول المالي مباشرة (عبر الدوال فقط)', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(C, $q$select count(*)::text from finance.payroll_items$q$) r;
  insert into t_res(name,pass,detail) select 'F06 مدير الفتاحة لا يستدعي دالة الكشوف', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.get_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)$q$) r;
  insert into t_res(name,pass,detail) select 'F07 مدير الفتاحة لا يستدعي دالة اليوميات', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.get_wage_history('e0000000-0000-0000-0000-000000000001')$q$) r;
  insert into t_res(name,pass,detail) select 'F08 مدير الفتاحة لا يستدعي الملخص المالي', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.get_finance_summary('2026-01-01','2026-12-31')::text$q$) r;
  insert into t_res(name,pass,detail) select 'F09 مدير الفتاحة لا يصدّر النسخة الاحتياطية', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.export_backup()::text$q$) r;
  insert into t_res(name,pass,detail) select 'F10 مدير الفتاحة لا يحدد يومية (حتى لعامله)', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.set_daily_wage('e0000000-0000-0000-0000-000000000001',999,'2026-11-01'::date,'تزوير')::text$q$) r;
  insert into t_res(name,pass,detail) select 'F11 رئيس المجلس يقرأ الملخص المالي عبر الدالة', (r.ok and r.res like '{%'), left(r.res,60) from pg_temp.try_as(C, $q$select public.get_finance_summary('2026-01-01','2026-12-31')::text$q$) r;

  -- ===== X: تجاوز الواجهة والتزوير =====
  insert into t_res(name,pass,detail) select 'X01 مدير الفتاحة لا يُدرج حضوراً مباشرة', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$with i as (insert into public.attendance (factory_id,employee_id,shift_id,work_date,status,recorded_by) values ('a6402de3-defe-4f71-a5dc-c9a61104ecff','e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-12','absent',auth.uid()) returning 1) select count(*)::text from i$q$) r;
  insert into t_res(name,pass,detail) select 'X02 مدير الفتاحة لا يعدّل ساعات الحضور مباشرة', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$with u as (update public.attendance set worked_hours=99 returning 1) select count(*)::text from u$q$) r;
  insert into t_res(name,pass,detail) select 'X03 مدير الفتاحة لا ينقل عاملاً بتعديل مباشر', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$with u as (update public.employees set factory_id='babed44d-e4bc-48ad-aa1b-68a054e619ae' returning 1) select count(*)::text from u$q$) r;
  insert into t_res(name,pass,detail) select 'X04 مدير الفتاحة لا يعدّل رصيد السلفة مباشرة', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$with u as (update public.advances set balance_remaining=0 returning 1) select count(*)::text from u$q$) r;
  insert into t_res(name,pass,detail) select 'X05 مدير الفتاحة لا يغيّر حسابه', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$with u as (update public.profiles set factory_id='babed44d-e4bc-48ad-aa1b-68a054e619ae' where id=auth.uid() returning 1) select count(*)::text from u$q$) r;
  insert into t_res(name,pass,detail) select 'X06 مدير الفتاحة لا يحذف سجل حضور', (r.ok=false and r.res like '%permission denied%'), r.res from pg_temp.try_as(F, $q$with u as (delete from public.attendance returning 1) select count(*)::text from u$q$) r;
  insert into t_res(name,pass,detail) select 'X07 مدير الفتاحة لا يسجل حضور عامل النسيج عبر الدالة', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003','2026-11-09'::date,'absent',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'X08 مدير الفتاحة لا يسجل عامله بوردية مصنع آخر (قيد FK مركب)', (r.ok=false and r.res like '%attendance_shift_same_factory_fk%'), r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003','2026-11-09'::date,'absent',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'X09 مدير النسيج لا يسلّف عامل الفتاحة', (r.ok=false and (r.res like '%FORBIDDEN%' or r.res like '%NOT_FOUND%')), r.res from pg_temp.try_as(T, $q$select public.create_advance('e0000000-0000-0000-0000-000000000001',50,'2026-11-07'::date,'x','full',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'X10 مدير النسيج لا ينقل عاملاً', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(T, $q$select public.transfer_employee('e0000000-0000-0000-0000-000000000001','babed44d-e4bc-48ad-aa1b-68a054e619ae','2026-11-14'::date,'محاولة')::text$q$) r;
  insert into t_res(name,pass,detail) select 'X11 مدير الفتاحة لا ينقل عاملاً', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.transfer_employee('e0000000-0000-0000-0000-000000000001','babed44d-e4bc-48ad-aa1b-68a054e619ae','2026-11-14'::date,'محاولة')::text$q$) r;

  perform pg_temp.reset_flags();
  perform set_config('request.jwt.claims', json_build_object('sub', C::text, 'role', 'authenticated')::text, true);
  insert into public.attendance (factory_id,employee_id,shift_id,work_date,status,recorded_by) values (FAT,E1,FAT_M,'2026-11-05','absent',F);
  insert into t_res(name,pass,detail) select 'X12 recorded_by المُرسَل مزوَّر يُستبدل بهوية الجلسة', (recorded_by = C), recorded_by::text from public.attendance where work_date='2026-11-05' and employee_id=E1;
  begin
    insert into public.attendance (factory_id,employee_id,shift_id,work_date,status) values (FAT,E2,FAT_M,'2026-11-05','absent');
    insert into t_res(name,pass,detail) values ('X13 حضور بمصنع لا يطابق ارتباط العامل مرفوض', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('X13 حضور بمصنع لا يطابق ارتباط العامل مرفوض', sqlerrm like 'FACTORY_MISMATCH%', sqlerrm);
  end;
  begin
    insert into public.attendance (factory_id,employee_id,shift_id,work_date,status) values (FAT,E1,TEX_M,'2026-11-05','absent');
    insert into t_res(name,pass,detail) values ('X14 وردية مصنع آخر في حضور مرفوضة على مستوى القاعدة', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('X14 وردية مصنع آخر في حضور مرفوضة على مستوى القاعدة', sqlerrm like '%attendance_shift_same_factory_fk%', sqlerrm);
  end;
  begin
    update public.employees set shift_id=TEX_M where id=E1;
    insert into t_res(name,pass,detail) values ('X15 ربط عامل بوردية مصنع آخر مرفوض', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('X15 ربط عامل بوردية مصنع آخر مرفوض', sqlerrm like '%employees_shift_same_factory_fk%', sqlerrm);
  end;
  perform pg_temp.reset_flags();

  -- ===== A: الحضور والحساب داخل القاعدة =====
  insert into t_res(name,pass,detail) select 'A01 تسجيل حضور صباحي للفتاحة', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-07'::date,'present','2026-11-07 08:20:00+02','2026-11-07 16:30:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A02 منع تكرار حضور نفس العامل والوردية واليوم', (r.ok=false and r.res like '%DUPLICATE_ATTENDANCE%'), r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-07'::date,'present','2026-11-07 08:00:00+02','2026-11-07 16:00:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A03 وردية ليلية 22:10 إلى 06:05 التالي', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-11-08'::date,'present','2026-11-08 22:10:00+02','2026-11-09 06:05:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A04 غياب 11-09', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-09'::date,'absent',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A05 إجازة 11-10', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-10'::date,'leave',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A06 مأمورية 11-11', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-11'::date,'mission',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A07 حضور الجمعة 11-13', r.ok, r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-13'::date,'present','2026-11-13 08:00:00+02','2026-11-13 16:00:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A08 الإدخال الجماعي بصف صحيح (غياب 11-12)', (r.ok and r.res='1'), r.res from pg_temp.try_as(F, $q$select public.record_attendance_bulk('[{"employee_id":"e0000000-0000-0000-0000-000000000001","shift_id":"a0000000-0000-0000-0000-000000000001","work_date":"2026-11-12","status":"absent"}]'::jsonb)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A09 مدير النسيج لا يسجل حضور عامل الفتاحة', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(T, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003','2026-11-09'::date,'absent',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A10 حالة حضور غير معرّفة مرفوضة', (r.ok=false), r.res from pg_temp.try_as(F, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','2026-11-14'::date,'xyz',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'A11 القيم المحسوبة داخل القاعدة: تأخير 20 وساعات 8.17 وإضافي 0.17 ومُسجِّل = مدير الفتاحة', (late_minutes=20 and worked_hours=8.17 and overtime_hours=0.17 and early_leave_minutes=0 and recorded_by=F), late_minutes||' / '||worked_hours||' / '||overtime_hours from public.attendance where employee_id=E1 and work_date='2026-11-07';
  insert into t_res(name,pass,detail) select 'A12 الوردية الليلية: تأخير 10 وساعات 7.92 وبلا إضافي', (late_minutes=10 and worked_hours=7.92 and overtime_hours=0), late_minutes||' / '||worked_hours from public.attendance where employee_id=E1 and work_date='2026-11-08';
  v_att := (select id::text from public.attendance where employee_id=E1 and work_date='2026-11-07');

  -- ===== P: السلف والحساب والاعتماد والصرف =====
  insert into t_res(name,pass,detail) select 'P01 مدير الفتاحة يسلّف عامله (3 أقساط من 100)', r.ok, r.res from pg_temp.try_as(F, $q$select public.create_advance('e0000000-0000-0000-0000-000000000001',300,'2026-11-07'::date,'سلفة اختبار','installments',100)::text$q$) r;
  insert into t_res(name,pass,detail) select 'P02 قسط أكبر من مبلغ السلفة مرفوض', (r.ok=false and r.res like '%INVALID_WEEKLY%'), r.res from pg_temp.try_as(F, $q$select public.create_advance('e0000000-0000-0000-0000-000000000001',300,'2026-11-07'::date,'x','installments',400)::text$q$) r;
  insert into t_res(name,pass,detail) select 'P03 مدير الفتاحة لا يحسب الأسبوع', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.calculate_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)::text$q$) r;
  insert into t_res(name,pass,detail) select 'P04 رئيس المجلس يحسب أسبوع الفتاحة', r.ok, r.res from pg_temp.try_as(C, $q$select public.calculate_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)::text$q$) r;
  insert into t_res(name,pass,detail) select 'P05 الكشف: إجمالي 350 وخصم سلفة 100 وصافي 250', (total_due=350 and advance_deduction=100 and net_due=250 and gross_regular=200 and gross_friday=150 and remaining_due=250), total_due||' / '||advance_deduction||' / '||net_due from finance.payroll_items where employee_id=E1 and week_start='2026-11-07';
  insert into t_res(name,pass,detail) select 'P06 الأيام: 2 عادي و1 جمعة و2 غياب و1 إجازة و1 مأمورية، والإضافي غير مطبّق بلا سياسة', (regular_days=2 and friday_days=1 and absent_days=2 and leave_days=1 and mission_days=1 and overtime_total=0), regular_days||'/'||friday_days||'/'||absent_days||'/'||leave_days||'/'||mission_days from finance.payroll_items where employee_id=E1 and week_start='2026-11-07';
  insert into t_res(name,pass,detail) select 'P07 خصم السلفة مسجَّل مرة واحدة ورصيدها 200 والحالة مفتوحة', ((select count(*) from finance.advance_repayments)=1 and balance_remaining=200 and status='open'), balance_remaining||' / '||status from public.advances where employee_id=E1;
  insert into t_res(name,pass,detail) select 'P08 إعادة حساب الأسبوع مرفوضة (لا خصم مزدوج)', (r.ok=false and r.res like '%PERIOD_NOT_OPEN%'), r.res from pg_temp.try_as(C, $q$select public.calculate_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)::text$q$) r;
  insert into t_res(name,pass,detail) select 'P09 مدير الفتاحة لا يعتمد الكشف', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select 'x'::text from (select public.approve_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)) s$q$) r;
  insert into t_res(name,pass,detail) select 'P10 رئيس المجلس يعتمد الكشف', r.ok, r.res from pg_temp.try_as(C, $q$select 'x'::text from (select public.approve_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)) s$q$) r;

  v_item := (select id::text from finance.payroll_items where employee_id=E1 and week_start='2026-11-07');
  insert into t_res(name,pass,detail) select 'P11 مدير الفتاحة لا يصرف راتباً', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.record_payroll_payment('a0000000-0000-0000-0000-0000000000ff',100,'cash',null,null,'PAY-F-000001')::text$q$) r;
  insert into t_res(name,pass,detail) select 'P12 صرف دفعة أولى 100', r.ok, r.res from pg_temp.try_as(C, $q$select public.record_payroll_payment('$q$ || v_item || $q$'::uuid,100,'cash',null,null,'PAY-TEST-0001')::text$q$) r;
  v_pay1 := (select id::text from finance.payroll_payments where idempotency_key='PAY-TEST-0001');
  insert into t_res(name,pass,detail) select 'P13 تكرار نفس مفتاح الدفعة يعيد الدفعة الأصلية', (r.ok and r.res = v_pay1 and (select count(*) from finance.payroll_payments)=1), r.res from pg_temp.try_as(C, $q$select public.record_payroll_payment('$q$ || v_item || $q$'::uuid,100,'cash',null,null,'PAY-TEST-0001')::text$q$) r;
  insert into t_res(name,pass,detail) select 'P14 دفع أكثر من المتبقي مرفوض', (r.ok=false and r.res like '%OVERPAY%'), r.res from pg_temp.try_as(C, $q$select public.record_payroll_payment('$q$ || v_item || $q$'::uuid,1000,'cash',null,null,'PAY-TEST-0002')::text$q$) r;
  insert into t_res(name,pass,detail) select 'P15 مفتاح دفعة قصير مرفوض', (r.ok=false and r.res like '%IDEMPOTENCY%'), r.res from pg_temp.try_as(C, $q$select public.record_payroll_payment('$q$ || v_item || $q$'::uuid,10,'cash',null,null,'x')::text$q$) r;
  insert into t_res(name,pass,detail) select 'P16 صرف الباقي 150 بتحويل', r.ok, r.res from pg_temp.try_as(C, $q$select public.record_payroll_payment('$q$ || v_item || $q$'::uuid,150,'bank_transfer',null,null,'PAY-TEST-0003')::text$q$) r;
  insert into t_res(name,pass,detail) select 'P17 الكشف مصروف بالكامل: مدفوع 250 والمتبقي 0 والحالة paid', (paid_total=250 and remaining_due=0 and payment_status='paid'), paid_total||' / '||remaining_due||' / '||payment_status from finance.payroll_items where id=v_item::uuid;

  -- ===== L: قفل الأسبوع =====
  insert into t_res(name,pass,detail) select 'L01 رئيس المجلس يغلق الأسبوع المعتمد', r.ok, r.res from pg_temp.try_as(C, $q$select 'x'::text from (select public.close_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)) s$q$) r;
  insert into t_res(name,pass,detail) select 'L02 مدير الفتاحة لا يعدّل حضور أسبوع مغلق', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.update_attendance('$q$ || v_att || $q$'::uuid,'absent',null,null,'x','تعديل')::text$q$) r;
  insert into t_res(name,pass,detail) select 'L03 تصحيح حضور مغلق بلا سبب موثق مرفوض', (r.ok=false and r.res like '%REASON_REQUIRED%'), r.res from pg_temp.try_as(C, $q$select public.update_attendance('$q$ || v_att || $q$'::uuid,'present','2026-11-07 08:00:00+02','2026-11-07 16:00:00+02','x','')::text$q$) r;
  insert into t_res(name,pass,detail) select 'L04 إعادة فتح أسبوع فيه دفعات مرفوضة', (r.ok=false and r.res like '%PAYMENTS_EXIST%'), r.res from pg_temp.try_as(C, $q$select public.reopen_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'L05 مدير الفتاحة لا يعيد فتح أسبوع', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.reopen_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'L06 اليومية لا تتغير داخل أسبوع معتمد', (r.ok=false and r.res like '%WAGE_LOCKED%'), r.res from pg_temp.try_as(C, $q$select public.set_daily_wage('e0000000-0000-0000-0000-000000000001',150,'2026-11-07'::date,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'L07 تغيير اليومية من تاريخ لاحق مسموح', r.ok, r.res from pg_temp.try_as(C, $q$select public.set_daily_wage('e0000000-0000-0000-0000-000000000001',150,'2026-11-20'::date,'زيادة')::text$q$) r;
  insert into t_res(name,pass,detail) select 'L08 اليومية تُطبَّق من تاريخ السريان (100 قبل 11-20 و150 من 11-20)', (finance.wage_on('e0000000-0000-0000-0000-000000000001','2026-11-19')=100 and finance.wage_on('e0000000-0000-0000-0000-000000000001','2026-11-20')=150), 'ok';

  perform pg_temp.reset_flags();
  perform set_config('request.jwt.claims', json_build_object('sub', C::text, 'role', 'authenticated')::text, true);
  begin
    update public.attendance set notes='تزوير' where id=v_att::uuid;
    insert into t_res(name,pass,detail) values ('L09 تعديل حضور أسبوع مغلق مباشرة مرفوض حتى لرئيس المجلس', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('L09 تعديل حضور أسبوع مغلق مباشرة مرفوض حتى لرئيس المجلس', sqlerrm like 'WEEK_LOCKED%', sqlerrm);
  end;
  perform pg_temp.reset_flags();
  begin
    update finance.payroll_items set net_due=0 where employee_id=E1;
    insert into t_res(name,pass,detail) values ('L10 تعديل الصافي مباشرة مرفوض', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('L10 تعديل الصافي مباشرة مرفوض', sqlerrm like 'FINANCE_LOCKED%', sqlerrm);
  end;
  perform pg_temp.reset_flags();
  begin
    update public.advances set balance_remaining=9999 where employee_id=E1;
    insert into t_res(name,pass,detail) values ('L11 زيادة رصيد السلفة مباشرة مرفوضة', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('L11 زيادة رصيد السلفة مباشرة مرفوضة', sqlerrm like 'ADVANCE_LOCKED%', sqlerrm);
  end;
  perform pg_temp.reset_flags();
  begin
    update public.advances set balance_remaining=0 where employee_id=E1;
    insert into t_res(name,pass,detail) values ('L12 تخفيض رصيد السلفة مباشرة مرفوض', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('L12 تخفيض رصيد السلفة مباشرة مرفوض', sqlerrm like 'ADVANCE_LOCKED%', sqlerrm);
  end;
  perform pg_temp.reset_flags();

  -- ===== T: النقل =====
  insert into t_res(name,pass,detail) select 'T01 النقل بتاريخ غير سبت مرفوض', (r.ok=false and r.res like '%TRANSFER_DATE%'), r.res from pg_temp.try_as(C, $q$select public.transfer_employee('e0000000-0000-0000-0000-000000000001','babed44d-e4bc-48ad-aa1b-68a054e619ae','2026-11-15'::date,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'T02 رئيس المجلس ينقل العامل من الفتاحة إلى النسيج من سبت 14-11', r.ok, r.res from pg_temp.try_as(C, $q$select public.transfer_employee('e0000000-0000-0000-0000-000000000001','babed44d-e4bc-48ad-aa1b-68a054e619ae','2026-11-14'::date,'نقل لتغطية النسيج')::text$q$) r;
  insert into t_res(name,pass,detail) select 'T03 سجل النقل: فترتان دون تداخل', (public.employee_factory_on('e0000000-0000-0000-0000-000000000001','2026-11-07')=FAT and public.employee_factory_on('e0000000-0000-0000-0000-000000000001','2026-11-14')=TEX and (select count(*) from public.employee_factory_assignments where employee_id='e0000000-0000-0000-0000-000000000001')=2), 'ok';
  insert into t_res(name,pass,detail) select 'T04 بعد النقل: مدير الفتاحة لا يرى العامل', (r.res='0'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.employees where id='e0000000-0000-0000-0000-000000000001'$q$) r;
  insert into t_res(name,pass,detail) select 'T05 بعد النقل: مدير النسيج يرى العامل', (r.res='1'), r.res from pg_temp.try_as(T, $q$select count(*)::text from public.employees where id='e0000000-0000-0000-0000-000000000001'$q$) r;
  insert into t_res(name,pass,detail) select 'T06 حضور ما قبل النقل يبقى لمصنعه القديم (الفتاحة ترى)', (r.res='1'), r.res from pg_temp.try_as(F, $q$select count(*)::text from public.attendance where employee_id='e0000000-0000-0000-0000-000000000001' and work_date='2026-11-07'$q$) r;
  insert into t_res(name,pass,detail) select 'T07 مدير النسيج لا يرى حضور ما قبل النقل', (r.res='0'), r.res from pg_temp.try_as(T, $q$select count(*)::text from public.attendance where employee_id='e0000000-0000-0000-0000-000000000001' and work_date='2026-11-07'$q$) r;
  insert into t_res(name,pass,detail) select 'T08 مدير النسيج يسجل حضور العامل بعد تاريخ النقل', r.ok, r.res from pg_temp.try_as(T, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003','2026-11-16'::date,'present','2026-11-16 08:00:00+02','2026-11-16 16:00:00+02',null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'T09 مدير النسيج لا يسجل للعامل قبل تاريخ نقله', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(T, $q$select public.record_attendance('e0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003','2026-11-10'::date,'absent',null,null,null)::text$q$) r;
  insert into t_res(name,pass,detail) select 'T10 نقل لنفس المصنع مرفوض', (r.ok=false and r.res like '%SAME_FACTORY%'), r.res from pg_temp.try_as(C, $q$select public.transfer_employee('e0000000-0000-0000-0000-000000000001','babed44d-e4bc-48ad-aa1b-68a054e619ae','2026-11-21'::date,'اختبار')::text$q$) r;

  -- ===== H: حماية الحسابات =====
  insert into t_res(name,pass,detail) select 'H01 رئيس المجلس لا يوقف حسابه', (r.ok=false and r.res like '%SELF_CHANGE%'), r.res from pg_temp.try_as(C, $q$select public.set_manager_status('54675bf6-aca8-4633-b717-a60e1019ca6e',false,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'H02 مدير الفتاحة لا يوقف مديراً آخر', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(F, $q$select public.set_manager_status('e3c6cb75-138e-488f-9b0c-a524d0c8d670',false,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'H03 رئيس المجلس يوقف مدير النسيج', r.ok, r.res from pg_temp.try_as(C, $q$select public.set_manager_status('e3c6cb75-138e-488f-9b0c-a524d0c8d670',false,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'H04 المدير الموقوف لا يصل لأي عامل', (r.res='0'), r.res from pg_temp.try_as(T, $q$select count(*)::text from public.employees where id='e0000000-0000-0000-0000-000000000001'$q$) r;
  insert into t_res(name,pass,detail) select 'H05 رئيس المجلس يعيد تفعيل مدير النسيج', r.ok, r.res from pg_temp.try_as(C, $q$select public.set_manager_status('e3c6cb75-138e-488f-9b0c-a524d0c8d670',true,'اختبار')::text$q$) r;
  insert into t_res(name,pass,detail) select 'H06 المدير المعاد تفعيله يرى عامله', (r.res='1'), r.res from pg_temp.try_as(T, $q$select count(*)::text from public.employees where id='e0000000-0000-0000-0000-000000000001'$q$) r;
  insert into t_res(name,pass,detail) select 'H07 مدير يغيّر مصنعه بنفسه مرفوض', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(T, $q$select public.change_manager_factory(auth.uid(),'a6402de3-defe-4f71-a5dc-c9a61104ecff','تزوير')::text$q$) r;
  begin
    update public.profiles set is_active=false where username='chairman';
    insert into t_res(name,pass,detail) values ('H08 تعطيل حساب رئيس المجلس مباشرة مرفوض', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('H08 تعطيل حساب رئيس المجلس مباشرة مرفوض', sqlerrm like 'CHAIRMAN_PROTECTED%', sqlerrm);
  end;
  begin
    delete from public.profiles where username='chairman';
    insert into t_res(name,pass,detail) values ('H09 حذف حساب رئيس المجلس مرفوض', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('H09 حذف حساب رئيس المجلس مرفوض', sqlerrm like 'NO_DELETE%', sqlerrm);
  end;
  begin
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('d1000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'chair2@erp.local', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now(), '', '', '', '');
    insert into public.profiles (id, username, full_name, role) values ('d1000000-0000-0000-0000-000000000009', 'chairman2', 'حساب ثانٍ', 'chairman');
    insert into t_res(name,pass,detail) values ('H10 إنشاء حساب رئيس مجلس ثانٍ مرفوض', false, 'لا خطأ');
  exception when others then
    insert into t_res(name,pass,detail) values ('H10 إنشاء حساب رئيس مجلس ثانٍ مرفوض', sqlerrm like '%profiles_single_chairman%', sqlerrm);
  end;

  -- ===== B: النسخ الاحتياطي والتقارير =====
  insert into t_res(name,pass,detail) select 'B01 النسخة الاحتياطية تشمل الكشوف والدفعات', (r.res='true'), r.res from pg_temp.try_as(C, $q$select (public.export_backup() ? 'payroll_items' and public.export_backup() ? 'payroll_payments')::text$q$) r;
  insert into t_res(name,pass,detail) select 'B02 رئيس المجلس يقرأ كشف الأسبوع عبر الدالة', (r.res='1'), r.res from pg_temp.try_as(C, $q$select count(*)::text from public.get_payroll_week('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)$q$) r;
  insert into t_res(name,pass,detail) select 'B03 مدير النسيج يعرف حالة أسبوع مصنعه', r.ok, r.res from pg_temp.try_as(T, $q$select public.get_week_status('babed44d-e4bc-48ad-aa1b-68a054e619ae','2026-11-14'::date)$q$) r;
  insert into t_res(name,pass,detail) select 'B04 مدير النسيج لا يعرف حالة أسبوع الفتاحة', (r.ok=false and r.res like '%FORBIDDEN%'), r.res from pg_temp.try_as(T, $q$select public.get_week_status('a6402de3-defe-4f71-a5dc-c9a61104ecff','2026-11-07'::date)$q$) r;

  raise exception E'TEST_REPORT passed=% failed=%\n%',
    (select count(*) from t_res where pass), (select count(*) from t_res where not pass),
    (select string_agg(name || ' => ' || case when pass then 'PASS' else 'FAIL' end || ' | ' || coalesce(detail,''), E'\n' order by id) from t_res);
end $$;
