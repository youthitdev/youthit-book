-- 한끗독서 마이그레이션 156
-- 책 교환 인증은 「청소년이 올리지 않고, 후기 탭에도 안 보이는」 기록 보관용으로 (2026-11-05 사용자 결정)
--
-- 【바뀌는 것】 154 에서 연 길을 닫는다. 책방이 올린 교환 인증 사진은 다시 운영진만 읽는다.
--   · 로그인한 사람이 책방 사진을 읽게 한 저장소 정책을 지운다 (영수증과 같은 비공개 저장소다)
--   · 후기 탭에 쓰던 피드 함수(exchange_feed)를 지운다 — 앱에서 부르지 않는다
--   · 청소년이 남긴 옛 사진·글은 표에 그대로 있다. 지우지 않고 앱에서만 안 보인다.
--   · exchange_hidden 칸은 남겨 둔다(쓰지 않는다).
--
-- ⚠️ 154 를 이미 돌렸다면 꼭 돌린다. 여러 번 돌려도 된다.

DROP POLICY IF EXISTS store_proofs_exchange_read ON storage.objects;
DROP FUNCTION IF EXISTS is_exchange_photo(text);
DROP FUNCTION IF EXISTS exchange_feed(int);

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 셋 다 0
SELECT (SELECT count(*) FROM pg_policies WHERE policyname = 'store_proofs_exchange_read') AS 정책_0이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'is_exchange_photo')                 AS 사진함수_0이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'exchange_feed')                     AS 피드함수_0이어야;
