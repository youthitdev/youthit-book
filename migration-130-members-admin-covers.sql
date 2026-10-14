-- 한끗독서 마이그레이션 130
-- 「함께 읽는 친구들」에 운영진이 고른 표지도 쓴다
--
-- 【문제】 129 는 책 검색에서 고른 표지(routine_books.found_cover_url)만 읽었다. 운영진이 관리자 「책 표지」에서
--   골라 둔 표지(book_covers, 118)는 반영되지 않아서, 손으로 제목만 적은 책은 계속 표지 없이 보였다.
--
-- 【고침】 책 이름(띄어쓰기·문장부호를 걷어낸 꼴)으로 운영진이 고른 표지를 먼저 찾고, 없으면 검색해서 고른 표지를 쓴다.
--   랜딩 「청소년이 읽는 책」(118)과 같은 순서다. 청소년이 직접 찍은 사진은 여전히 쓰지 않는다.
--
-- ⚠️ 118·129 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION routine_members(p_routine bigint)
RETURNS TABLE (nick text, books jsonb) AS $$
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), '친구'),
         COALESCE((SELECT jsonb_agg(jsonb_build_object('t', b.title,
                                      'c', COALESCE(NULLIF(btrim(bc.cover_url), ''), NULLIF(btrim(COALESCE(b.found_cover_url, '')), '')))
                                    ORDER BY b.created_at)
                     FROM routine_books b
                     LEFT JOIN book_covers bc ON bc.k = book_key(b.title)
                    WHERE b.routine_id = rp.routine_id AND b.user_id = rp.user_id), '[]'::jsonb)
    FROM routine_participants rp
    JOIN routines r ON r.id = rp.routine_id
    JOIN profiles p ON p.id = rp.user_id
   WHERE rp.routine_id = p_routine
     AND rp.status = 'approved'
     AND r.status IN ('recruit', 'active')
     AND p.withdrawn_at IS NULL
     AND COALESCE(p.role, 'youth') = 'youth'
     AND NOT COALESCE(p.can_lead, false)
     AND ( auth.uid() IS NULL
           OR is_admin()
           OR EXISTS (SELECT 1 FROM profiles me
                       WHERE me.id = auth.uid() AND me.withdrawn_at IS NULL
                         AND (me.verify_status = 'approved' OR me.can_lead)) )
   ORDER BY rp.joined_at
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION routine_members(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION routine_members(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 129 의 표와 같은 모양 — 「공식표지_있는_책」이 같거나 늘어나야 한다
SELECT r.id AS 루틴, r.title AS 이름, r.status AS 상태,
       (SELECT count(*) FROM routine_members(r.id)) AS 보이는_친구,
       (SELECT count(*) FROM routine_members(r.id) m, jsonb_array_elements(m.books) e WHERE e->>'c' IS NOT NULL) AS 공식표지_있는_책,
       (SELECT count(*) FROM routine_members(r.id) m, jsonb_array_elements(m.books) e WHERE e->>'c' IS NULL) AS 표지_없는_책
  FROM routines r WHERE r.status IN ('recruit', 'active') ORDER BY r.id DESC LIMIT 10;
