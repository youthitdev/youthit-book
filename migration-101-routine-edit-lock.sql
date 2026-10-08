-- 한끗독서 마이그레이션 101
-- 루틴이 시작된 뒤의 수정: 흔들리면 안 되는 것은 잠그고, 고치면 운영진에게 알린다
--
-- 【잠그는 것】 (끗짱이 고칠 때만. 운영진은 그대로 고친다)
--   · 시작일        — 이미 쌓인 인증과 「N일째」 계산이 어긋난다
--   · 종료일        — 늘리기만. 줄이면 읽고 있는 아이의 일정이 줄어든다
--   · 모집 인원     — 지금 함께하는 아이 수보다 적게는 못 줄인다
--   · 책방          — 보고 들어온 아이가 갈 곳이 달라진다
--   · 함께 읽는 책(kind = 'one') — 아이들이 그 책을 보고 들어왔다
--   「시작한 뒤」는 승인이 끝난(pending 아님) 루틴이 시작일에 닿은 때다.
--   잠긴 칸은 오류를 내지 않고 **원래 값으로 되돌린다** (기존 규칙과 같은 방식).
-- 【알리는 것】 승인이 끝난 루틴의 내용을 끗짱이 고치면 운영진에게 「루틴이 수정됐어요」 알림이 간다.
--   무엇을 고쳤는지(제목·소개·인증 안내·기간·정원·공유회·사진·책)를 함께 적는다.
--
-- ⚠️ 58(check_routine_write)·78(admin_user_ids)·39(notify_push) 뒤에 돌린다.

-- ── 1. 잠금 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;

  IF NOT is_approved_kkut() THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.led_by := auth.uid();
    NEW.status := 'pending';
    NEW.sponsor_name := NULL;
  ELSE
    IF OLD.status = 'pending' AND NEW.status <> 'pending' THEN NEW.status := 'pending'; END IF;
    IF OLD.status <> 'pending' AND NEW.status = 'pending' THEN NEW.status := OLD.status; END IF;
    IF OLD.status = 'pending' THEN NEW.reject_reason := NULL; END IF;
    NEW.led_by       := OLD.led_by;
    NEW.sponsor_name := OLD.sponsor_name;
    NEW.kind         := OLD.kind;
    -- 공유회 조건은 켜는 건 만들 때만. 끄는 건 언제든 (모임이 취소될 수 있다)
    IF NOT OLD.meetup_required THEN NEW.meetup_required := false; END IF;

    -- 시작한 뒤에는 일정과 약속을 잠근다
    IF OLD.status <> 'pending' AND OLD.start_date <= (now() AT TIME ZONE 'Asia/Seoul')::date THEN
      NEW.start_date  := OLD.start_date;
      NEW.end_date    := GREATEST(NEW.end_date, OLD.end_date);
      NEW.max_people  := GREATEST(NEW.max_people,
                           (SELECT count(*) FROM routine_participants
                             WHERE routine_id = OLD.id AND status = 'approved')::int);
      NEW.bookstore_id := OLD.bookstore_id;
      IF OLD.kind = 'one' THEN
        NEW.kkut_book_title     := OLD.kkut_book_title;
        NEW.kkut_book_url       := OLD.kkut_book_url;
        NEW.kkut_book_isbn      := OLD.kkut_book_isbn;
        NEW.kkut_book_authors   := OLD.kkut_book_authors;
        NEW.kkut_book_publisher := OLD.kkut_book_publisher;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 2. 고치면 운영진에게 알린다 ────────────────────────
CREATE OR REPLACE FUNCTION notify_routine_edited() RETURNS trigger AS $$
DECLARE a uuid; what text[] := '{}';
BEGIN
  -- 끗짱이 고친 것만. 운영진 본인의 수정과 승인 전(어차피 확인한다) 수정은 알리지 않는다
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;
  IF OLD.status = 'pending' OR NEW.status = 'pending' THEN RETURN NEW; END IF;

  IF NEW.title IS DISTINCT FROM OLD.title OR NEW.emoji IS DISTINCT FROM OLD.emoji THEN what := what || '제목'; END IF;
  IF NEW.description IS DISTINCT FROM OLD.description THEN what := what || '소개'; END IF;
  IF NEW.cert_guide IS DISTINCT FROM OLD.cert_guide THEN what := what || '인증 안내'; END IF;
  IF NEW.end_date IS DISTINCT FROM OLD.end_date OR NEW.start_date IS DISTINCT FROM OLD.start_date THEN what := what || '기간'; END IF;
  IF NEW.max_people IS DISTINCT FROM OLD.max_people THEN what := what || '모집 인원'; END IF;
  IF NEW.meetup_at IS DISTINCT FROM OLD.meetup_at OR NEW.meetup_place IS DISTINCT FROM OLD.meetup_place
     OR NEW.meetup_detail IS DISTINCT FROM OLD.meetup_detail OR NEW.meetup_note IS DISTINCT FROM OLD.meetup_note
     OR NEW.meetup_required IS DISTINCT FROM OLD.meetup_required THEN what := what || '공유회'; END IF;
  IF NEW.cover_url IS DISTINCT FROM OLD.cover_url THEN what := what || '대표 사진'; END IF;
  IF NEW.kkut_book_title IS DISTINCT FROM OLD.kkut_book_title THEN what := what || '끗짱 책'; END IF;
  IF NEW.quote_required IS DISTINCT FROM OLD.quote_required OR NEW.camera_only IS DISTINCT FROM OLD.camera_only THEN what := what || '인증 방식'; END IF;

  IF cardinality(what) = 0 THEN RETURN NEW; END IF;

  FOR a IN SELECT * FROM admin_user_ids() LOOP
    PERFORM notify_push(a, '루틴이 수정됐어요 ✏️',
      COALESCE(NEW.title, '루틴') || ' · ' || array_to_string(what, ', ') || ' 을(를) 고쳤어요',
      '/youthit-book/admin.html');
  END LOOP;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;      -- 알림이 터져서 수정이 막히면 안 된다
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_edit_notify ON routines;
CREATE TRIGGER routines_edit_notify AFTER UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION notify_routine_edited();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 함수 몸통은 부를 때 비로소 검사되니, 쓰는 칸이 정말 있는지 먼저 센다. 기대: 칸 26, 나머지 모두 true
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'routines'
           AND column_name IN ('title','emoji','description','cert_guide','start_date','end_date','max_people',
                               'bookstore_id','kind','status','reject_reason','led_by','sponsor_name',
                               'meetup_required','meetup_at','meetup_place','meetup_detail','meetup_note',
                               'cover_url','quote_required','camera_only','kkut_book_title','kkut_book_url',
                               'kkut_book_isbn','kkut_book_authors','kkut_book_publisher')) AS 칸_26이어야,
       (pg_get_functiondef('check_routine_write'::regproc) LIKE '%GREATEST(NEW.end_date%')   AS 잠금_들어감,
       EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'routines_edit_notify')               AS 알림_트리거,
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'admin_user_ids')                       AS 운영진함수;
