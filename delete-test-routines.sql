-- 테스트 루틴 둘을 지운다 (2026-09-30, 사용자 확인)
--   「하루 10분 책읽기」 · 「하루 한장 책읽기」
--
-- 이 둘에 딸린 「정산 끝남」 구매는 테스트로 넣어본 것이라고 확인받았다.
-- 그래서 그 구매를 먼저 지우고, 루틴을 지운다.
-- (구매가 남아 있으면 routines_del_guard 트리거가 막는다 — 그게 정상이다)
--
-- ⚠️ 편집기는 이 붙여넣기를 **한 덩이로** 돌린다. 하나라도 틀어지면 전부 되돌아간다.
-- ⚠️ 제목이 정확히 둘이 아니면 스스로 멈춘다.

DO $$
DECLARE
  v_ids   bigint[];
  v_buy   int;
  v_cert  int;
BEGIN
  SELECT array_agg(id) INTO v_ids
    FROM routines
   WHERE title IN ('하루 10분 책읽기', '하루 한장 책읽기');

  IF v_ids IS NULL OR array_length(v_ids, 1) <> 2 THEN
    RAISE EXCEPTION '그 제목의 루틴이 정확히 둘이 아닙니다 (찾은 것: %). 멈춥니다.',
      COALESCE(array_length(v_ids, 1), 0);
  END IF;

  SELECT count(*) INTO v_buy  FROM book_purchases WHERE routine_id = ANY(v_ids);
  SELECT count(*) INTO v_cert FROM certifications WHERE routine_id = ANY(v_ids);
  RAISE NOTICE '지웁니다 — 루틴 %, 인증 %건, 구매 %건', v_ids, v_cert, v_buy;

  -- 구매를 먼저 치운다. 안 그러면 트리거가 막는다
  DELETE FROM book_purchases WHERE routine_id = ANY(v_ids);

  -- 나머지(참여·인증·댓글·후기·읽는 책·콕·공유글)는 딸려서 같이 지워진다
  DELETE FROM routines WHERE id = ANY(v_ids);
END $$;

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM routines
         WHERE title IN ('하루 10분 책읽기', '하루 한장 책읽기'))        AS 남은_그루틴,
       (SELECT count(*) FROM routines)                                  AS 전체루틴,
       (SELECT count(*) FROM certifications)                            AS 남은인증,
       (SELECT count(*) FROM book_purchases)                            AS 남은구매,
       (SELECT count(*) FROM book_purchases WHERE status = 'settled')   AS 남은_정산끝남;
