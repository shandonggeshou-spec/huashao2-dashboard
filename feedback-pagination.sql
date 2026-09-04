-- 数据看板“用户意见”分页增量脚本。
-- 在 Supabase SQL Editor 中执行一次即可，不会修改或删除已有意见。

create or replace function public.get_feedback_page(p_page integer default 1, p_page_size integer default 5)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := greatest(5, least(coalesce(p_page_size, 5), 30));
  v_total bigint;
  v_total_pages integer;
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select count(*) into v_total
  from public.feedback
  where coalesce(result_public_id, '') not like 'HL-VERIFY%'
    and coalesce(result_public_id, '') not like 'HL-LIVE%'
    and coalesce(result_public_id, '') not like 'HL-DEMO%'
    and lower(trim(message)) not in ('自动化回归测试', '自动化回归测试。');

  v_total_pages := case when v_total = 0 then 0 else ceil(v_total::numeric / v_page_size)::integer end;
  if v_total_pages > 0 then v_page := least(v_page, v_total_pages); else v_page := 1; end if;

  return jsonb_build_object(
    'page', v_page,
    'page_size', v_page_size,
    'total', v_total,
    'total_pages', v_total_pages,
    'items', (
      select coalesce(jsonb_agg(to_jsonb(page_rows) order by submitted_at desc, id desc), '[]'::jsonb)
      from (
        select id, created_at as submitted_at, category, message, result_public_id, result_type, status
        from public.feedback
        where coalesce(result_public_id, '') not like 'HL-VERIFY%'
          and coalesce(result_public_id, '') not like 'HL-LIVE%'
          and coalesce(result_public_id, '') not like 'HL-DEMO%'
          and lower(trim(message)) not in ('自动化回归测试', '自动化回归测试。')
        order by created_at desc, id desc
        limit v_page_size
        offset (v_page - 1) * v_page_size
      ) page_rows
    )
  );
end;
$$;

revoke all on function public.get_feedback_page(integer, integer) from public, anon;
grant execute on function public.get_feedback_page(integer, integer) to authenticated;
