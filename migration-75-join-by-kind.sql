-- 한끗독서 마이그레이션 75
-- 루틴 갈래마다 참여할 때 받는 것이 다르다
--
-- 【무엇이 막혀 있었나】 참여 트리거가 갈래를 가리지 않고 책 사진과 제목을
--   반드시 받았다. 그래서—
--   · 함께 읽는 글(shared) — 책이 아예 없는 루틴인데 책을 내놓으라고 막았다
--   · 함께 읽는 책(one_book) — 끗짱이 표지를 안 걸었으면 사진이 비어 막혔다
--
-- 【갈래별로】
--   book     각자 고르니 사진도 제목도 받는다 (그대로)
--   one_book 끗짱이 정한 한 권이다. 제목만 보고, 표지는 있으면 쓴다
--   shared   책이 없다. 참여 각오만 받는다
--
-- 각오는 셋 다 받는다. 「왜 함께하고 싶은지」는 책과 상관없다.
--
-- ⚠️ check_participant_insert 는 16 → 17 → 17b → 37 → 41 로 덮어써졌다.
--   지금 살아 있는 것은 41번 판이고, 이 파일은 거기서 책 검사만 갈랐다.

CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text; v_age int; v_verify text; v_kind text;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  SELECT age_years(pp.birth_date) INTO v_age
    FROM profiles_private pp WHERE pp.id = NEW.user_id;
  SELECT p.verify_status INTO v_verify
    FROM profiles p WHERE p.id = NEW.user_id;

  -- 생년월일이 없는 사람(예전 가입자)은 나이로 막지 않는다
  IF v_age IS NOT NULL AND v_age < 14 THEN
    RAISE EXCEPTION '한끗독서는 만 14세부터 함께할 수 있어요';
  END IF;

  IF COALESCE(v_verify, 'none') <> 'approved' THEN
    RAISE EXCEPTION '청소년 확인이 끝나야 루틴에 참여할 수 있어요';
  END IF;

  NEW.status := 'approved';

  SELECT max_people, status, COALESCE(kind, 'book')
    INTO v_max, v_status, v_kind
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
    IF COALESCE(NEW.book_photo_url, '') = '' THEN
      RAISE EXCEPTION '읽을 책 사진을 올려주세요';
    END IF;
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
  SELECT count(*) INTO v_now FROM routine_participants
   WHERE routine_id = NEW.routine_id AND status = 'approved';
  IF v_max IS NOT NULL AND v_now >= v_max THEN
    RAISE EXCEPTION '정원이 찼어요';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT CASE WHEN pg_get_functiondef(oid) LIKE '%v_kind%'
            THEN '갈래를 가림' ELSE '아직 옛 판' END AS 참여검사
  FROM pg_proc WHERE proname = 'check_participant_insert';
