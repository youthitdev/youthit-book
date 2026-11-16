-- 한끗독서 마이그레이션 174
-- 책 교환 사진을 랜딩(홈페이지)에도 — 운영진이 한 번 올리면 앱 후기 탭과 랜딩에 같이 보인다 (2026-11-16 사용자: A안)
--
-- 【전제】 올리는 사진은 얼굴이 나오지 않거나 동의를 받은 것만이다 (운영진이 올리기 전에 확인한다).
--
-- 【하는 일】
--   1. exchange_posts.book_title — 책 이름(선택). 사진 아래에 『책 이름』으로 붙는다.
--   2. exchange_posts.landing — 랜딩에도 보일지(기본 켜짐). 앱 후기 탭에는 항상 보이고, 이 칸은 랜딩만 정한다.
--   3. 저장소 exchange-photos 를 공개로 바꾼다. 랜딩은 로그인 전 화면이라 서명 주소를 못 쓴다.
--      ⚠️ 공개 저장소는 사진 주소를 아는 사람이면 누구나 열 수 있다. 「랜딩에서 빼기」를 해도 주소를 아는 사람에게는 열린다.
--         (주소는 앱에 로그인한 회원과 운영진에게만 보인다.) 그래서 얼굴 확인·동의 확인을 올리기 전에 한다.
--   4. dokseo_exchange_photos(개수) — 랜딩이 부르는 목록. 보임(active)이고 랜딩 켜짐(landing)인 것만, 책방 이름·날짜·책 이름만 준다.
-- 되돌리려면: UPDATE storage.buckets SET public = false WHERE id = 'exchange-photos';  (랜딩 사진이 안 보인다. 앱은 서명 주소라 그대로)
-- ⚠️ 170 뒤에 돌린다. 여러 번 돌려도 된다.

ALTER TABLE exchange_posts ADD COLUMN IF NOT EXISTS book_title text;
ALTER TABLE exchange_posts ADD COLUMN IF NOT EXISTS landing    boolean NOT NULL DEFAULT true;

UPDATE storage.buckets SET public = true WHERE id = 'exchange-photos';

CREATE OR REPLACE FUNCTION dokseo_exchange_photos(p_limit int DEFAULT 12)
RETURNS TABLE (photo_path text, store_name text, day date, book_title text) AS $$
  SELECT e.photo_path, e.store_name, e.day, e.book_title
    FROM exchange_posts e
   WHERE e.active AND e.landing
   ORDER BY e.day DESC, e.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 30)
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION dokseo_exchange_photos(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION dokseo_exchange_photos(int) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 칸 둘 2 / 저장소 공개 1 / 함수 1 / 익명 호출 true
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'exchange_posts' AND column_name IN ('book_title', 'landing'))      AS 칸_2여야,
       (SELECT count(*) FROM storage.buckets WHERE id = 'exchange-photos' AND public)            AS 공개저장소_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_exchange_photos')                   AS 함수_1이어야,
       has_function_privilege('anon', 'dokseo_exchange_photos(int)', 'EXECUTE')                  AS 익명호출_true여야;
