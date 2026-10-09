-- 한끗독서 마이그레이션 105
-- 인증에 좋아요
--
-- 【무엇】 같은 루틴 사람이 인증 한 장에 ♥ 를 누른다. 다시 누르면 취소된다. 한 사람이 한 장에 한 번.
--   댓글처럼 「볼 수 있는 인증」에만 누를 수 있다 (can_see_cert, 23).
--   남의 루틴 인증 번호를 찍어 넣어도 막힌다.
--
-- 【본인 인증에는】 화면에서 단추를 감춘다. 표에서는 막지 않는다 (막는 이득이 작고 정책만 복잡해진다).
--
-- 【알림은 아직 없다】 ♥ 하나에 푸시가 울리면 너무 잦다. 써 보고 정한다.
--
-- ⚠️ 23(can_see_cert) 뒤에 돌린다.

CREATE TABLE IF NOT EXISTS cert_likes (
  cert_id    bigint NOT NULL REFERENCES certifications(id) ON DELETE CASCADE,
  user_id    uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cert_id, user_id)
);
CREATE INDEX IF NOT EXISTS cert_likes_user_idx ON cert_likes(user_id);

ALTER TABLE cert_likes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS likes_read   ON cert_likes;
DROP POLICY IF EXISTS likes_add    ON cert_likes;
DROP POLICY IF EXISTS likes_remove ON cert_likes;
CREATE POLICY likes_read   ON cert_likes FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin() OR can_see_cert(cert_id));
CREATE POLICY likes_add    ON cert_likes FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND can_see_cert(cert_id));
CREATE POLICY likes_remove ON cert_likes FOR DELETE TO authenticated
  USING (user_id = auth.uid());

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 표 1, 정책 3, 칸 3
SELECT (SELECT count(*) FROM information_schema.tables  WHERE table_name = 'cert_likes') AS 표_1이어야,
       (SELECT count(*) FROM pg_policies               WHERE tablename  = 'cert_likes') AS 정책_3이어야,
       (SELECT count(*) FROM information_schema.columns WHERE table_name = 'cert_likes') AS 칸_3이어야;
