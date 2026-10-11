-- 한끗독서 마이그레이션 118
-- 랜딩 「청소년들이 읽고 있는 책」에 운영진이 고른 공식 표지를 붙인다
--
-- 【왜】 랜딩 책 목록은 책 검색에서 고른 표지(routine_books.found_cover_url)만 쓴다. 청소년이 직접 찍어 올린 책 사진은
--   손이나 방이 찍혔을 수 있어 로그인 전 방문자에게 내보내지 않는다 (99). 그래서 책 제목을 손으로 쳐서 올린 책은
--   앱 안에서는 사진이 보이는데 랜딩에서는 표지가 없다 (2026-10-11 사용자: 「노 피플 존」 「양면의 조개껍데기」).
--
-- 【고침】 운영진이 관리자 화면 「책 표지」에서 그 책을 검색해 **맞는 판본의 표지를 직접 고른다**.
--   자동으로 첫 결과를 붙이지 않는다 — 같은 제목의 다른 판본(「데미안」 네 가지)을 가르는 건 사람이 한다.
--   고른 표지는 book_covers 에 책 이름(띄어쓰기·문장부호를 걷어낸 꼴)으로 저장되고, 랜딩 목록은 이것을 먼저 쓴다.
--   카카오가 준 주소를 그대로 건다 — 우리 저장소에 옮겨 담지 않는다 (95 와 같다).
--
-- 【청소년 사진은 여전히 쓰지 않는다】 이 파일이 늘리는 것은 운영진이 고른 공식 표지뿐이다.
--
-- ⚠️ 95·99 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS book_covers (
  k          text PRIMARY KEY,                 -- 책 이름에서 띄어쓰기·문장부호를 걷어낸 것 (99 와 같은 방식)
  title      text NOT NULL,                    -- 운영진이 고른 정식 제목
  cover_url  text NOT NULL,
  set_by     uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE book_covers ENABLE ROW LEVEL SECURITY;   -- 정책이 없으니 앱에서 직접은 못 읽고 쓴다. 아래 함수로만

-- 책 이름 → 같은 책 키 (99 의 정규식과 같다)
CREATE OR REPLACE FUNCTION book_key(p text) RETURNS text AS $$
  SELECT regexp_replace(lower(btrim(COALESCE(p, ''))), '[\s\.,:;!?()''"·~\-–—“”‘’「」『』]', '', 'g')
$$ LANGUAGE sql IMMUTABLE;

-- 랜딩 목록: 운영진이 고른 표지를 먼저, 없으면 검색해서 고른 표지 (반환 칸은 그대로)
CREATE OR REPLACE FUNCTION dokseo_books_reading(p_limit int DEFAULT 20)
RETURNS TABLE (book_title text, readers bigint, cover_url text) AS $$
  WITH c AS (
    SELECT ct.book_title AS t, ct.user_id, ct.created_at, book_key(ct.book_title) AS k
      FROM certifications ct
      JOIN profiles p ON p.id = ct.user_id
     WHERE ct.book_title IS NOT NULL AND btrim(ct.book_title) <> ''
       AND NOT COALESCE(p.can_lead, false)
       AND COALESCE(p.role, '') <> 'adult'
  ),
  cov AS (
    SELECT DISTINCT ON (k) k, t, found_cover_url
      FROM (
        SELECT book_key(title) AS k, title AS t, found_cover_url, created_at
          FROM routine_books
         WHERE found_cover_url IS NOT NULL AND btrim(found_cover_url) <> ''
      ) x
     ORDER BY k, created_at DESC
  ),
  g AS (
    SELECT k, count(DISTINCT user_id) AS readers, max(created_at) AS last_at,
           (array_agg(t ORDER BY created_at DESC))[1] AS t
      FROM c WHERE k <> '' GROUP BY k
  )
  SELECT COALESCE(bc.title, cov.t, g.t), g.readers, COALESCE(bc.cover_url, cov.found_cover_url)
    FROM g
    LEFT JOIN cov        ON cov.k = g.k
    LEFT JOIN book_covers bc ON bc.k = g.k
   ORDER BY g.last_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 40)
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION dokseo_books_reading(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION dokseo_books_reading(int) TO anon, authenticated;

-- 운영진: 표지가 아직 없는 책 (읽는 사람이 많은 순)
CREATE OR REPLACE FUNCTION admin_cover_books() RETURNS TABLE (book_title text, readers bigint) AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '운영진만 볼 수 있어요'; END IF;
  RETURN QUERY
    SELECT r.book_title, r.readers FROM dokseo_books_reading(40) r
     WHERE r.cover_url IS NULL OR btrim(r.cover_url) = ''
     ORDER BY r.readers DESC, r.book_title;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION admin_cover_books() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_cover_books() TO authenticated;

-- 운영진: 고른 표지를 저장한다 (같은 책이면 덮어쓴다)
CREATE OR REPLACE FUNCTION admin_set_book_cover(p_title text, p_cover text) RETURNS void AS $$
DECLARE v_k text := book_key(p_title);
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '운영진만 저장할 수 있어요'; END IF;
  IF v_k = '' THEN RAISE EXCEPTION '책 제목이 비었어요'; END IF;
  IF p_cover IS NULL OR p_cover !~ '^https://' OR length(p_cover) > 500 THEN
    RAISE EXCEPTION '표지 주소가 올바르지 않아요';
  END IF;
  INSERT INTO book_covers(k, title, cover_url, set_by)
  VALUES (v_k, left(btrim(p_title), 120), p_cover, auth.uid())
  ON CONFLICT (k) DO UPDATE
     SET title = EXCLUDED.title, cover_url = EXCLUDED.cover_url, set_by = EXCLUDED.set_by, updated_at = now();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_set_book_cover(text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_set_book_cover(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 저장하지 않는다. 기대: 함수 3 / 표 1 / 아래 목록은 랜딩에 지금 나가는 책과 표지 여부
SELECT (SELECT count(*) FROM pg_proc WHERE proname IN ('book_key', 'admin_cover_books', 'admin_set_book_cover')) AS 함수_3이어야,
       (SELECT count(*) FROM pg_class WHERE relname = 'book_covers')                                              AS 표_1이어야;
SELECT book_title AS 책, readers AS 읽는_청소년, (cover_url IS NOT NULL) AS 표지있음 FROM dokseo_books_reading(20);
