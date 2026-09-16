-- 한끗독서 마이그레이션 26
-- 파트너 서점 등록 (완벽한날들 · 당신의강릉 · 책방채움)
--
-- ⚠️ 셋 다 active = false 로 넣는다.
--   active 인 서점은 청소년 앱 '서점' 탭에 "책 받으러 갈 곳" 으로 바로 뜬다.
--   아직 섭외가 안 된 곳이 켜져 있으면, 아이가 찾아가서 돈 없이 책을 달라고 하고
--   사장님은 영문을 모르는 일이 생긴다. 아이에게도 서점에도 나쁜 일이다.
--   → 섭외가 끝난 곳만 관리자 화면에서 하나씩 켤 것.
--
-- 전화번호는 넣지 않았다. 앱에 있던 033-000-0000 은 화면 확인용 가짜 번호였고,
-- 가짜 번호를 넣으면 아이가 실제로 걸어 본다.

INSERT INTO bookstores (name, region, address, hours, closed_days, intro, active)
SELECT * FROM (VALUES
  ('완벽한날들', '강원 속초',
   '강원특별자치도 속초시 동해대로 4344',
   '평일 11:00~19:00, 주말 11:00~18:00', '매주 월요일 휴무',
   '바다 곁에서 책을 파는 동네책방이에요.', false),
  ('당신의강릉', '강원 강릉',
   '강원특별자치도 강릉시 경강로 2024',
   '12:00~20:00', '매주 화요일 휴무',
   NULL, false),
  ('책방채움', '대전',
   '대전광역시 중구 대종로 480',
   '11:00~19:00', NULL,
   NULL, false)
) AS v(name, region, address, hours, closed_days, intro, active)
WHERE NOT EXISTS (SELECT 1 FROM bookstores b WHERE b.name = v.name);

-- 확인
SELECT id, name, region, active FROM bookstores ORDER BY active DESC, name;
