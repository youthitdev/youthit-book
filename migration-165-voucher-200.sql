-- 한끗독서 마이그레이션 165
-- 교환권 한 장 = 200N (2026-11-13 사용자). 지금까지는 150N이었다.
--
-- 【하는 일】 설정 points_per_voucher 를 200 으로 맞춘다. 화면·서버 계산식은 모두 이 값을 읽는다.
--   이미 200으로 바꿔 두셨다면 아무것도 달라지지 않는다 (여러 번 돌려도 된다).
--
-- ⚠️ 교환권 수는 「나다움 합계 ÷ 한 장 값」으로 그때그때 계산한다. 그래서 값을 올리면
--   나다움이 150~199N 인 청소년은 교환권 1장이 0장으로 줄어든다 (전에 이미 쓴 교환권은 그대로 쓴 것으로 센다).
--   맨 아래 확인에서 몇 명의 「쓸 수 있는 교환권」이 줄어드는지 먼저 보여 준다.
--   손해 보는 분이 있으면 알려 달라 — 관리자 「나다움 지급」으로 모자란 만큼 채워 줄 수 있다.

UPDATE dokseo_settings SET points_per_voucher = 200 WHERE id = 1;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 한 장 값 200 / 교환권이 줄어드는 사람(0이면 아무도 손해 없음)
SELECT (SELECT points_per_voucher FROM dokseo_settings WHERE id = 1) AS 한장_200이어야,
       count(*) FILTER (WHERE GREATEST(0, pts / 150 - used) > GREATEST(0, pts / 200 - used)) AS 교환권_줄어드는_사람,
       count(*) FILTER (WHERE GREATEST(0, pts / 150 - used) < GREATEST(0, pts / 200 - used)) AS 늘어나는_사람_0이어야
  FROM (
    SELECT (dokseo_points(p.id) ->> 'points')::int AS pts,
           (dokseo_points(p.id) ->> 'used')::int   AS used
      FROM profiles p
     WHERE p.withdrawn_at IS NULL AND COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
  ) t;
