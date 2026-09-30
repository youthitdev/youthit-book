-- 테스트 자료 전부 지우기 (2026-09-30, 사용자 확인 — 후원까지 전부 테스트)
--
-- ⚠️ 되돌릴 수 없습니다.
--
-- 【지우는 것】 루틴 · 참여 · 인증 · 댓글 · 후기 · 콕 · 읽는 책 · 공유 글 ·
--              책 구매 · 기금 배분 · 완료 카드 · 후원 내역
-- 【남는 것】   회원 · 책방 · 끗짱 신청서 · 알림 설정
-- 【사진】      Storage 는 그대로. DB 줄만 지웁니다
--
-- ⚠️ 순서가 중요합니다. consumption_allocations 가 book_purchases 를
--    ON DELETE RESTRICT 로 물고 있어, 배분을 먼저 치우지 않으면 멈춥니다.

-- ── 지우기 전 모습 ─────────────────────────────────────
SELECT '지우기 전' AS 언제,
       (SELECT count(*) FROM routines)                AS 루틴,
       (SELECT count(*) FROM certifications)          AS 인증,
       (SELECT count(*) FROM book_purchases)          AS 구매,
       (SELECT count(*) FROM consumption_allocations) AS 기금배분,
       (SELECT count(*) FROM charges)                 AS 후원;

-- ── 지운다 ─────────────────────────────────────────────
DO $$
BEGIN
  DELETE FROM consumption_allocations;   -- RESTRICT 라 구매보다 먼저
  DELETE FROM completion_events;         -- 후원이 다 쓰였다고 만든 카드
  DELETE FROM book_purchases;
  DELETE FROM routines;                  -- 참여·인증·댓글·후기·콕·읽는책·공유글이 딸려 간다
  DELETE FROM charges;
  RAISE NOTICE '전부 지웠습니다.';
END $$;

-- ── 확인 ───────────────────────────────────────────────
SELECT '지운 뒤' AS 언제,
       (SELECT count(*) FROM routines)                AS 루틴,
       (SELECT count(*) FROM certifications)          AS 인증,
       (SELECT count(*) FROM book_purchases)          AS 구매,
       (SELECT count(*) FROM consumption_allocations) AS 기금배분,
       (SELECT count(*) FROM charges)                 AS 후원,
       (SELECT count(*) FROM profiles)                AS 회원_그대로,
       (SELECT count(*) FROM bookstores)              AS 책방_그대로;
