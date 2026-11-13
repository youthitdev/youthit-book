-- 한끗독서 마이그레이션 168
-- 기존 후기는 30N 그대로 유지 (2026-11-13 사용자: 「기존에 30N 받은 사람은 그대로 두고 앞으로만 20N」)
--
-- 【배경】 166에서 후기 기준을 20N으로 바꿨는데, 나다움은 기록을 합산해 그때그때 계산하므로
--   이미 쓴 후기도 20N으로 계산되어 6명이 10N씩 줄었다. 그 10N을 「나다움 지급」으로 되돌려 준다.
--
-- 【하는 일】 2026-11-13 00:00(한국시간) 이전에 쓴 후기 1개당 +10N 을 지급 내역(nadaum_grants)에 넣는다.
--   · 사람별로 한 번만 넣는다 (같은 사유가 이미 있으면 건너뜀) → 여러 번 돌려도 중복 지급되지 않는다.
--   · 그 이후 쓰는 후기는 20N 그대로다.
--   · 알림은 가지 않는다. 나다움 내역에는 사유와 함께 보인다.
-- 되돌리려면: 관리자 「나다움 지급」 내역에서 해당 줄 「회수」 (또는 void_nadaum).

INSERT INTO nadaum_grants (user_id, amount, reason, granted_by)
SELECT r.user_id, count(*) * 10, '후기 30N 유지 (기준 변경 전에 쓴 후기)', NULL
  FROM reviews r
  JOIN profiles p ON p.id = r.user_id
 WHERE r.created_at < timestamp '2026-11-13 00:00:00' AT TIME ZONE 'Asia/Seoul'
   AND p.withdrawn_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM nadaum_grants g
                    WHERE g.user_id = r.user_id AND g.reason = '후기 30N 유지 (기준 변경 전에 쓴 후기)')
 GROUP BY r.user_id;

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 지급받은_사람 6 / 지급_합계_N 60
SELECT count(*) AS 지급받은_사람_6이어야, COALESCE(sum(amount), 0) AS 지급_합계_N_60이어야
  FROM nadaum_grants
 WHERE reason = '후기 30N 유지 (기준 변경 전에 쓴 후기)' AND voided_at IS NULL;
