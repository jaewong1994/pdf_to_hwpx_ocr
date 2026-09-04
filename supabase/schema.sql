-- OCR30 스튜디오 — 캐시 지갑 스키마 (새 Supabase 프로젝트에 한 번 실행)
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여 넣고 Run.
-- 관리자 지정만 손으로 한 번 해 주면 됩니다(맨 아래 참고).

-- ── 관리자 ────────────────────────────────────────────────────────────────
create table if not exists public.ocr_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note text,
  created_at timestamptz not null default now()
);

create or replace function public.ocr_is_admin(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.ocr_admins a where a.user_id = p_user);
$$;

-- ── 가격표 ────────────────────────────────────────────────────────────────
create table if not exists public.ocr_pricing (
  key text primary key,
  cash_per_unit integer not null check (cash_per_unit >= 0),
  note text,
  updated_at timestamptz not null default now()
);

insert into public.ocr_pricing(key, cash_per_unit, note)
values ('problem', 100, '승인 문항 1건당 캐시(문제+해설 결박+HWPX 조판 포함). 1캐시=1원 기준')
on conflict (key) do nothing;

create or replace function public.ocr_price(p_key text default 'problem')
returns integer language sql stable security definer set search_path to 'public' as $$
  select cash_per_unit from public.ocr_pricing where key = p_key;
$$;

-- ── 지갑 · 원장 · 작업 ────────────────────────────────────────────────────
create table if not exists public.ocr_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance integer not null default 0,
  reserved integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.ocr_cash_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  delta integer not null,
  kind text not null check (kind in ('grant','charge','reserve','release','spend','refund','adjust')),
  job_id text,
  note text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists ocr_cash_ledger_user_idx on public.ocr_cash_ledger(user_id, created_at desc);

create table if not exists public.ocr_jobs (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text,
  status text not null default 'reserved'
    check (status in ('reserved','running','complete','failed','released')),
  problems_expected integer not null default 0,
  problems_approved integer not null default 0,
  price_per_unit integer not null default 0,
  reserved_cash integer not null default 0,
  spent_cash integer not null default 0,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ocr_jobs_user_idx on public.ocr_jobs(user_id, created_at desc);

-- ── RLS: 자기 것만 읽는다. 쓰기는 아래 함수(SECURITY DEFINER)로만 ────────────
alter table public.ocr_wallets     enable row level security;
alter table public.ocr_cash_ledger enable row level security;
alter table public.ocr_jobs        enable row level security;
alter table public.ocr_pricing     enable row level security;
alter table public.ocr_admins      enable row level security;

drop policy if exists ocr_wallets_read on public.ocr_wallets;
create policy ocr_wallets_read on public.ocr_wallets for select to authenticated
  using (user_id = auth.uid() or public.ocr_is_admin());

drop policy if exists ocr_ledger_read on public.ocr_cash_ledger;
create policy ocr_ledger_read on public.ocr_cash_ledger for select to authenticated
  using (user_id = auth.uid() or public.ocr_is_admin());

drop policy if exists ocr_jobs_read on public.ocr_jobs;
create policy ocr_jobs_read on public.ocr_jobs for select to authenticated
  using (user_id = auth.uid() or public.ocr_is_admin());

drop policy if exists ocr_pricing_read on public.ocr_pricing;
create policy ocr_pricing_read on public.ocr_pricing for select to authenticated using (true);

-- ── 조회 ──────────────────────────────────────────────────────────────────
create or replace function public.ocr_wallet_me()
returns table(user_id uuid, balance integer, reserved integer, available integer,
              price_per_problem integer, is_admin boolean)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
  insert into public.ocr_wallets(user_id) values (auth.uid()) on conflict (user_id) do nothing;
  return query
    select w.user_id, w.balance, w.reserved, w.balance - w.reserved,
           public.ocr_price('problem'), public.ocr_is_admin()
    from public.ocr_wallets w where w.user_id = auth.uid();
end $$;

create or replace function public.ocr_find_user(p_email text)
returns table(user_id uuid, email text, account_type text)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
begin
  if not public.ocr_is_admin() then raise exception '관리자만 조회할 수 있습니다'; end if;
  return query
    select u.id, u.email::text,
           case when public.ocr_is_admin(u.id) then 'ADMIN' else '사용자' end
    from auth.users u where lower(u.email) = lower(p_email) limit 5;
end $$;

-- ── 관리자 지급 ───────────────────────────────────────────────────────────
create or replace function public.ocr_grant_cash(p_user uuid, p_amount integer, p_note text default null)
returns table(user_id uuid, balance integer, reserved integer)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
begin
  if not public.ocr_is_admin() then raise exception '관리자만 캐시를 지급할 수 있습니다'; end if;
  if p_amount = 0 then raise exception '금액이 0입니다'; end if;
  insert into public.ocr_wallets(user_id) values (p_user) on conflict (user_id) do nothing;
  update public.ocr_wallets w set balance = w.balance + p_amount, updated_at = now() where w.user_id = p_user;
  insert into public.ocr_cash_ledger(user_id, delta, kind, note, created_by)
    values (p_user, p_amount, case when p_amount > 0 then 'grant' else 'adjust' end, p_note, auth.uid());
  return query select w.user_id, w.balance, w.reserved from public.ocr_wallets w where w.user_id = p_user;
end $$;

-- ── 예약(사용자) ──────────────────────────────────────────────────────────
create or replace function public.ocr_reserve(p_job text, p_title text, p_expected integer)
returns table(job_id text, reserved_cash integer, price_per_unit integer, available integer)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
declare v_price integer; v_amount integer; v_avail integer;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
  if p_expected <= 0 then raise exception '예상 문항 수가 0입니다'; end if;
  v_price := public.ocr_price('problem');
  v_amount := v_price * p_expected;
  insert into public.ocr_wallets(user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select w.balance - w.reserved into v_avail from public.ocr_wallets w where w.user_id = auth.uid() for update;
  if v_avail < v_amount then
    raise exception '캐시가 부족합니다: 필요 % (문항 % × %), 사용 가능 %', v_amount, p_expected, v_price, v_avail;
  end if;
  if exists (select 1 from public.ocr_jobs j where j.id = p_job and j.status in ('reserved','running')) then
    raise exception '이미 예약된 작업입니다';
  end if;
  update public.ocr_wallets w set reserved = w.reserved + v_amount, updated_at = now() where w.user_id = auth.uid();
  insert into public.ocr_jobs(id, user_id, title, status, problems_expected, price_per_unit, reserved_cash)
    values (p_job, auth.uid(), p_title, 'reserved', p_expected, v_price, v_amount)
    on conflict (id) do update set status = 'reserved', problems_expected = p_expected, price_per_unit = v_price,
      reserved_cash = v_amount, title = p_title, updated_at = now();
  insert into public.ocr_cash_ledger(user_id, delta, kind, job_id, note, created_by)
    values (auth.uid(), -v_amount, 'reserve', p_job, format('예약 %s문항', p_expected), auth.uid());
  return query select p_job, v_amount, v_price, v_avail - v_amount;
end $$;

-- ── 진행·정산·해제(서버 전용: service_role 키로만) ────────────────────────
create or replace function public.ocr_job_running(p_job text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') <> 'service_role' then
    raise exception '서버만 갱신할 수 있습니다';
  end if;
  update public.ocr_jobs set status = 'running', updated_at = now() where id = p_job and status = 'reserved';
end $$;

create or replace function public.ocr_settle(p_job text, p_approved integer,
                                             p_status text default 'complete', p_meta jsonb default '{}'::jsonb)
returns table(job_id text, spent_cash integer, released_cash integer, balance integer)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
declare v_job public.ocr_jobs%rowtype; v_w public.ocr_wallets%rowtype;
        v_due integer; v_spend integer; v_release integer; v_cap integer;
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') <> 'service_role' then
    raise exception '서버만 정산할 수 있습니다';
  end if;
  select * into v_job from public.ocr_jobs where id = p_job for update;
  if not found then raise exception '작업이 없습니다: %', p_job; end if;
  if v_job.status not in ('reserved','running') then raise exception '이미 정산된 작업입니다: %', v_job.status; end if;
  select * into v_w from public.ocr_wallets where user_id = v_job.user_id for update;
  v_due := greatest(0, p_approved) * v_job.price_per_unit;
  v_cap := v_job.reserved_cash + greatest(0, v_w.balance - v_w.reserved);
  v_spend := least(v_due, v_cap);                       -- 남의 예약을 침범하지 않는다
  v_release := greatest(0, v_job.reserved_cash - v_spend);
  update public.ocr_wallets w set balance = w.balance - v_spend,
         reserved = w.reserved - v_job.reserved_cash, updated_at = now()
   where w.user_id = v_job.user_id;
  if v_spend > 0 then
    insert into public.ocr_cash_ledger(user_id, delta, kind, job_id, note)
      values (v_job.user_id, -v_spend, 'spend', p_job,
              format('승인 %s문항 × %s%s', p_approved, v_job.price_per_unit,
                     case when v_spend < v_due then ' (잔액 한도)' else '' end));
  end if;
  if v_release > 0 then
    insert into public.ocr_cash_ledger(user_id, delta, kind, job_id, note)
      values (v_job.user_id, v_release, 'release', p_job, '예약 해제');
  end if;
  update public.ocr_jobs set status = case when p_status = 'complete' then 'complete' else 'failed' end,
         problems_approved = greatest(0, p_approved), spent_cash = v_spend,
         meta = coalesce(meta,'{}'::jsonb) || coalesce(p_meta,'{}'::jsonb), updated_at = now()
   where id = p_job;
  return query select p_job, v_spend, v_release, w.balance
                 from public.ocr_wallets w where w.user_id = v_job.user_id;
end $$;

create or replace function public.ocr_release(p_job text, p_reason text default null)
returns table(job_id text, released_cash integer)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
declare v_job public.ocr_jobs%rowtype;
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') <> 'service_role' then
    raise exception '서버만 해제할 수 있습니다';
  end if;
  select * into v_job from public.ocr_jobs where id = p_job for update;
  if not found or v_job.status not in ('reserved','running') then return; end if;
  update public.ocr_wallets w set reserved = w.reserved - v_job.reserved_cash, updated_at = now()
   where w.user_id = v_job.user_id;
  insert into public.ocr_cash_ledger(user_id, delta, kind, job_id, note)
    values (v_job.user_id, v_job.reserved_cash, 'release', p_job, coalesce(p_reason, '실패 해제'));
  update public.ocr_jobs set status = 'released', updated_at = now() where id = p_job;
  return query select p_job, v_job.reserved_cash;
end $$;

-- ── 관리자 지정 (한 번만, 손으로) ──────────────────────────────────────────
-- Authentication → Users 에서 내 계정 UUID 를 복사해 아래 한 줄을 실행하세요.
--   insert into public.ocr_admins(user_id, note) values ('여기에-내-UUID', '운영자');
