-- 한끗독서 마이그레이션 129
-- 루틴 화면에서 「함께 읽는 친구들」 — 닉네임과 읽는 책 표지 (2026-10-14 사용자)
--
-- 【왜】 신청하러 들어온 청소년이 제일 궁금한 건 「누가 같이 읽지? 무슨 책이지?」다. 보이면 고르기 쉽고 소속감이 생긴다.
--   그런데 남의 루틴의 참여자 줄은 RLS 가 막아 두어서 앱이 직접 읽을 수 없다. 그래서 **닉네임과 공식 표지만** 돌려주는 함수를 낸다.
--
-- 【무엇이 나가나】 닉네임 · 읽는 책 제목 · 그 책의 **공식 표지 주소**(책 검색에서 고른 것, found_cover_url).
--   · 이름·지역·학교·나이·프로필 사진·직접 찍은 책 사진은 나가지 않는다 (사진은 손이나 방이 찍혔을 수 있다 — 99 와 같은 원칙)
--   · 닉네임이 비어 있으면 「친구」로 보인다 (실명으로 대신하지 않는다)
--   · **승인되어 참여 중인 청소년만** 나온다. 신청 대기·반려, 끗짱, 탈퇴한 회원은 나오지 않는다
--   · 모집 중이거나 진행 중인 루틴만 (끝난 루틴과 열리기 전 심사 중인 루틴은 비운다)
--
-- 【누가 볼 수 있나】 로그인한 회원 중 **청소년 확인이 끝난 사람**, 끗짱, 운영진. 둘러보기(비로그인)와 확인 전 회원에게는
--   빈 목록이다. 참여 여부와 상관없이 신청 전에도 본다 (사용자가 정했다 — 닉네임과 표지 정도라서).
--
-- ⚠️ 30·95·123 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION routine_members(p_routine bigint)
RETURNS TABLE (nick text, books jsonb) AS $$
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), '친구'),
         COALESCE((SELECT jsonb_agg(jsonb_build_object('t', b.title, 'c', NULLIF(btrim(COALESCE(b.found_cover_url, '')), ''))
                                    ORDER BY b.created_at)
                     FROM routine_books b
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
     -- 볼 수 있는 사람. SQL 편집기(auth.uid() 없음)는 시험용으로 통과
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
-- 아무것도 바꾸지 않는다. 루틴마다 보이는 친구 수와 그중 공식 표지가 있는 책 수. 기대: 함수 1
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'routine_members') AS 함수_1이어야;
SELECT r.id AS 루틴, r.title AS 이름, r.status AS 상태,
       (SELECT count(*) FROM routine_members(r.id)) AS 보이는_친구,
       (SELECT count(*) FROM routine_members(r.id) m, jsonb_array_elements(m.books) e WHERE e->>'c' IS NOT NULL) AS 공식표지_있는_책
  FROM routines r ORDER BY r.id DESC LIMIT 10;
