-- ⚠️ 테스트용. 실서비스 전에 아래 '정리' 구문으로 반드시 지울 것
-- 루틴 1의 참여자에게 지난 14일치 인증을 채워 교환권 문턱(250P)을 넘긴다.
-- 인증은 하루 한 건만 가능해서 오늘 눌러서는 못 채우기 때문이다.

INSERT INTO certifications
  (routine_id, user_id, photo_urls, quote, book_title, page_end, content, cert_date, created_at)
SELECT p.routine_id,
       p.user_id,
       '{}'::text[],
       '[테스트] 오늘도 한 장 읽었다',
       '테스트 책',
       10 * g,
       '[테스트] 채워 넣은 기록',
       ((now() AT TIME ZONE 'Asia/Seoul')::date - g),
       now() - (g || ' days')::interval
  FROM routine_participants p
  CROSS JOIN generate_series(1, 14) AS g
 WHERE p.routine_id = 1 AND p.status = 'approved'
ON CONFLICT DO NOTHING;

-- 결과 확인 — 포인트와 교환권
SELECT u.email,
       count(*)                              AS 인증수,
       sum(r.points_per_cert)                AS 인증포인트,
       dokseo_points(c.user_id) ->> 'points' AS 총포인트,
       dokseo_points(c.user_id) ->> 'left'   AS 쓸수있는교환권
  FROM certifications c
  JOIN routines r   ON r.id = c.routine_id
  JOIN auth.users u ON u.id = c.user_id
 WHERE c.routine_id = 1
 GROUP BY u.email, c.user_id;
