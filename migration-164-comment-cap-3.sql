-- 한끗독서 마이그레이션 164
-- 댓글 나다움은 하루 3개까지 (2026-11-12 사용자). 지금까지는 5개였다.
--
-- 【하는 일】 설정 comment_daily_cap 을 3 으로 바꾼다. 앱·서버 계산식은 이 값을 읽어 쓰므로 함수는 건드리지 않는다.
--   · 「하루」는 한국 시간 기준 하루, 모임 안 인증 글에 단 댓글(답글 제외)만 센다 — 지금 규칙 그대로.
--
-- ⚠️ 나다움 잔액은 기록을 합산해서 그때그때 계산한다. 그래서 **과거 날짜에도 새 상한이 적용된다**.
--   하루에 댓글을 4~5개 단 날이 있는 청소년은 그 날의 1~2N이 빠진다. 맨 아래 확인에서 몇 명·몇 N이 줄어드는지 보여 준다.
--   과거는 그대로 두고 오늘부터만 적용하길 원하면 알려 달라 (계산식을 고쳐야 한다).
-- 되돌리려면: UPDATE dokseo_settings SET comment_daily_cap = 5 WHERE id = 1;
-- 여러 번 돌려도 된다.

UPDATE dokseo_settings SET comment_daily_cap = 3 WHERE id = 1;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 상한 3 / 줄어드는 사람·나다움(0이면 아무도 손해 없음)
SELECT (SELECT comment_daily_cap FROM dokseo_settings WHERE id = 1) AS 상한_3이어야,
       count(DISTINCT user_id)                                       AS 줄어드는_사람,
       COALESCE(sum(n - 3), 0)                                       AS 줄어드는_나다움_N
  FROM (
    SELECT m.user_id, count(*) AS n
      FROM cert_comments m JOIN certifications c ON c.id = m.cert_id
     WHERE c.user_id <> m.user_id AND m.parent_id IS NULL
     GROUP BY m.user_id, (m.created_at AT TIME ZONE 'Asia/Seoul')::date
    HAVING count(*) > 3
  ) t;
