-- 数据看板趋势聚合增量脚本。
-- 在 Supabase SQL Editor 中完整执行；不会修改或删除现有测试数据。

create or replace function public.get_trend_data(p_granularity text default 'day')
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_granularity text := lower(coalesce(p_granularity, 'day'));
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_items jsonb := '[]'::jsonb;
  v_total bigint := 0;
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if v_granularity not in ('day', 'l7d', 'month') then
    raise exception 'invalid granularity' using errcode = '22023';
  end if;

  if v_granularity = 'day' then
    with buckets as (
      select generate_series(v_today - 9, v_today, interval '1 day')::date as bucket_start
    ), counts as (
      select b.bucket_start, count(r.id) as count
      from buckets b
      left join public.test_results r
        on (r.created_at at time zone 'Asia/Shanghai')::date = b.bucket_start
       and r.public_id not like 'HL-VERIFY%'
       and r.public_id not like 'HL-LIVE%'
      group by b.bucket_start
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'bucket_start', bucket_start::text,
             'day', bucket_start::text,
             'label', to_char(bucket_start, 'FMMM/FMDD'),
             'count', count
           ) order by bucket_start), '[]'::jsonb),
           coalesce(sum(count), 0)
      into v_items, v_total
    from counts;

  elsif v_granularity = 'l7d' then
    with months as (
      select generate_series(
        date_trunc('month', v_today)::date - interval '2 months',
        date_trunc('month', v_today)::date,
        interval '1 month'
      )::date as month_start
    ), buckets as (
      select (month_start + (slot * 7))::date as bucket_start,
             least(
               (month_start + (slot * 7) + 6)::date,
               (month_start + interval '1 month - 1 day')::date
             ) as bucket_end
      from months
      cross join generate_series(0, 4) as slot
      where (month_start + (slot * 7))::date <= v_today
        and (month_start + (slot * 7))::date <= (month_start + interval '1 month - 1 day')::date
    ), counts as (
      select b.bucket_start, b.bucket_end, count(r.id) as count
      from buckets b
      left join public.test_results r
        on (r.created_at at time zone 'Asia/Shanghai')::date between b.bucket_start and least(b.bucket_end, v_today)
       and r.public_id not like 'HL-VERIFY%'
       and r.public_id not like 'HL-LIVE%'
      group by b.bucket_start, b.bucket_end
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'bucket_start', bucket_start::text,
             'bucket_end', bucket_end::text,
             'label', to_char(bucket_start, 'MMDD') || '-' || to_char(bucket_end, 'MMDD'),
             'count', count
           ) order by bucket_start), '[]'::jsonb),
           coalesce(sum(count), 0)
      into v_items, v_total
    from counts;

  else
    with buckets as (
      select generate_series(
        date_trunc('month', v_today)::date - interval '11 months',
        date_trunc('month', v_today)::date,
        interval '1 month'
      )::date as bucket_start
    ), counts as (
      select b.bucket_start, count(r.id) as count
      from buckets b
      left join public.test_results r
        on (r.created_at at time zone 'Asia/Shanghai')::date >= b.bucket_start
       and (r.created_at at time zone 'Asia/Shanghai')::date < (b.bucket_start + interval '1 month')::date
       and (r.created_at at time zone 'Asia/Shanghai')::date <= v_today
       and r.public_id not like 'HL-VERIFY%'
       and r.public_id not like 'HL-LIVE%'
      group by b.bucket_start
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'bucket_start', bucket_start::text,
             'label', to_char(bucket_start, 'YYMM'),
             'count', count
           ) order by bucket_start), '[]'::jsonb),
           coalesce(sum(count), 0)
      into v_items, v_total
    from counts;
  end if;

  return jsonb_build_object(
    'granularity', v_granularity,
    'total', v_total,
    'items', v_items
  );
end;
$$;

revoke all on function public.get_trend_data(text) from public, anon;
grant execute on function public.get_trend_data(text) to authenticated;
