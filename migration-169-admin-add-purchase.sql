-- 한끗독서 마이그레이션 169
-- 운영진이 교환(책값 정산) 기록을 직접 등록한다 (2026-11-13 QA: 「QR 오류로 교환권 사용 없이 책값을 정산한 서점」)
--
-- 【배경】 관리자 「정산 대기」·「서점 입금」은 교환 기록(book_purchases) 한 줄씩을 보여 주는 화면이다.
--   기록은 QR 제출 · 청소년이 앱에서 「QR 없이」 기록 · 책방 청구로만 생긴다.
--   QR 이 안 돼서 앱 밖에서 정산한 건은 기록이 없어 관리자 화면에 남지 않고,
--   청소년의 교환권도 그대로 남아 같은 교환권을 한 번 더 쓸 수 있다.
--
-- 【하는 일】 admin_add_purchase — 운영진만 부른다. 이미 정산된 건(settled)으로 한 줄을 넣는다.
--   · 청소년의 교환권이 1장 줄어든다 (교환권 = 나다움으로 번 장수 − 정산 대기·완료 기록 수).
--   · 입금일을 넣으면 「입금 완료」까지 끝난 건으로, 비우면 입금 전으로 남는다.
--   · 메모는 「[운영진 직접 등록] …」로 시작한다. 목록에서 직접 등록 건을 알아볼 수 있다.
--   · 모임은 그 청소년이 가장 최근에 참여한 모임으로 자동 연결한다 (기록 칸이 모임을 요구한다).
--   · 같은 청소년·서점·금액·날짜로 이미 직접 등록한 건이 있으면 막는다 (두 번 눌러도 한 번만).
--   · 알림은 가지 않는다.
-- 되돌리려면: 관리자 「서점 입금」에서 그 줄의 「−」(정산 취소). 입금까지 끝난 건은 먼저 「되돌리기」를 눌러야 한다.
--
-- ⚠️ 이미 「나다움 차감」으로 교환권을 줄여 둔 청소년은 이중으로 줄지 않게, 등록 전에 관리자 「나다움 지급」에서 그 차감을 「차감 취소」한다.
-- ⚠️ 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION admin_add_purchase(
  p_user    uuid,
  p_store   bigint,
  p_amount  int,
  p_day     date,
  p_book    text DEFAULT NULL,
  p_paid_on date DEFAULT NULL,
  p_note    text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_cap int; v_routine bigint; v_id bigint; v_at timestamptz; v_paid timestamptz;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  IF p_user IS NULL OR NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_user) THEN
    RAISE EXCEPTION '청소년을 찾지 못했어요';
  END IF;
  IF p_store IS NULL OR NOT EXISTS (SELECT 1 FROM bookstores WHERE id = p_store) THEN
    RAISE EXCEPTION '책방을 찾지 못했어요';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION '금액을 적어주세요'; END IF;
  v_cap := COALESCE((SELECT voucher_max_amount FROM dokseo_settings WHERE id = 1), 20000);
  IF p_amount > v_cap THEN
    RAISE EXCEPTION '교환권 한도를 넘어요 (최대 %원)', to_char(v_cap, 'FM999,999');
  END IF;
  IF p_day IS NULL THEN RAISE EXCEPTION '책 받은 날을 골라주세요'; END IF;

  -- 기록 칸이 모임을 요구한다. 가장 최근에 참여한 모임, 없으면 가장 최근에 인증한 모임
  SELECT rp.routine_id INTO v_routine FROM routine_participants rp
   WHERE rp.user_id = p_user ORDER BY rp.joined_at DESC NULLS LAST LIMIT 1;
  IF v_routine IS NULL THEN
    SELECT c.routine_id INTO v_routine FROM certifications c
     WHERE c.user_id = p_user ORDER BY c.cert_date DESC LIMIT 1;
  END IF;
  IF v_routine IS NULL THEN
    RAISE EXCEPTION '이 청소년이 참여한 모임이 없어서 등록할 수 없어요';
  END IF;

  v_at   := (p_day + time '12:00') AT TIME ZONE 'Asia/Seoul';
  v_paid := CASE WHEN p_paid_on IS NULL THEN NULL
                 ELSE (p_paid_on + time '12:00') AT TIME ZONE 'Asia/Seoul' END;

  IF EXISTS (SELECT 1 FROM book_purchases b
              WHERE b.user_id = p_user AND b.bookstore_id = p_store AND b.amount = p_amount
                AND b.created_at = v_at AND b.status <> 'void'
                AND b.note LIKE '[운영진 직접 등록]%') THEN
    RAISE EXCEPTION '같은 건이 이미 등록되어 있어요';
  END IF;

  INSERT INTO book_purchases (user_id, routine_id, bookstore_id, code_ok, status, amount,
                              store_book_title, note, settled_by, settled_at, created_at,
                              paid_at, paid_by)
  VALUES (p_user, v_routine, p_store, false, 'settled', p_amount,
          NULLIF(btrim(COALESCE(p_book, '')), ''),
          '[운영진 직접 등록]' || COALESCE(' ' || NULLIF(btrim(COALESCE(p_note, '')), ''), ''),
          auth.uid(), now(), v_at,
          v_paid, CASE WHEN v_paid IS NULL THEN NULL ELSE auth.uid() END)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_add_purchase(uuid, bigint, int, date, text, date, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_add_purchase(uuid, bigint, int, date, text, date, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 함수 1 / 보안정의자 true / 로그인 없는 사람에게는 닫혀 있음 true
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'admin_add_purchase')                       AS 함수_1이어야,
       (SELECT bool_and(prosecdef) FROM pg_proc WHERE proname = 'admin_add_purchase')            AS 보안정의자_true여야,
       NOT has_function_privilege('anon', 'admin_add_purchase(uuid, bigint, int, date, text, date, text)', 'EXECUTE')
                                                                                                  AS 익명_차단_true여야;
