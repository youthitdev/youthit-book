-- 한끗독서 마이그레이션 62
-- 61 을 바로잡는다 — 지금 정산은 배분(FIFO)을 쓰지 않는다
--
-- 【무엇을 틀렸나】 61 을 만들 때 supabase-schema.sql 의 옛 settle_book_purchase
--   를 보고 「정산 = 후원 건에서 FIFO 로 차감」이라고 여겼다. 그런데 그건
--   **마이그레이션 18 에서 이미 폐기**됐다. 지금 정산은 consumption_allocations
--   를 만들지 않고, 잔액도 단순 합계로 본다:
--       남은 도서기금 = sum(charges.book_fund_amount) − sum(정산된 구매 금액)
--
--   그래서 61 의 fix_book_purchase 는 **있지도 않은 배분을 새로 만들어**
--   charges.remaining_amount 를 깎는다. 잔액 계산에는 안 쓰이는 칸이지만
--   숫자가 틀어진 채로 남는다.
--
-- 【바로잡으면 훨씬 단순해진다】 취소는 status 만 'void' 로 바꾸면 된다.
--   잔액은 「정산된 것」만 세므로 저절로 돌아온다. 되돌릴 배분이 없다.

-- 배분을 건드리던 함수는 치운다. 지금 구조에서 부를 일이 없다
DROP FUNCTION IF EXISTS unallocate_purchase(bigint);
DROP FUNCTION IF EXISTS allocate_purchase(bigint, int);

-- ── 정산 고치기 ────────────────────────────────────────
CREATE OR REPLACE FUNCTION fix_book_purchase(
  p_purchase_id bigint,
  p_amount      int    DEFAULT NULL,
  p_bookstore   bigint DEFAULT NULL,
  p_note        text   DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE g record; v_amt int; v_cap int; v_fund int; v_spent int; v_left int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;

  SELECT * INTO g FROM book_purchases WHERE id = p_purchase_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 건이 없습니다 (id=%)', p_purchase_id; END IF;
  IF g.status <> 'settled' THEN RAISE EXCEPTION '정산이 끝난 건만 고칠 수 있습니다'; END IF;
  IF g.paid_at IS NOT NULL THEN
    RAISE EXCEPTION '이미 책방에 입금한 건이라 고칠 수 없습니다. 책방과 먼저 이야기해 주세요';
  END IF;

  v_amt := COALESCE(p_amount, g.amount);
  IF v_amt <= 0 THEN RAISE EXCEPTION '금액이 올바르지 않습니다'; END IF;

  SELECT voucher_max_amount INTO v_cap FROM dokseo_settings WHERE id = 1;
  v_cap := COALESCE(v_cap, 20000);
  IF v_amt > v_cap THEN
    RAISE EXCEPTION '교환권 한도를 넘습니다 (한도 %원 / 입력 %원)', v_cap, v_amt;
  END IF;

  -- 이 건을 뺀 잔액과 견준다. 정산과 같은 셈이다
  SELECT COALESCE(sum(book_fund_amount), 0) INTO v_fund FROM charges;
  SELECT COALESCE(sum(amount), 0) INTO v_spent
    FROM book_purchases WHERE status = 'settled' AND id <> p_purchase_id;
  v_left := v_fund - v_spent;
  IF v_amt > v_left THEN
    RAISE EXCEPTION '도서기금이 부족합니다 (남은 %원 / 입력 %원)', v_left, v_amt;
  END IF;

  UPDATE book_purchases
     SET amount       = v_amt,
         bookstore_id = COALESCE(p_bookstore, bookstore_id),
         note         = COALESCE(NULLIF(btrim(p_note), ''), note)
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('id', p_purchase_id, 'amount', v_amt, 'fund_left', v_left - v_amt);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 정산 취소 ──────────────────────────────────────────
-- 잔액은 「정산된 것」만 세므로, status 만 바꾸면 저절로 돌아온다
CREATE OR REPLACE FUNCTION void_book_purchase(
  p_purchase_id bigint,
  p_reason      text
) RETURNS jsonb AS $$
DECLARE g record;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION '취소 사유를 적어주세요'; END IF;

  SELECT * INTO g FROM book_purchases WHERE id = p_purchase_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 건이 없습니다 (id=%)', p_purchase_id; END IF;
  IF g.status = 'void' THEN RAISE EXCEPTION '이미 취소된 건입니다'; END IF;
  IF g.paid_at IS NOT NULL THEN
    RAISE EXCEPTION '이미 책방에 입금한 건이라 취소할 수 없습니다. 책방과 먼저 이야기해 주세요';
  END IF;

  UPDATE book_purchases
     SET status = 'void',
         note   = COALESCE(NULLIF(btrim(note), '') || E'\n', '') || '[취소] ' || btrim(p_reason)
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('id', p_purchase_id, 'status', 'void');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION fix_book_purchase(bigint, int, bigint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION fix_book_purchase(bigint, int, bigint, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION void_book_purchase(bigint, text)             FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION void_book_purchase(bigint, text)             TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT p.proname AS 남은함수
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('fix_book_purchase','void_book_purchase','unallocate_purchase','allocate_purchase')
 ORDER BY 1;
