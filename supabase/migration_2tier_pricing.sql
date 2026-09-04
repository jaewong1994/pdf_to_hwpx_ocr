-- OCR30 단가 2종 (2026-09-04 사용자 결정)
--
-- 해설 PDF 를 주면 해설을 '읽어' 오고, 안 주면 AI 가 '지어'낸다. 실측 원가가 문항당 36원 대 98원으로
-- 세 배 가까이 차이 나므로 단가를 나눈다.
--
--   problem            해설 PDF 첨부  100캐시   (원가 36원, 마진 64%)
--   problem_generated  해설 지어내기  200캐시   (원가 98원, 마진 51%)
--
-- 이미 schema.sql 을 실행한 프로젝트에 덧붙여 실행한다. 여러 번 실행해도 안전하다.

insert into public.ocr_pricing(key, cash_per_unit, note)
values ('problem_generated', 200,
        'AI 해설 생성 포함 1문항당 캐시. 해설 PDF 를 주지 않은 의뢰. 1캐시=1원 기준')
on conflict (key) do update set cash_per_unit = excluded.cash_per_unit,
                                note = excluded.note, updated_at = now();

update public.ocr_pricing
   set note = '승인 문항 1건당 캐시(해설 PDF 첨부 의뢰). 1캐시=1원 기준', updated_at = now()
 where key = 'problem';

-- 지갑 조회에 두 단가를 함께 실어 화면이 미리 견적을 낼 수 있게 한다
create or replace function public.ocr_wallet_me()
returns table(balance integer, reserved integer, available integer,
              price_per_problem integer, price_generated integer, is_admin boolean)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
  return query
    select w.balance, w.reserved, w.balance - w.reserved,
           public.ocr_price('problem'), public.ocr_price('problem_generated'),
           public.ocr_is_admin()
    from public.ocr_wallets w where w.user_id = auth.uid();
end $$;

-- 예약할 때 어느 단가를 쓸지 받는다. 값을 안 주면 예전처럼 'problem'.
create or replace function public.ocr_reserve(p_job text, p_title text, p_expected integer,
                                              p_kind text default 'problem')
returns table(job_id text, reserved_cash integer, price_per_unit integer, available integer)
language plpgsql security definer set search_path to 'public' as $$
#variable_conflict use_column
declare v_price integer; v_amount integer; v_avail integer; v_kind text;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다'; end if;
  if p_expected <= 0 then raise exception '예상 문항 수가 0입니다'; end if;
  v_kind := case when p_kind = 'problem_generated' then 'problem_generated' else 'problem' end;
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
                   case when v_kind = 'problem_generated' then '해설 생성' else '해설 첨부' end),
            auth.uid());
  return query select p_job, v_amount, v_price, v_avail - v_amount;
end $$;
