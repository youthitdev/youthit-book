-- 루틴 전부 지우기 (테스트 데이터 정리)
-- ⚠️ 한 번에 두 덩이를 다 돌리지 마세요. ①을 먼저 보고, 괜찮으면 ②를 돌립니다.

-- ── ① 먼저 무엇이 딸려 나가는지 본다 ──────────────────
-- 루틴을 지우면 아래가 **전부 같이 지워집니다** (ON DELETE CASCADE).
SELECT (SELECT count(*) FROM routines)              AS 루틴,
       (SELECT count(*) FROM routine_participants)  AS 참여,
       (SELECT count(*) FROM certifications)        AS 인증,
       (SELECT count(*) FROM cert_comments)         AS 댓글,
       (SELECT count(*) FROM routine_books)         AS 읽는책,
       (SELECT count(*) FROM reviews)               AS 후기,
       (SELECT count(*) FROM nudges)                AS 콕,
       (SELECT count(*) FROM routine_posts)         AS 공유글,
       (SELECT count(*) FROM book_purchases)        AS 책구매,
       (SELECT count(*) FROM book_purchases
         WHERE status = 'settled')                  AS 정산끝난_구매;

-- ⚠️⚠️ 「정산끝난_구매」가 0 이 아니면 멈추세요.
--   그건 유스보이스가 책방에 **실제로 돈을 보낸 기록**입니다.
--   기부금 사용명세에 들어가는 자료라 지우면 안 됩니다.
--   그 경우에는 아래 ② 대신 저에게 알려주세요 — 그 루틴만 빼고 지우면 됩니다.

-- ── ② 확인했으면 여기를 돌린다 ────────────────────────
-- 정산 끝난 구매가 하나라도 있으면 스스로 멈춥니다.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM book_purchases WHERE status = 'settled';
  IF n > 0 THEN
    RAISE EXCEPTION '정산이 끝난 구매가 % 건 있습니다. 돈이 오간 기록이라 지울 수 없습니다.', n;
  END IF;

  -- 사진은 Storage 에 그대로 남습니다. DB 줄만 지웁니다
  DELETE FROM routines;
END $$;

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM routines)             AS 남은루틴,
       (SELECT count(*) FROM certifications)       AS 남은인증,
       (SELECT count(*) FROM book_purchases)       AS 남은구매,
       (SELECT count(*) FROM profiles)             AS 회원은그대로,
       (SELECT count(*) FROM bookstores)           AS 책방은그대로;
