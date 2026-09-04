-- 数据看板“全部测试记录”分页增量脚本。
-- 在 Supabase SQL Editor 中执行一次即可；不会修改或删除已有测试数据。

create or replace function public.get_test_results_page(p_page integer default 1, p_page_size integer default 10)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := greatest(5, least(coalesce(p_page_size, 10), 50));
  v_total bigint;
  v_total_pages integer;
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select count(*)
    into v_total
  from public.test_results
  where public_id not like 'HL-VERIFY%'
    and public_id not like 'HL-LIVE%';

  v_total_pages := case when v_total = 0 then 0 else ceil(v_total::numeric / v_page_size)::integer end;
  if v_total_pages > 0 then
    v_page := least(v_page, v_total_pages);
  else
    v_page := 1;
  end if;

  return jsonb_build_object(
    'page', v_page,
    'page_size', v_page_size,
    'total', v_total,
    'total_pages', v_total_pages,
    'items', (
      select coalesce(jsonb_agg(to_jsonb(page_rows) order by tested_at desc, public_id desc), '[]'::jsonb)
      from (
        select created_at as tested_at, duration_seconds, primary_type as result_type,
               case primary_type
                 when 'jing' then '井柏然' when 'ning' then '宁静' when 'xu' then '许晴'
                 when 'zheng' then '郑爽' when 'mao' then '毛阿敏'
                 when 'chen' then '陈意涵' when 'yang' then '杨洋'
               end as result_name, public_id
        from public.test_results
        where public_id not like 'HL-VERIFY%'
          and public_id not like 'HL-LIVE%'
        order by created_at desc, public_id desc
        limit v_page_size
        offset (v_page - 1) * v_page_size
      ) page_rows
    )
  );
end;
$$;

revoke all on function public.get_test_results_page(integer, integer) from public, anon;
grant execute on function public.get_test_results_page(integer, integer) to authenticated;
