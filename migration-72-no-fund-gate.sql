-- 한끗독서 마이그레이션 72
-- 도서기금 잔액으로 정산을 막지 않는다
--
-- 【왜 막고 있었나】 「후원금이 들어온 만큼만 책을 산다」는 전제였다.
--   charges 에 후원을 먼저 넣어야 정산이 됐다.
--
-- 【왜 푸나】 후원자 한 사람 한 사람에게 「당신 돈이 이 책이 됐다」고
--   알리는 건 접기로 했다(월간 리포트로 총계만 알린다). 그 순간 후원 입력은
--   정산의 선행 조건이 아니라 운영 기록이 된다. 기록이 없다고 책방에
--   보낼 돈을 못 보내는 건 앞뒤가 바뀐 것이다.
--
--   실제로도 기금은 책에만 쓰이지 않는다(창작지원·북페어). 앱이 아는
--   숫자로 문을 잠그면, 앱이 모르는 지출이 생길 때마다 문이 잘못 닫힌다.
--
-- 【남기는 것】 교환권 한도(voucher_max_amount)는 그대로 지킨다. 그건
--   한 아이가 한 번에 가져갈 수 있는 금액이라 성격이 다르다.
--   charges 표와 「남은 도서기금」 숫자도 그대로 둔다 — 기부금품법상
--   사용명세를 남기는 자리다. 보여주되 막지 않는다.
--
-- ⚠️ settle_book_purchase 는 06 → 12 → 18 로 덮어써졌다. 지금 살아 있는
--   것은 18번 판이고, 이 파일은 거기서 잔액 검사만 뺀 것이다.

CREATE OR REPLACE FUNCTION settle_book_purchase(
  p_purchase_id bigint,
  p_amount      int,
  p_receipt_url text DEFAULT NULL,
  p_note        text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE v_cap int; v_fund int; v_spent int; v_left int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION '정산 금액이 올바르지 않습니다'; END IF;

  PERFORM 1 FROM book_purchases
   WHERE id = p_purchase_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 대기 상태의 건이 아닙니다 (id=%)', p_purchase_id;
  END IF;

  SELECT voucher_max_amount INTO v_cap FROM dokseo_settings WHERE id = 1;
  v_cap := COALESCE(v_cap, 20000);
  IF p_amount > v_cap THEN
    RAISE EXCEPTION '교환권 한도를 넘습니다 (한도 %원 / 입력 %원)', v_cap, p_amount;
  END IF;

  -- 잔액은 계산해서 돌려주기만 한다. 모자라도 막지 않는다 —
  -- 책방에 보낼 돈을 장부 때문에 못 보내는 일은 없어야 한다
  SELECT COALESCE(sum(book_fund_amount), 0) INTO v_fund FROM charges;
  SELECT COALESCE(sum(amount), 0) INTO v_spent FROM book_purchases WHERE status = 'settled';
  v_left := v_fund - v_spent;

  UPDATE book_purchases
     SET status = 'settled', amount = p_amount,
         receipt_url = COALESCE(p_receipt_url, receipt_url),
         note = COALESCE(p_note, note),
         settled_by = auth.uid(), settled_at = now()
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('purchase_id', p_purchase_id, 'amount', p_amount,
                            'fund_left', v_left - p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) TO authenticated;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT CASE WHEN pg_get_functiondef(oid) LIKE '%도서기금이 부족합니다%'
            THEN '아직 막고 있음' ELSE '안 막음' END AS 잔액검사,
       CASE WHEN pg_get_functiondef(oid) LIKE '%교환권 한도를 넘습니다%'
            THEN '지킴' ELSE '풀림' END                AS 교환권한도
  FROM pg_proc WHERE proname = 'settle_book_purchase';
