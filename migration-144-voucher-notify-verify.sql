-- 한끗독서 마이그레이션 144
-- 청소년 확인 전인 사람에게 가는 「교환권이 생겼어요」 알림을, 확인부터 하라는 말로 바꾼다 (2026-10-21 사용자)
--
-- 【문제】 교환권은 나다움 합계로만 생기는데, 책을 받으려면 청소년 확인이 끝나 있어야 한다(서버가 막는다).
--   그런데 알림은 확인 전 사람에게도 똑같이 「교환권이 생겼어요 — 책 한 권을 바꿔 보세요」로 갔다. 눌러서 서점에 가도 책을 못 받으니
--   안내와 어긋났다.
--
-- 【고침】 127 의 notify_new_vouchers() 에서 알림 문구만 갈린다.
--   · 확인이 끝난 사람: 지금처럼 「교환권이 생겼어요 🎫 — 동네책방에서 책 한 권을 골라 바꿔 보세요」(서점 탭으로)
--   · 확인 전인 사람:   「교환권이 생겼어요 🎫 — 책을 받으려면 청소년 확인을 먼저 끝내 주세요」(MY 로 — 거기에 「청소년 확인부터 하기」 단추가 있다)
--   알리는 때(교환권이 처음 늘어났을 때 한 번)와 끌 수 없는 종류라는 점은 그대로다.
--
-- ⚠️ 127 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION notify_new_vouchers() RETURNS int AS $$
DECLARE r record; n int := 0; v_old int;
BEGIN
  FOR r IN
    SELECT a.user_id, a.earned, COALESCE(p.verify_status, 'none') AS vs
      FROM dokseo_points_all() a
      JOIN profiles p ON p.id = a.user_id
     WHERE p.withdrawn_at IS NULL AND a.earned > 0
  LOOP
    SELECT earned INTO v_old FROM voucher_notified WHERE user_id = r.user_id;
    IF v_old IS NULL THEN v_old := 0; END IF;
    IF r.earned > v_old THEN
      IF r.vs = 'approved' THEN
        PERFORM notify_push(r.user_id, '교환권이 생겼어요 🎫',
          '동네책방에서 책 한 권을 골라 바꿔 보세요', '/youthit-book/app.html?tab=store');
      ELSE
        PERFORM notify_push(r.user_id, '교환권이 생겼어요 🎫',
          '책을 받으려면 청소년 확인을 먼저 끝내 주세요', '/youthit-book/app.html?tab=my');
      END IF;
      INSERT INTO voucher_notified(user_id, earned) VALUES (r.user_id, r.earned)
        ON CONFLICT (user_id) DO UPDATE SET earned = EXCLUDED.earned, at = now();
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION notify_new_vouchers() FROM PUBLIC, anon, authenticated;

-- ── 확인 ───────────────────────────────────────────────
-- 아무에게도 알리지 않는다. 기대: 새 판 1 / 지금 확인 전인데 교환권이 있는 사람 수 (알림은 새로 늘어날 때만 간다)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'notify_new_vouchers' AND prosrc LIKE '%청소년 확인을 먼저%') AS 새판_1이어야,
       (SELECT count(*) FROM dokseo_points_all() a JOIN profiles p ON p.id = a.user_id
         WHERE p.withdrawn_at IS NULL AND a.remain > 0 AND COALESCE(p.verify_status, 'none') <> 'approved')   AS 확인전_교환권_있는_사람;
