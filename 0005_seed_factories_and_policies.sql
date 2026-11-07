-- 0005: المصانع الثلاثة، وإعدادات السياسات المالية (معطلة افتراضياً حتى يعتمدها رئيس المجلس)
insert into public.factories (code, name_ar) values
  ('FATTAHA','مصنع الفتّاحة'),
  ('TEXTILE','مصنع النسيج'),
  ('SPINNING','مصنع الغزل')
on conflict (code) do nothing;

insert into public.system_settings (key, value) values
  ('overtime_policy', '{"enabled": false, "rate_multiplier": 1}'),
  ('late_deduction_policy', '{"enabled": false, "per_minute": 0}'),
  ('leave_policy', '{"paid_factor": 0}'),
  ('mission_policy', '{"paid_factor": 0}')
on conflict (key) do nothing;
