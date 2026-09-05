-- 数据看板“总计 / 按日人格分布”增量脚本。
-- 在 Supabase SQL Editor 中执行一次即可；只读取聚合数据，不会修改或删除测试记录。

create or replace function public.get_profile_distribution_total()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return (
    with valid_results as (
      select primary_type
      from public.test_results
      where public_id not like 'HL-VERIFY%'
        and public_id not like 'HL-LIVE%'
    ), profile_rows as (
      select primary_type as profile_type, count(*) as profile_count
      from valid_results
      group by primary_type
    )
    select jsonb_build_object(
      'total', (select count(*) from valid_results),
      'items', coalesce(
        (select jsonb_agg(
          jsonb_build_object('type', profile_type, 'count', profile_count)
          order by profile_type
        ) from profile_rows),
        '[]'::jsonb
      )
    )
  );
end;
$$;

revoke all on function public.get_profile_distribution_total() from public, anon;
grant execute on function public.get_profile_distribution_total() to authenticated;

create or replace function public.get_profile_distribution_by_date(
  p_date date default ((now() at time zone 'Asia/Shanghai')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_date date := least(coalesce(p_date, v_today), v_today);
  v_start timestamptz := (v_date::timestamp at time zone 'Asia/Shanghai');
  v_end timestamptz := ((v_date + 1)::timestamp at time zone 'Asia/Shanghai');
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'date', v_date,
    'total', (
      select count(*)
      from public.test_results
      where created_at >= v_start and created_at < v_end
        and public_id not like 'HL-VERIFY%'
        and public_id not like 'HL-LIVE%'
    ),
    'items', (
      select coalesce(
        jsonb_agg(jsonb_build_object('type', profile_type, 'count', profile_count) order by profile_type),
        '[]'::jsonb
      )
      from (
        select primary_type as profile_type, count(*) as profile_count
        from public.test_results
        where created_at >= v_start and created_at < v_end
          and public_id not like 'HL-VERIFY%'
          and public_id not like 'HL-LIVE%'
        group by primary_type
      ) profile_rows
    )
  );
end;
$$;

revoke all on function public.get_profile_distribution_by_date(date) from public, anon;
grant execute on function public.get_profile_distribution_by_date(date) to authenticated;
