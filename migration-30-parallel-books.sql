-- 한끗독서 마이그레이션 30
-- 한 루틴에서 여러 권을 나눠 읽는다 (병렬독서). 한 번에 세 권까지.
--
-- 지금도 certifications 는 인증마다 책 제목을 따로 갖고, 쪽수도 책별로 센다.
-- 그러니 두 권을 번갈아 읽는 것 자체는 이미 된다. 모자란 건 두 가지다.
--
--   1. 인증할 때마다 제목을 손으로 고쳐 써야 한다. 오타가 나면 같은 책이
--      두 권으로 갈라진다 — 「아무튼, 메모」와 「아무튼 메모」.
--   2. 둘째·셋째 책의 표지 사진을 둘 자리가 없다.
--      routine_participants.book_photo_url 은 한 장뿐이다.
--
-- 그래서 「내가 이 루틴에서 읽는 책」 목록을 따로 둔다. 화면은 이걸 칩으로
-- 보여주고, 아이는 눌러서 고른다. 제목을 다시 칠 일이 없다.

CREATE TABLE IF NOT EXISTS routine_books (
  routine_id bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  user_id    uuid   NOT NULL REFERENCES auth.users   ON DELETE CASCADE,
  title      text   NOT NULL CHECK (btrim(title) <> ''),
  cover_url  text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (routine_id, user_id, title)
);
CREATE INDEX IF NOT EXISTS routine_books_mine ON routine_books (user_id, routine_id, created_at);

COMMENT ON TABLE routine_books IS '한 루틴에서 내가 읽는 책 (병렬독서, 최대 3권)';

-- 세 권 상한. 화면에서도 막지만 서버에도 건다
CREATE OR REPLACE FUNCTION check_routine_book() RETURNS trigger AS $$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;
  SELECT count(*) INTO v_n FROM routine_books
   WHERE routine_id = NEW.routine_id AND user_id = NEW.user_id;
  IF v_n >= 3 THEN
    RAISE EXCEPTION '한 루틴에서는 세 권까지 읽을 수 있어요';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routine_books_cap ON routine_books;
CREATE TRIGGER routine_books_cap BEFORE INSERT ON routine_books
  FOR EACH ROW EXECUTE FUNCTION check_routine_book();

ALTER TABLE routine_books ENABLE ROW LEVEL SECURITY;

-- 읽기는 인증과 같은 범위로 맞춘다 — 같은 루틴 참여자와 그 루틴 끗짱
DROP POLICY IF EXISTS rbooks_read ON routine_books;
CREATE POLICY rbooks_read ON routine_books FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin() OR routine_id IN (SELECT visible_routine_ids()));

DROP POLICY IF EXISTS rbooks_own_write ON routine_books;
CREATE POLICY rbooks_own_write ON routine_books FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS rbooks_own_update ON routine_books;
CREATE POLICY rbooks_own_update ON routine_books FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS rbooks_own_delete ON routine_books;
CREATE POLICY rbooks_own_delete ON routine_books FOR DELETE TO authenticated
  USING (user_id = auth.uid() OR is_admin());

-- 이미 참여하면서 적어둔 책을 첫 권으로 옮긴다. 표지 사진도 같이
INSERT INTO routine_books (routine_id, user_id, title, cover_url, created_at)
SELECT p.routine_id, p.user_id, btrim(p.book_title), p.book_photo_url, p.joined_at
  FROM routine_participants p
 WHERE p.status = 'approved' AND COALESCE(btrim(p.book_title), '') <> ''
ON CONFLICT DO NOTHING;

-- 인증에만 남아 있던 책도 옮긴다 (표지는 없다). 참여자당 세 권을 넘지 않게 자른다
INSERT INTO routine_books (routine_id, user_id, title, created_at)
SELECT routine_id, user_id, title, first_day FROM (
  SELECT c.routine_id, c.user_id, btrim(c.book_title) AS title,
         min(c.created_at) AS first_day,
         row_number() OVER (PARTITION BY c.routine_id, c.user_id ORDER BY min(c.created_at)) AS rn
    FROM certifications c
   WHERE COALESCE(btrim(c.book_title), '') <> ''
   GROUP BY c.routine_id, c.user_id, btrim(c.book_title)
) t WHERE rn <= 3
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ↓ 사람별로 몇 권이 됐나. 줄이 나와야 성공이다
SELECT p.name AS 이름, b.routine_id AS 루틴, count(*) AS 책수,
       string_agg(b.title, ' · ' ORDER BY b.created_at) AS 책
  FROM routine_books b JOIN profiles p ON p.id = b.user_id
 GROUP BY p.name, b.routine_id ORDER BY 3 DESC;
