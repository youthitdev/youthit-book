-- 한끗독서 마이그레이션 82
-- 청소년 확인 전에도 루틴에 들어올 수 있다 (2026-10-06 사용자 결정)
--
-- 【무엇을 되돌리나】 37 번에서 「확인이 끝나야 참여」로 막았다. 승인이 하루
--   밀리면 아이는 그 하루를 아무것도 못 하고 기다렸다. 기다리는 동안 앱을
--   지우는 아이가 생긴다. 들어와서 먼저 읽기 시작하게 한다.
--
-- 【그래도 돈은 그대로 막힌다】 교환권과 책은 `check_purchase_verified` 가
--   따로 지킨다 — role='youth' 이고 verify_status='approved' 여야 한다.
--   도서기금은 기부금 사용명세에 들어가는 돈이라 거기는 안 연다.
--
-- ⚠️ 【열린 것을 알고 열었다】 루틴에 들어오면 그 루틴의 인증 사진·문장·댓글이
--   보인다(visible_routine_ids). 아이들 사진에는 얼굴·방·교복이 찍히고
--   cert-photos 는 아직 공개 버킷이다. 사용자에게 알렸고, 그래도 열기로 했다.
--   나중에 좁힌다면 손댈 자리는 `visible_routine_ids()` 한 곳이다.
--
-- 나이(만 14세)는 그대로 막는다. 그건 확인과 다른 선이다.

CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text; v_age int; v_kind text;
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
-- 참여 문에서 확인 검사가 빠졌는지, 구매 문에는 남아 있는지 같이 본다
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname = 'check_participant_insert'
      AND pg_get_functiondef(p.oid) NOT LIKE '%청소년 확인이 끝나야 루틴에%')  AS 참여_열림,
  (SELECT count(*) FROM pg_proc p
    WHERE p.proname = 'check_purchase_verified'
      AND pg_get_functiondef(p.oid) LIKE '%청소년 확인이 끝나야 책을%')        AS 책_막힘,
  (SELECT count(*) FROM profiles WHERE COALESCE(verify_status,'none') <> 'approved')
                                                                              AS 확인전인원;
