-- 한끗독서 마이그레이션 18
-- FIFO 차감 폐기 — 기금은 책에만 쓰이지 않는다
--
-- 【배경】 후원금은 책뿐 아니라 창작지원금·북페어 운영비로도 나간다.
--   그런데 지금 구조는 "후원금 = 책이 될 돈"을 전제로, 책을 살 때마다
--   후원 건에서 깎아나간다(FIFO). 전제가 깨졌다.
--
--   게다가 개인 후원금 추적은 이미 포기했다(「함께한 뒤로」). FIFO 가 하던
--   유일한 일은 잔액 체크뿐이고, 그건 단순 합계로 된다.
--
--   창작지원금·북페어는 앱 밖에서 일어나는 일이라 앱이 모른다. 그러니
--   앱이 아는 범위(들어온 도서기금 − 책에 쓴 돈)로만 잔액을 계산하고,
--   정확한 사용 내역은 연말 보고로 따로 낸다.
--
--   consumption_allocations / completion_events 는 지우지 않는다. 지금까지
--   쌓인 기록이고, 되돌릴 일이 생길 수도 있다. 새로 쓰지 않을 뿐이다.

-- ── 정산: 잔액을 확인하고 금액만 확정한다
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

  -- 앱이 아는 범위의 잔액. 실제로는 창작지원금 등으로 더 나갔을 수 있다
  SELECT COALESCE(sum(book_fund_amount), 0) INTO v_fund FROM charges;
  SELECT COALESCE(sum(amount), 0) INTO v_spent FROM book_purchases WHERE status = 'settled';
  v_left := v_fund - v_spent;
  IF v_left < p_amount THEN
    RAISE EXCEPTION '도서기금이 부족합니다 (남은 %원 / 필요 %원)', v_left, p_amount;
  END IF;

  UPDATE book_purchases
     SET status = 'settled', amount = p_amount,
         receipt_url = COALESCE(p_receipt_url, receipt_url),
         note = COALESCE(p_note, note),
         settled_by = auth.uid(), settled_at = now()
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('purchase_id', p_purchase_id, 'amount', p_amount, 'fund_left', v_left - p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) TO authenticated;

-- ── 집계도 FIFO 를 보지 않는다
CREATE OR REPLACE FUNCTION dokseo_pool_status() RETURNS jsonb AS $$
  WITH f AS (SELECT COALESCE(sum(amount), 0) AS total,
                    COALESCE(sum(book_fund_amount), 0) AS fund,
                    COALESCE(sum(operation_fee_amount), 0) AS op,
                    COALESCE(count(DISTINCT sponsor_id), 0) AS sponsors
               FROM charges),
       s AS (SELECT COALESCE(sum(amount), 0) AS spent,
                    COALESCE(count(*) FILTER (WHERE status = 'settled'), 0) AS bought,
                    COALESCE(count(*) FILTER (WHERE status = 'pending'), 0) AS pending,
                    COALESCE(count(DISTINCT user_id) FILTER (WHERE status <> 'void'), 0) AS students
               FROM book_purchases WHERE status <> 'void')
  SELECT jsonb_build_object(
    'total_donated',    f.total,
    'book_fund',        f.fund,
    'operation_fee',    f.op,
    'spent',            s.spent,
    'remaining',        GREATEST(0, f.fund - s.spent),
    'books_bought',     s.bought,
    'books_pending',    s.pending,
    'students_reached', s.students,
    'sponsors_count',   f.sponsors,
    'bookstores_count', (SELECT count(*) FROM bookstores WHERE active)
  ) FROM f, s;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_pool_status() TO anon, authenticated;

COMMENT ON COLUMN charges.remaining_amount IS
  '[미사용] FIFO 차감 시절의 잔액. migration-18 이후로 갱신하지 않는다';
