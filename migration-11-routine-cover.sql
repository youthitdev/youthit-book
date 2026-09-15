-- 한끗독서 마이그레이션 11
-- 루틴 대표 사진(썸네일)
--
-- 이모지만으로는 루틴이 다 비슷해 보인다. 청소년이 고를 때 눈에 걸리는 건
-- 사진이라, 끗짱이 대표 사진 한 장을 올릴 수 있게 한다. 없으면 이모지로 둔다.
--
-- ⚠️ 이 사진은 끗짱이 고른 홍보용 이미지다. 청소년의 인증 사진이나
--    책 구매 사진과 섞이지 않게 버킷을 따로 둔다.

ALTER TABLE routines ADD COLUMN IF NOT EXISTS cover_url text;

COMMENT ON COLUMN routines.cover_url IS
  '루틴 대표 사진. 끗짱이 올린다. 없으면 화면에서 emoji 로 대체된다';

-- 루틴 카드에 그대로 걸리는 이미지라 공개 버킷
INSERT INTO storage.buckets (id, name, public)
VALUES ('routine-covers', 'routine-covers', true) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "routine_covers_read" ON storage.objects;
CREATE POLICY "routine_covers_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'routine-covers');

-- 자기 폴더(uid)에만 올릴 수 있다
DROP POLICY IF EXISTS "routine_covers_own_insert" ON storage.objects;
CREATE POLICY "routine_covers_own_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'routine-covers'
              AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "routine_covers_own_update" ON storage.objects;
CREATE POLICY "routine_covers_own_update" ON storage.objects FOR UPDATE
  USING (bucket_id = 'routine-covers'
         AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));

DROP POLICY IF EXISTS "routine_covers_own_delete" ON storage.objects;
CREATE POLICY "routine_covers_own_delete" ON storage.objects FOR DELETE
  USING (bucket_id = 'routine-covers'
         AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));
