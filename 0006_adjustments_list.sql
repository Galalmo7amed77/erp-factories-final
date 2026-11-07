-- 0006: قائمة المكافآت والجزاءات لرئيس المجلس (قراءة فقط)
create or replace function public.list_adjustments(p_kind text, p_factory uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public, finance as $$
begin
  perform public.require_chairman();
  if p_kind = 'bonus' then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'employee_id', b.employee_id, 'factory_id', b.factory_id, 'event_date', b.event_date,
        'reason', b.reason, 'amount', b.amount, 'approval_status', b.approval_status,
        'applied', b.applied_payroll_item_id is not null) order by b.event_date desc)
      from finance.bonuses b
      where (p_factory is null or b.factory_id = p_factory) and b.event_date between p_from and p_to), '[]'::jsonb);
  elsif p_kind = 'penalty' then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'employee_id', b.employee_id, 'factory_id', b.factory_id, 'event_date', b.event_date,
        'reason', b.reason, 'amount', b.amount, 'approval_status', b.approval_status,
        'applied', b.applied_payroll_item_id is not null) order by b.event_date desc)
      from finance.penalties b
      where (p_factory is null or b.factory_id = p_factory) and b.event_date between p_from and p_to), '[]'::jsonb);
  end if;
  raise exception 'INVALID_KIND';
end $$;

revoke all on function public.list_adjustments(text, uuid, date, date) from public, anon, authenticated;
grant execute on function public.list_adjustments(text, uuid, date, date) to authenticated;
