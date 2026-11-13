-- 한끗독서 마이그레이션 166
-- 후기 작성 나다움 20N (2026-11-13 사용자). 지금까지는 모임 후기 30N · 책 인증 후기 30N 이었다.
--
-- 【하는 일】 설정 points_per_review(모임 후기)·points_per_bookreview(책 인증 후기)를 둘 다 20 으로 바꾼다.
--   앱 화면(「후기 쓰고 +20N」)과 서버 계산식은 이 값을 읽어 쓰므로 함수는 건드리지 않는다.
--
-- ⚠️ 나다움 잔액은 기록을 합산해서 그때그때 계산한다. 그래서 **이미 쓴 후기에도 새 값이 적용된다**.
--   후기 하나당 10N 씩 줄어든다. 맨 아래 확인에서 몇 명의 나다움이 얼마나 줄고, 그 때문에 쓸 수 있는 교환권이 줄어드는 사람이 있는지 보여 준다.
--   과거에 쓴 후기는 30N 그대로 두고 앞으로 쓰는 것부터 20N 으로 하길 원하면 알려 달라 (계산식을 고쳐야 한다).
-- 되돌리려면: UPDATE dokseo_settings SET points_per_review = 30, points_per_bookreview = 30 WHERE id = 1;
-- 여러 번 돌려도 된다.

UPDATE dokseo_settings SET points_per_review = 20, points_per_bookreview = 20 WHERE id = 1;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 두 값 20 / 나다움이 줄어드는 사람·합계 / 그 때문에 교환권이 줄어드는 사람(0이면 아무도 손해 없음)
WITH x AS (
  SELECT p.id,
         (dokseo_points(p.id) ->> 'points')::int AS now_pts,
         (dokseo_points(p.id) ->> 'used')::int   AS used,
         (SELECT count(*) FROM reviews r WHERE r.user_id = p.id) AS n_rev
    FROM profiles p
   WHERE p.withdrawn_at IS NULL AND COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
), s AS (SELECT GREATEST(points_per_voucher, 1) AS per, points_per_review AS pr, points_per_bookreview AS pb FROM dokseo_settings WHERE id = 1)
SELECT (SELECT pr FROM s) AS 모임후기_20이어야,
       (SELECT pb FROM s) AS 책후기_20이어야,
       count(*) FILTER (WHERE n_rev > 0)                                                    AS 나다움_줄어드는_사람,
       COALESCE(sum(n_rev) * 10, 0)                                                         AS 줄어드는_나다움_합계_N,
       count(*) FILTER (WHERE GREATEST(0, (now_pts + n_rev * 10) / (SELECT per FROM s) - used)
                            > GREATEST(0, now_pts / (SELECT per FROM s) - used))            AS 교환권_줄어드는_사람
  FROM x;
