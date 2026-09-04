-- 花路人格局独立站长看板：在原 huashao2-personality Supabase 项目的 SQL Editor 中执行。
-- 该脚本不会改变公开测试站的匿名 INSERT 权限，也不会新增 IP、城市或身份字段。

create table if not exists public.dashboard_admins (
  email text primary key check (email = lower(email) and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  created_at timestamptz not null default now()
);
comment on table public.dashboard_admins is 'Email allowlist for the separate owner dashboard.';
alter table public.dashboard_admins enable row level security;
revoke all on public.dashboard_admins from anon, authenticated;

create or replace function public.is_dashboard_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.dashboard_admins
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

revoke all on function public.is_dashboard_admin() from public, anon;
grant execute on function public.is_dashboard_admin() to authenticated;

create or replace function public.get_dashboard_data(p_days integer default 7)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 7), 30));
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_today_start timestamptz;
  v_yesterday_start timestamptz;
  v_period_count bigint;
  v_today_count bigint;
  v_yesterday_count bigint;
  v_total_count bigint;
  v_total_feedback bigint;
  v_pending_feedback bigint;
  v_processed_feedback bigint;
  v_period_avg_duration numeric;
  v_today_avg_duration numeric;
  v_yesterday_avg_duration numeric;
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  v_period_start := ((v_today - (v_days - 1))::timestamp at time zone 'Asia/Shanghai');
  v_period_end := ((v_today + 1)::timestamp at time zone 'Asia/Shanghai');
  v_today_start := (v_today::timestamp at time zone 'Asia/Shanghai');
  v_yesterday_start := ((v_today - 1)::timestamp at time zone 'Asia/Shanghai');

  select count(*), avg(duration_seconds)
    into v_period_count, v_period_avg_duration
  from public.test_results
  where created_at >= v_period_start and created_at < v_period_end
    and public_id not like 'HL-VERIFY%' and public_id not like 'HL-LIVE%';

  select count(*), avg(duration_seconds)
    into v_today_count, v_today_avg_duration
  from public.test_results
  where created_at >= v_today_start and created_at < v_period_end
    and public_id not like 'HL-VERIFY%' and public_id not like 'HL-LIVE%';

  select count(*), avg(duration_seconds)
    into v_yesterday_count, v_yesterday_avg_duration
  from public.test_results
  where created_at >= v_yesterday_start and created_at < v_today_start
    and public_id not like 'HL-VERIFY%' and public_id not like 'HL-LIVE%';

  select count(*) into v_total_count
  from public.test_results
  where public_id not like 'HL-VERIFY%' and public_id not like 'HL-LIVE%';

  select count(*),
         count(*) filter (where status = 'new'),
         count(*) filter (where status in ('resolved', 'archived'))
    into v_total_feedback, v_pending_feedback, v_processed_feedback
  from public.feedback
  where coalesce(result_public_id, '') not like 'HL-VERIFY%'
    and coalesce(result_public_id, '') not like 'HL-LIVE%'
    and coalesce(result_public_id, '') not like 'HL-DEMO%'
    and lower(trim(message)) not in ('自动化回归测试', '自动化回归测试。');

  return jsonb_build_object(
    'days', v_days,
    'generated_at', now(),
    'metrics', jsonb_build_object(
      'period_tests', v_period_count,
      'total_tests', v_total_count,
      'period_avg_duration_seconds', case when v_period_avg_duration is null then null else round(v_period_avg_duration) end,
      'today_tests', v_today_count,
      'yesterday_tests', v_yesterday_count,
      'today_tests_dod_percent', case when v_yesterday_count = 0 then null else round(((v_today_count - v_yesterday_count)::numeric / v_yesterday_count) * 100, 1) end,
      'today_avg_duration_seconds', case when v_today_avg_duration is null then null else round(v_today_avg_duration) end,
      'yesterday_avg_duration_seconds', case when v_yesterday_avg_duration is null then null else round(v_yesterday_avg_duration) end,
      'today_duration_dod_percent', case when v_today_avg_duration is null or v_yesterday_avg_duration is null or v_yesterday_avg_duration = 0 then null else round(((v_today_avg_duration - v_yesterday_avg_duration) / v_yesterday_avg_duration) * 100, 1) end,
      'total_feedback', v_total_feedback,
      'pending_feedback', v_pending_feedback,
      'processed_feedback', v_processed_feedback
    ),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object('day', day::text, 'count', count) order by day), '[]'::jsonb)
      from (
        select (series.day at time zone 'Asia/Shanghai')::date as day, count(r.id) as count
        from generate_series(v_period_start, v_period_end - interval '1 day', interval '1 day') as series(day)
        left join public.test_results r
          on r.created_at >= series.day
         and r.created_at < series.day + interval '1 day'
         and r.public_id not like 'HL-VERIFY%' and r.public_id not like 'HL-LIVE%'
        group by series.day
      ) daily_rows
    ),
    'profiles', (
      select coalesce(jsonb_agg(jsonb_build_object('type', primary_type, 'count', count) order by count desc), '[]'::jsonb)
      from (
        select primary_type, count(*) as count
        from public.test_results
        where created_at >= v_period_start and created_at < v_period_end
          and public_id not like 'HL-VERIFY%' and public_id not like 'HL-LIVE%'
        group by primary_type
      ) profile_rows
    ),
    'recent', (
      select coalesce(jsonb_agg(to_jsonb(recent_rows) order by tested_at desc), '[]'::jsonb)
      from (
        select created_at as tested_at, duration_seconds, primary_type as result_type,
               case primary_type
                 when 'jing' then '井柏然' when 'ning' then '宁静' when 'xu' then '许晴'
                 when 'zheng' then '郑爽' when 'mao' then '毛阿敏'
                 when 'chen' then '陈意涵' when 'yang' then '杨洋'
               end as result_name, public_id
        from public.test_results
        where public_id not like 'HL-VERIFY%' and public_id not like 'HL-LIVE%'
        order by created_at desc
        limit 20
      ) recent_rows
    ),
    'feedback', (
      select coalesce(jsonb_agg(to_jsonb(feedback_rows) order by submitted_at desc), '[]'::jsonb)
      from (
        select id, created_at as submitted_at, category, message, result_public_id, result_type, status
        from public.feedback
        where coalesce(result_public_id, '') not like 'HL-VERIFY%'
          and coalesce(result_public_id, '') not like 'HL-LIVE%'
          and coalesce(result_public_id, '') not like 'HL-DEMO%'
          and lower(trim(message)) not in ('自动化回归测试', '自动化回归测试。')
        order by created_at desc
        limit 30
      ) feedback_rows
    )
  );
end;
$$;

revoke all on function public.get_dashboard_data(integer) from public, anon;
grant execute on function public.get_dashboard_data(integer) to authenticated;

drop function if exists public.get_trend_data(text);
drop function if exists public.get_trend_data(text, date);

create function public.get_trend_data(
  p_granularity text default 'day',
  p_date date default ((now() at time zone 'Asia/Shanghai')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_granularity text := lower(coalesce(p_granularity, 'day'));
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_date date := least(coalesce(p_date, (now() at time zone 'Asia/Shanghai')::date), (now() at time zone 'Asia/Shanghai')::date);
  v_items jsonb := '[]'::jsonb;
  v_total bigint := 0;
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if v_granularity not in ('hour', 'day', 'l7d', 'month') then
    raise exception 'invalid granularity' using errcode = '22023';
  end if;

  if v_granularity = 'hour' then
    with buckets as (
      select hour_value,
             ((v_date::timestamp + make_interval(hours => hour_value)) at time zone 'Asia/Shanghai') as bucket_start,
             ((v_date::timestamp + make_interval(hours => hour_value + 1)) at time zone 'Asia/Shanghai') as bucket_end,
             (v_date = v_today and hour_value > extract(hour from now() at time zone 'Asia/Shanghai')::integer) as is_future
      from generate_series(0, 23) as hour_value
    ), counts as (
      select b.hour_value, b.bucket_start, b.is_future, count(r.id) as count
      from buckets b
      left join public.test_results r
        on r.created_at >= b.bucket_start
       and r.created_at < b.bucket_end
       and r.public_id not like 'HL-VERIFY%'
       and r.public_id not like 'HL-LIVE%'
      group by b.hour_value, b.bucket_start, b.is_future
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'bucket_start', bucket_start,
             'label', hour_value::text,
             'count', case when is_future then null else count end,
             'is_future', is_future
           ) order by hour_value), '[]'::jsonb),
           coalesce(sum(count) filter (where not is_future), 0)
      into v_items, v_total
    from counts;

  elsif v_granularity = 'day' then
    with buckets as (
      select generate_series(v_date - 9, v_date, interval '1 day')::date as bucket_start
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
        date_trunc('month', v_date)::date - interval '2 months',
        date_trunc('month', v_date)::date,
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
      where (month_start + (slot * 7))::date <= v_date
        and (month_start + (slot * 7))::date <= (month_start + interval '1 month - 1 day')::date
    ), counts as (
      select b.bucket_start, b.bucket_end, count(r.id) as count
      from buckets b
      left join public.test_results r
        on (r.created_at at time zone 'Asia/Shanghai')::date between b.bucket_start and least(b.bucket_end, v_date)
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
        date_trunc('month', v_date)::date - interval '11 months',
        date_trunc('month', v_date)::date,
        interval '1 month'
      )::date as bucket_start
    ), counts as (
      select b.bucket_start, count(r.id) as count
      from buckets b
      left join public.test_results r
        on (r.created_at at time zone 'Asia/Shanghai')::date >= b.bucket_start
       and (r.created_at at time zone 'Asia/Shanghai')::date < (b.bucket_start + interval '1 month')::date
       and (r.created_at at time zone 'Asia/Shanghai')::date <= v_date
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
    'p_date', v_date::text,
    'today', v_today::text,
    'total', v_total,
    'items', v_items
  );
end;
$$;

revoke all on function public.get_trend_data(text, date) from public, anon;
grant execute on function public.get_trend_data(text, date) to authenticated;

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

create or replace function public.get_feedback_page_filtered(
  p_page integer default 1,
  p_page_size integer default 5,
  p_category text default 'all'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := greatest(5, least(coalesce(p_page_size, 5), 30));
  v_category text := lower(trim(coalesce(p_category, 'all')));
  v_total bigint;
  v_total_pages integer;
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if v_category not in ('all', 'result', 'question', 'bug', 'idea', 'other') then
    raise exception 'invalid feedback category' using errcode = '22023';
  end if;

  select count(*) into v_total
  from public.feedback
  where coalesce(result_public_id, '') not like 'HL-VERIFY%'
    and coalesce(result_public_id, '') not like 'HL-LIVE%'
    and coalesce(result_public_id, '') not like 'HL-DEMO%'
    and lower(trim(message)) not in ('自动化回归测试', '自动化回归测试。')
    and (v_category = 'all' or category = v_category);

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
          and (v_category = 'all' or category = v_category)
        order by created_at desc, id desc
        limit v_page_size
        offset (v_page - 1) * v_page_size
      ) page_rows
    )
  );
end;
$$;

revoke all on function public.get_feedback_page_filtered(integer, integer, text) from public, anon;
grant execute on function public.get_feedback_page_filtered(integer, integer, text) to authenticated;

create or replace function public.update_feedback_status(p_feedback_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
begin
  if not public.is_dashboard_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if p_status not in ('new', 'reviewing', 'resolved', 'archived') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  update public.feedback set status = p_status where id = p_feedback_id;
end;
$$;

revoke all on function public.update_feedback_status(uuid, text) from public, anon;
grant execute on function public.update_feedback_status(uuid, text) to authenticated;

-- 最后一行请在执行前替换为站长邮箱。重复执行不会产生重复记录。
-- insert into public.dashboard_admins(email) values ('your-email@example.com') on conflict do nothing;
