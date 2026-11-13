-- 한끗독서 마이그레이션 170
-- 후기 탭의 「책 교환 인증」 — 운영진이 직접 올린 사진만 보인다 (2026-11-13 사용자 결정: 후기 탭 A안, 운영진이 책방 인증 사진을 내려받아 올림)
--
-- 【배경】 11월 5일(156)에 책방이 올린 교환 사진을 후기 탭에서 닫았다(운영진만 읽는 보관용).
--   이번에는 그 저장소를 다시 열지 않는다. 운영진이 사진을 내려받아 얼굴이 나오지 않는지 확인한 뒤
--   **새 저장소**에 직접 올리고, 앱 후기 탭은 이 표에 올라온 것만 보여 준다.
--
-- 【무엇을】
--   1. exchange_posts 표: 사진 경로 · 책방 이름 · 날짜 · 보임 여부. 청소년 이름·닉네임은 담지 않는다.
--   2. 비공개 저장소 exchange-photos: 로그인한 사람이 읽고(서명 주소로 본다), 올리기·지우기는 운영진만.
--   3. 표 읽기: 로그인한 사람은 보이는 것만, 운영진은 전부. 쓰기는 운영진만.
-- 되돌리려면: 관리자 「책 교환 사진」에서 「숨기기」(앱에서만 빠짐) 또는 「지우기」(사진 파일까지 삭제).
-- ⚠️ 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS exchange_posts (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  photo_path  text   NOT NULL,
  store_name  text   NOT NULL,
  day         date   NOT NULL,
  active      boolean NOT NULL DEFAULT true,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exchange_posts_day_idx ON exchange_posts (day DESC, id DESC);

ALTER TABLE exchange_posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS exchange_posts_read ON exchange_posts;
CREATE POLICY exchange_posts_read ON exchange_posts FOR SELECT TO authenticated
  USING (active OR is_admin());

DROP POLICY IF EXISTS exchange_posts_admin ON exchange_posts;
CREATE POLICY exchange_posts_admin ON exchange_posts FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('exchange-photos', 'exchange-photos', false, 5242880)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS exchange_photos_read ON storage.objects;
CREATE POLICY exchange_photos_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'exchange-photos');

DROP POLICY IF EXISTS exchange_photos_insert ON storage.objects;
CREATE POLICY exchange_photos_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'exchange-photos' AND is_admin());

DROP POLICY IF EXISTS exchange_photos_delete ON storage.objects;
CREATE POLICY exchange_photos_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'exchange-photos' AND is_admin());

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 표 1 / 표 정책 2 / 저장소 1 / 저장소 정책 3
SELECT (SELECT count(*) FROM pg_tables WHERE tablename = 'exchange_posts')                                  AS 표_1이어야,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'exchange_posts')                                AS 표정책_2여야,
       (SELECT count(*) FROM storage.buckets WHERE id = 'exchange-photos' AND NOT public)                   AS 저장소_1이어야,
       (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND policyname LIKE 'exchange_photos_%') AS 저장소정책_3이어야;
