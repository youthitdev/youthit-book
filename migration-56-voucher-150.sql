-- 한끗독서 마이그레이션 56
-- 교환권 문턱을 250P → 150P
--
-- 【왜 150 인가】 인증 한 번이 10P, 루틴 한 번이 15일이다.
--   150P = **한 루틴을 끝까지 하면 책 한 권**. 셈이 딱 떨어진다.
--   전에는 250P 라, 완주해도 댓글·후기까지 채워야 겨우 닿았다
--   (인증 150 + 댓글 75 + 후기 30 = 255P). 매일 읽었는데 책을 못 받는
--   일이 생길 수 있었다.
--
-- ⚠️ 이미 쌓인 포인트에도 그대로 적용된다. 150P 를 넘겨 둔 아이는
--   이 SQL 을 돌리는 순간 교환권을 받는다 — 빼앗기는 사람은 없다.

UPDATE dokseo_settings SET points_per_voucher = 150 WHERE id = 1;

SELECT points_per_voucher AS 교환권문턱,
       points_per_cert    AS 인증1회,
       voucher_max_amount AS 책값상한
  FROM dokseo_settings WHERE id = 1;
