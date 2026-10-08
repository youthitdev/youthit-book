-- 한끗독서 마이그레이션 102
-- 프로필 사진 (청소년 · 끗짱 모두)
--
-- 【무엇】 profiles.avatar_url 한 칸과, 사진을 담는 공개 버킷 avatars.
--   사진은 앱이 정사각형(가운데 기준)으로 잘라 320px 로 줄여서 올린다.
-- 【누가 보나】 프로필 사진은 profiles 에 있어서 **읽는 범위가 닉네임과 같다** —
--   같은 루틴 사람끼리, 그리고 운영진. 로그인 전 방문자에게는 나가지 않는다
--   (끗짱을 보여 주는 routine_leads 에는 넣지 않았다).
--   ※ 버킷이 공개라서 **사진 주소를 아는 사람**은 열 수 있다. 주소는 같은 루틴 사람에게만 내려간다.
-- 【지우기】 본인은 사진을 바꾸거나 지울 수 있고, 운영진은 아래처럼 지울 수 있다.
--   UPDATE profiles SET avatar_url = NULL WHERE id = '<계정번호>';
--
-- ⚠️ 11(routine-covers)과 같은 방식이다. 돌려도 기존 데이터는 바뀌지 않는다.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_url text;
COMMENT ON COLUMN profiles.avatar_url IS '프로필 사진 주소(avatars 버킷). 없으면 이름 첫 글자 동그라미';

INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "avatars_read" ON storage.objects;
CREATE POLICY "avatars_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'avatars');

-- 자기 폴더(uid)에만 올릴 수 있다
DROP POLICY IF EXISTS "avatars_own_insert" ON storage.objects;
CREATE POLICY "avatars_own_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'avatars'
              AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "avatars_own_update" ON storage.objects;
CREATE POLICY "avatars_own_update" ON storage.objects FOR UPDATE
  USING (bucket_id = 'avatars'
         AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));

DROP POLICY IF EXISTS "avatars_own_delete" ON storage.objects;
CREATE POLICY "avatars_own_delete" ON storage.objects FOR DELETE
  USING (bucket_id = 'avatars'
         AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 칸 1, 버킷 1(공개), 정책 4
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'profiles' AND column_name = 'avatar_url')              AS 칸_1이어야,
       (SELECT count(*) FROM storage.buckets WHERE id = 'avatars' AND public)       AS 공개버킷_1이어야,
       (SELECT count(*) FROM pg_policies
         WHERE tablename = 'objects' AND policyname LIKE 'avatars_%')               AS 정책_4여야;
