-- 한끗독서 마이그레이션 08
-- 필사를 루틴 옵션으로
--
-- 【배경】 필사는 사진 인증 방법(cert_guide)과 성격이 다르다. 사진을 어떻게
--   찍을지가 아니라, 문장을 옮겨 적는 걸 이 루틴의 일부로 삼을지의 문제다.
--   그래서 인증 방법 목록에서 빼고 별도 옵션으로 둔다.
--
--   끄면 지금과 같다 — '마음에 남은 문장'은 선택.
--   켜면 인증할 때 문장을 반드시 적어야 한다.
--
--   ⚠️ 모든 루틴에 필사를 강제하지는 않는다. 끗짱이 자기 루틴에 대해
--   고르는 것이고, 기본값은 꺼짐이다.

ALTER TABLE routines
  ADD COLUMN IF NOT EXISTS quote_required boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN routines.quote_required IS
  '켜면 인증할 때 마음에 남은 문장(certifications.quote)을 반드시 적어야 한다';
