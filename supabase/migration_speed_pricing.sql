-- OCR30 단가 4종: 해설(첨부/생성) × 속도(빠르게/저렴하게) (2026-09-04 사용자 결정 "고르게 만들자 요금을 차등을 두고")
--
-- 실측 근거(올백 p113-118, 36문항 A/B)
--   빠르게(표준 티어)  문항당 13초 · 원가 71원(해설 생성)
--   저렴하게(flex 티어) 문항당 43초 · 원가 37원(해설 생성) — 정확도는 동일했다
--   해설 PDF 를 주면 판독만 하므로 위 원가의 절반쯤이다.
--
--   key                       뜻                        캐시   원가   마진
--   problem                   해설 첨부 · 빠르게         100    37원   63%
--   problem_flex              해설 첨부 · 저렴하게        60    19원   68%
--   problem_generated         해설 생성 · 빠르게         200    71원   65%
--   problem_generated_flex    해설 생성 · 저렴하게       120    37원   69%
--
-- schema.sql · migration_2tier_pricing.sql 다음에 실행한다. 여러 번 실행해도 안전하다.

insert into public.ocr_pricing(key, cash_per_unit, note) values
  ('problem',                100, '해설 PDF 첨부 · 빠르게(표준 티어). 문항당 캐시'),
  ('problem_flex',            60, '해설 PDF 첨부 · 저렴하게(할인 티어, 시간 약 3배). 문항당 캐시'),
  ('problem_generated',      200, 'AI 해설 생성 · 빠르게(표준 티어). 문항당 캐시'),
  ('problem_generated_flex', 120, 'AI 해설 생성 · 저렴하게(할인 티어, 시간 약 3배). 문항당 캐시')
on conflict (key) do update set cash_per_unit = excluded.cash_per_unit,
                                note = excluded.note, updated_at = now();

-- 화면이 네 단가를 한 번에 받아 견적을 낸다
create or replace function public.ocr_wallet_me()
returns table(balance integer, reserved integer, available integer,
              price_per_problem integer, price_generated integer,
              price_flex integer, price_generated_flex integer, is_admin boolean)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
  return query
    select w.balance, w.reserved, w.balance - w.reserved,
           public.ocr_price('problem'), public.ocr_price('problem_generated'),
           public.ocr_price('problem_flex'), public.ocr_price('problem_generated_flex'),
           public.ocr_is_admin()
    from public.ocr_wallets w where w.user_id = auth.uid();
end $$;

-- 예약: 네 단가 중 하나를 받는다. 모르는 값이면 가장 비싼 쪽으로 올려 잡는다.
create or replace function public.ocr_reserve(p_job text, p_title text, p_expected integer,
                                              p_kind text default 'problem')
returns table(job_id text, reserved_cash integer, price_per_unit integer, available integer)
language plpgsql security definer set search_path to 'public' as $$
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
end $$;
