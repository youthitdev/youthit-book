-- 한끗독서 마이그레이션 99
-- 랜딩 「청소년들이 읽고 있는 책」 — 끗짱의 책을 빼고, 표지를 함께 내보낸다
--
-- 【문제】 이 목록은 certifications 를 통째로 세서, 끗짱이 읽은 책이 「청소년들이 읽고 있는 책」에 섞였다.
--   → 끗짱(can_lead)과 어른(role = 'adult')의 인증은 센다 하지 않는다.
-- 【표지】 routine_books.found_cover_url (95. 책 검색에서 고른 표지, 카카오가 준 주소)만 쓴다.
--   아이가 **직접 찍어 올린 책 사진**(cover_url)은 로그인 전 방문자에게 내보내지 않는다 —
--   손이나 방이 찍혔을 수 있다. 표지가 없는 책은 제목만 나간다.
-- 【같은 책】 띄어쓰기·문장부호만 다른 제목(「안녕이라그랬어」/「안녕이라 그랬어」)은 한 권으로 묶는다.
--   표지가 있는 쪽 제목을 쓴다.
-- 반환 칸이 늘어서 지우고 다시 만든다. 기존 칸(book_title, readers)은 그대로라 옛 화면도 그대로 돈다.
-- ⚠️ 95 뒤에 돌린다.

DROP FUNCTION IF EXISTS dokseo_books_reading(int);

CREATE OR REPLACE FUNCTION dokseo_books_reading(p_limit int DEFAULT 20)
RETURNS TABLE (book_title text, readers bigint, cover_url text) AS $$
  WITH c AS (
    SELECT ct.book_title AS t, ct.user_id, ct.created_at,
           regexp_replace(lower(btrim(ct.book_title)), '[\s\.,:;!?()''"·~\-–—“”‘’「」『』]', '', 'g') AS k
      FROM certifications ct
      JOIN profiles p ON p.id = ct.user_id
     WHERE ct.book_title IS NOT NULL AND btrim(ct.book_title) <> ''
       AND NOT COALESCE(p.can_lead, false)
       AND COALESCE(p.role, '') <> 'adult'
  ),
  cov AS (
    SELECT DISTINCT ON (k) k, t, found_cover_url
      FROM (
        SELECT regexp_replace(lower(btrim(title)), '[\s\.,:;!?()''"·~\-–—“”‘’「」『』]', '', 'g') AS k,
               title AS t, found_cover_url, created_at
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
  SELECT COALESCE(cov.t, g.t), g.readers, cov.found_cover_url
    FROM g LEFT JOIN cov ON cov.k = g.k
   ORDER BY g.last_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 40)
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION dokseo_books_reading(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION dokseo_books_reading(int) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 함수를 실제로 불러 본다 (정규식·조인이 틀리면 여기서 오류가 난다).
-- 기대: 끗짱이 읽은 책은 빠진 목록. 표지는 95 뒤에 검색해서 고른 책에만 붙는다
SELECT book_title AS 책, readers AS 읽는_청소년, (cover_url IS NOT NULL) AS 표지있음
  FROM dokseo_books_reading(20);
