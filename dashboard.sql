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
