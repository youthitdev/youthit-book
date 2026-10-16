-- 한끗독서 마이그레이션 139
-- 모집이 끝난(진행 중) 루틴에는 새로 참여할 수 없다 (2026-10-16 사용자)
--
-- 【왜】 루틴 상태가 날짜에 맞춰 자동으로 바뀐다(134): 시작일이 되면 모집 중 → 진행 중. 그런데 참여 신청은
--   「끝난 루틴」만 막고 있어서, 진행 중인 루틴에도 참여 신청이 됐다. 이미 모집이 끝났으니 서버도 막는다.
--   (화면도 같이 바꿨다. 화면만 바꾸면 주소를 직접 부르는 경우가 남는다.)
--
-- 【그대로인 것】 나이·정원·책 제목·참여 각오·갈래별 규칙은 131 판과 같다. 이미 참여 중인 사람은 영향이 없다.
--   승인 대기(pending) 상태의 루틴에는 끗짱 본인 행이 들어갈 수 있어 막지 않는다 — 막는 건 진행 중(active)뿐이다.
--
-- ⚠️ 131 뒤에 돌린다. 여러 번 돌려도 된다.

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
  IF v_status = 'active' THEN
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
-- 기대: 함수가 새 판(진행 중 막는 판) 1
SELECT count(*) AS 새_판_1이어야 FROM pg_proc
 WHERE proname = 'check_participant_insert'
   AND pg_get_functiondef(oid) LIKE '%모집이 끝난 루틴이에요%';
