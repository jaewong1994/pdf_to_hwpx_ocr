-- 2026-09-14 migration_mixed_pricing.sql 적용 직전 지인용 프로젝트(kfsjeshfyaghnfsycvax)의 함수 정의 백업.
-- 되돌리려면 이 파일을 그대로 실행한 뒤 (text,text,integer,text,integer,text) / (text,integer,text,jsonb,integer,text) 시그니처를 drop 한다.

CREATE OR REPLACE FUNCTION public.ocr_reserve(p_job text, p_title text, p_expected integer, p_kind text DEFAULT 'problem'::text)
 RETURNS TABLE(job_id text, reserved_cash integer, price_per_unit integer, available integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_price integer; v_amount integer; v_avail integer; v_kind text;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
  if p_expected <= 0 then raise exception '예상 문항 수가 0입니다'; end if;
  v_kind := case
    when p_kind in ('problem', 'problem_flex', 'problem_generated', 'problem_generated_flex')
      then p_kind
    else 'problem_generated'          -- 모르면 비싼 쪽: 실행 도중 캐시가 모자라 멈추지 않게
  end;
  v_price := public.ocr_price(v_kind);
  if v_price is null then raise exception '단가가 설정되지 않았습니다: %', v_kind; end if;
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
    values (auth.uid(), -v_amount, 'reserve', p_job,
            format('예약 %s문항 (%s)', p_expected,
                   case v_kind
                     when 'problem'                then '해설 첨부·빠르게'
                     when 'problem_flex'           then '해설 첨부·저렴하게'
                     when 'problem_generated'      then '해설 생성·빠르게'
                     else                               '해설 생성·저렴하게'
                   end),
            auth.uid());
  return query select p_job, v_amount, v_price, v_avail - v_amount;
end $function$;

CREATE OR REPLACE FUNCTION public.ocr_settle(p_job text, p_approved integer, p_status text DEFAULT 'complete'::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(job_id text, spent_cash integer, released_cash integer, balance integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;
