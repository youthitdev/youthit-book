-- 한끗독서 마이그레이션 141
-- 루틴이 시작하는 날(1일차)에도 참여 신청을 받는다 (2026-10-17 사용자)
--
-- 【왜】 139 로 「진행 중」인 루틴에는 신청이 막혔다. 그런데 루틴 상태는 시작일 0시 10분에 자동으로 「진행 중」으로 바뀌어서
--   (134), 1일차 당일에 신청하려는 아이는 시작하는 날에 이미 막혔다. 1일차 당일에 신청하는 아이들이 있어서 그날까지는 연다.
--
-- 【규칙】 모집 중이거나, 「진행 중」이어도 **시작일이 오늘(한국 시간)** 이면 받는다. 시작일 다음 날부터는 막는다.
--   화면(app.html)도 같은 규칙이다 (joinOpen).
--
-- 【그대로인 것】 나이·정원·책 제목·참여 각오·갈래별 규칙, 끝난 루틴은 막는 것은 139 판과 같다.
--
-- ⚠️ 131·139 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text; v_age int; v_kind text; v_start date;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  SELECT age_years(pp.birth_date) INTO v_age
    FROM profiles_private pp WHERE pp.id = NEW.user_id;

  -- 생년월일이 없는 사람(예전 가입자)은 나이로 막지 않는다
  IF v_age IS NOT NULL AND v_age < 14 THEN
    RAISE EXCEPTION '한끗독서는 만 14세부터 함께할 수 있어요';
  END IF;

  -- 청소년 확인은 여기서 묻지 않는다. 책을 받을 때 check_purchase_verified 가 본다

  NEW.status := 'approved';

  SELECT max_people, status, COALESCE(kind, 'book'), start_date
    INTO v_max, v_status, v_kind, v_start
    FROM routines WHERE id = NEW.routine_id;

  IF v_kind = 'shared' THEN
    -- 책이 없는 루틴이다. 들고 있지도 않은 걸 내놓으라고 하지 않는다
    NEW.book_title := NULL;
    NEW.book_photo_url := NULL;
  ELSIF v_kind = 'one_book' THEN
    -- 끗짱이 정한 한 권. 제목은 있어야 하고, 표지는 있으면 쓴다
    IF COALESCE(btrim(NEW.book_title), '') = '' THEN
      RAISE EXCEPTION '끗짱이 아직 읽을 책을 정하지 않았어요';
    END IF;
  ELSE
    -- 책 사진은 받지 않아도 된다 (선택). 제목만 있으면 된다 — 표지는 검색에서 고른 공식 표지를 쓴다
    IF COALESCE(btrim(NEW.book_title), '') = '' THEN
      RAISE EXCEPTION '읽을 책 제목을 적어주세요';
    END IF;
  END IF;

  IF COALESCE(btrim(NEW.note), '') = '' THEN
    RAISE EXCEPTION '참여 각오를 적어주세요';
  END IF;

  IF v_status = 'done' THEN
    RAISE EXCEPTION '이미 끝난 루틴이에요';
  END IF;
  -- 진행 중이어도 시작하는 날(1일차)까지는 받는다. 다음 날부터 막는다
  IF v_status = 'active' AND v_start IS DISTINCT FROM (now() AT TIME ZONE 'Asia/Seoul')::date THEN
    RAISE EXCEPTION '모집이 끝난 루틴이에요';
  END IF;
  SELECT count(*) INTO v_now FROM routine_participants
   WHERE routine_id = NEW.routine_id AND status = 'approved';
  IF v_max IS NOT NULL AND v_now >= v_max THEN
    RAISE EXCEPTION '정원이 찼어요';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 새 판(시작하는 날까지 받는 판) 1
SELECT count(*) AS 새판_1이어야 FROM pg_proc
 WHERE proname = 'check_participant_insert'
   AND pg_get_functiondef(oid) LIKE '%Asia/Seoul%'
   AND pg_get_functiondef(oid) LIKE '%모집이 끝난 루틴이에요%';
