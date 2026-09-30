-- 테스트 자료 전부 지우기 (2026-09-30)
--
-- ⚠️ 되돌릴 수 없습니다. ①을 먼저 보고, 정하신 다음 ②를 돌리세요.
--
-- 【남는 것】 회원 · 책방 · 끗짱 신청서 · 알림 설정은 건드리지 않습니다.
-- 【사진】 Storage 의 사진은 그대로 남습니다. DB 줄만 지웁니다.

-- ══ ① 지금 무엇이 있는지 본다 ═════════════════════════
SELECT (SELECT count(*) FROM routines)                 AS 루틴,
       (SELECT count(*) FROM routine_participants)     AS 참여,
       (SELECT count(*) FROM certifications)           AS 인증,
       (SELECT count(*) FROM cert_comments)            AS 댓글,
       (SELECT count(*) FROM reviews)                  AS 후기,
       (SELECT count(*) FROM book_purchases)           AS 구매,
       (SELECT count(*) FROM consumption_allocations)  AS 기금배분,
       (SELECT count(*) FROM charges)                  AS 후원건,
       (SELECT COALESCE(sum(book_fund_amount), 0) FROM charges) AS 후원금액,
       (SELECT count(*) FROM profiles)                 AS 회원_안지움,
       (SELECT count(*) FROM bookstores)               AS 책방_안지움;

-- ⚠️⚠️ 「후원건」을 보세요.
--   실제로 누군가 돈을 보낸 기록이면 **지우면 안 됩니다.**
--   테스트로 넣어본 것이면 아래 ②-B 로 같이 지웁니다.


-- ══ ② 지운다 — 둘 중 하나만 고르세요 ══════════════════

-- ── ②-A 루틴만 지운다 (후원 기록은 남긴다) ─────────────
-- 차감했던 후원금을 되돌려 놓고, 루틴 계열만 지웁니다.
DO $$
DECLARE a record;
BEGIN
  -- 배분을 되돌린다. 안 그러면 기금 잔액이 줄어든 채로 남는다
  FOR a IN SELECT charge_id, sum(amount) AS amt
             FROM consumption_allocations GROUP BY charge_id LOOP
    UPDATE charges
       SET remaining_amount = remaining_amount + a.amt,
           status = 'active', completed_at = NULL
     WHERE id = a.charge_id;
    DELETE FROM completion_events WHERE charge_id = a.charge_id;
  END LOOP;

  DELETE FROM consumption_allocations;   -- RESTRICT 라 구매보다 먼저
  DELETE FROM book_purchases;
  DELETE FROM routines;                  -- 참여·인증·댓글·후기·콕·읽는책·공유글이 딸려 간다
  RAISE NOTICE '루틴 계열을 지웠습니다. 후원 기록은 그대로 두고 기금을 되돌렸습니다.';
END $$;

-- ── ②-B 후원 기록까지 전부 지운다 ──────────────────────
-- 후원도 테스트로 넣어본 것일 때만. 위 ②-A 대신 이것만 돌리세요.
-- (쓰려면 아래 주석을 풀고, 위 ②-A 덩이는 지우고 돌리세요)
--
-- DO $$
-- BEGIN
--   DELETE FROM consumption_allocations;
--   DELETE FROM completion_events;
--   DELETE FROM book_purchases;
--   DELETE FROM routines;
--   DELETE FROM charges;
--   RAISE NOTICE '루틴과 후원 기록을 전부 지웠습니다.';
-- END $$;


-- ══ 확인 ══════════════════════════════════════════════
SELECT (SELECT count(*) FROM routines)                AS 남은루틴,
       (SELECT count(*) FROM certifications)          AS 남은인증,
       (SELECT count(*) FROM book_purchases)          AS 남은구매,
       (SELECT count(*) FROM consumption_allocations) AS 남은배분,
       (SELECT count(*) FROM charges)                 AS 남은후원,
       (SELECT COALESCE(sum(remaining_amount), 0) FROM charges) AS 기금잔액,
       (SELECT count(*) FROM profiles)                AS 회원,
       (SELECT count(*) FROM bookstores)              AS 책방;
