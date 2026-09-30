-- 한끗독서 마이그레이션 63
-- 도서기금 비율을 80% → 30%
--
-- 후원금은 책값으로만 쓰지 않는다. 습관을 만드는 일 — 끗짱 활동, 공유회,
-- 운영 — 에 70%, 아이들 책값에 30% 를 쓰기로 했다 (2026-09-30 사용자).
--
--   후원 100만원  →  도서기금 30만원  +  운영비 70만원
--
-- ⚠️ 이미 들어온 후원은 **그때 비율로 굳어 있다.** 이 값은 앞으로 넣을
--   후원에만 적용된다 (split_charge_amounts 가 넣을 때 한 번 가른다).
--   지금은 후원이 한 건도 없으니 소급 걱정이 없다.

UPDATE dokseo_settings SET book_fund_rate = 0.300 WHERE id = 1;

SELECT book_fund_rate                        AS 도서기금비율,
       ROUND((1 - book_fund_rate) * 100)     AS 운영비_퍼센트,
       1000000 * book_fund_rate              AS 백만원이면_책값,
       1000000 * (1 - book_fund_rate)        AS 백만원이면_운영비,
       (SELECT count(*) FROM charges)        AS 이미들어온_후원
  FROM dokseo_settings WHERE id = 1;
