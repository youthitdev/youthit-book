-- 한끗독서 마이그레이션 125
-- 홈의 「공지」 (2026-10-13 사용자) — 운영진이 쓰고, 청소년과 끗짱의 홈 맨 위에 한 줄로 보인다
--
-- 【구조】 공지는 제목·본문·보이는 기간만 가진다. 홈에는 가장 최근 공지 한 줄이 나오고, 누르면 창에 공지 목록이 열린다.
--   · 보이는 기간(ends_at)이 비어 있으면 운영진이 내릴 때까지 계속 보인다. 지난 공지는 보이지 않는다.
--   · 읽었는지는 각자 폰에 적는다 (홈의 작은 점). 서버는 모른다.
--   · 푸시 알림은 선택이다. 올릴 때 운영진이 체크하면 기존 「알림 보내기」(scheduled_notifications, 44)에 바로 넣는다.
--
-- 【누가 읽나】 로그인한 회원 누구나 (지금 보이는 공지만). 쓰고 고치고 내리는 것은 운영진만.
--
-- ⚠️ 44 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS notices (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  title      text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 80),
  body       text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 2000),
  starts_at  timestamptz NOT NULL DEFAULT now(),
  ends_at    timestamptz,                         -- 비어 있으면 내릴 때까지 계속
  created_by uuid REFERENCES auth.users ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notices_active_idx ON notices (starts_at DESC);
COMMENT ON TABLE notices IS '홈에 보이는 운영진 공지';

ALTER TABLE notices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notices_read  ON notices;
CREATE POLICY notices_read ON notices FOR SELECT TO authenticated
  USING (is_admin() OR (starts_at <= now() AND (ends_at IS NULL OR ends_at > now())));

DROP POLICY IF EXISTS notices_admin ON notices;
CREATE POLICY notices_admin ON notices FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 올리지 않는다. 기대: 표 1 / 정책 2
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_name = 'notices') AS 표_1이어야,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'notices')                AS 정책_2여야;
