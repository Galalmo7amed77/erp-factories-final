-- 0007: دوال إدارة الورديات. كانت موجودة في المشروع دون ملف migration، فأُضيفت هنا لتعيد الحزمة إنشاء النظام كاملاً.
create or replace function public.create_shift(p_factory uuid, p_name text, p_start time, p_end time, p_hours numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_factory_access(p_factory);
  if length(btrim(coalesce(p_name,''))) = 0 then raise exception 'NAME_REQUIRED'; end if;
  insert into public.shifts (factory_id, name, start_time, end_time, required_hours)
  values (p_factory, btrim(p_name), p_start, p_end, p_hours)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.update_shift(p_id uuid, p_name text, p_start time, p_end time, p_hours numeric, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_factory uuid;
begin
  select s.factory_id into v_factory from public.shifts s where s.id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.require_factory_access(v_factory);
  update public.shifts set name = btrim(p_name), start_time = p_start, end_time = p_end,
    required_hours = p_hours, is_active = p_active
  where id = p_id;
end $$;

revoke all on function public.create_shift(uuid, text, time, time, numeric) from public, anon, authenticated;
revoke all on function public.update_shift(uuid, text, time, time, numeric, boolean) from public, anon, authenticated;
grant execute on function public.create_shift(uuid, text, time, time, numeric) to authenticated;
grant execute on function public.update_shift(uuid, text, time, time, numeric, boolean) to authenticated;
