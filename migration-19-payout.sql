-- 한끗독서 마이그레이션 19
-- 서점 입금 상태
--
-- 【돈 흐름】 서점 외상 → 유스보이스가 서점에 지급.
--   아이에게 현금을 먼저 내게 하지 않는다. 그 순간 돈 없는 아이가 걸러지는데,
--   그 아이가 이 프로그램이 도우려는 바로 그 아이다.
--
-- 【상태】 pending(정산 대기) → settled(금액 확정) → paid(서점에 입금)
--   status 값을 늘리지 않고 paid_at 으로 표시한다. 코드 곳곳에
--   status='settled' 로 책 권수·지출을 세는 곳이 많아, 값을 늘리면 그중
--   하나만 놓쳐도 조용히 숫자가 틀어진다. paid_at 이면 기존 판정을
--   건드리지 않는다.
--     정산 확정 = settled
--     입금 대기 = settled AND paid_at IS NULL
--     입금 완료 = settled AND paid_at IS NOT NULL

ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS paid_at timestamptz;
ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS paid_by uuid REFERENCES auth.users ON DELETE SET NULL;

COMMENT ON COLUMN book_purchases.paid_at IS
  '서점에 실제로 입금한 시각. NULL 이면 입금 대기. 금액 확정(settled_at)과 다르다';

CREATE INDEX IF NOT EXISTS book_purchases_unpaid_idx
  ON book_purchases (bookstore_id) WHERE status = 'settled' AND paid_at IS NULL;

-- 입금 표시 / 되돌리기 (관리자만)
CREATE OR REPLACE FUNCTION mark_purchase_paid(p_purchase_id bigint, p_paid boolean DEFAULT true)
RETURNS jsonb AS $$
DECLARE v_status text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT status INTO v_status FROM book_purchases WHERE id = p_purchase_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 건입니다 (id=%)', p_purchase_id; END IF;
  IF v_status <> 'settled' THEN
    RAISE EXCEPTION '금액이 확정된 건만 입금 표시할 수 있습니다';
  END IF;

  UPDATE book_purchases
     SET paid_at = CASE WHEN p_paid THEN now() ELSE NULL END,
         paid_by = CASE WHEN p_paid THEN auth.uid() ELSE NULL END
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('purchase_id', p_purchase_id, 'paid', p_paid);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION mark_purchase_paid(bigint, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION mark_purchase_paid(bigint, boolean) TO authenticated;
