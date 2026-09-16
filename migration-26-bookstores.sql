-- 한끗독서 마이그레이션 26
-- 파트너 서점 등록
--
-- 【지역 표기를 맞춘다】 앱의 서점 탭은 region 으로 묶고, 아이의 '사는 곳'과
--   앞 덩어리(시·도)를 맞춰 내 동네를 맨 위로 올린다. 그래서 표기가 섞이면
--   ('서울시' vs '서울') 같은 동네인데 따로 묶인다. 이렇게 통일한다.
--       시·도는 줄여서   — 서울 / 경기 / 강원 / 전남 / 대전
--       시·군·구는 그대로 — 강릉시 / 순천시 / 수원시 / 성북구 / 용인시 / 유성구
--   먼저 들어가 있던 유스서점이 '서울 성동구' 라 그 형식을 따른다.
--
-- ⚠️ 주소가 비어 있어서 active = false 로 넣는다.
--   주소는 앱의 '길찾기' 버튼에 그대로 들어간다. 주소가 없으면 아이가
--   갈 곳을 못 찾고, 버튼도 안 나온다.
--   → 관리자 화면 [파트너 서점 → 수정] 에서 주소·영업시간을 채우고 켤 것.

INSERT INTO bookstores (name, region, active)
SELECT * FROM (VALUES
  ('당신의강릉',       '강원 강릉시', false),
  ('골목책방서성이다', '전남 순천시', false),
  ('하우스 결',        '경기 수원시', false),
  ('초록서림',         '서울 성북구', false),
  ('빈칸놀이터',       '경기 용인시', false),
  ('빈칸라운지',       '경기 용인시', false),
  ('책방채움',         '대전 유성구', false)
) AS v(name, region, active)
WHERE NOT EXISTS (SELECT 1 FROM bookstores b WHERE b.name = v.name);

-- 앞서 데모 값으로 넣었다면 지역을 바로잡고, 확인 안 된 주소는 지운다
UPDATE bookstores SET region = '강원 강릉시' WHERE name = '당신의강릉';
UPDATE bookstores SET region = '대전 유성구', address = NULL
 WHERE name = '책방채움';

-- 완벽한날들은 명단에 없어 넣지 않았다. 파트너가 맞으면 아래를 쓰면 된다
-- INSERT INTO bookstores (name, region, active) VALUES ('완벽한날들', '강원 속초시', false);

SELECT id, name, region, address, active FROM bookstores ORDER BY active DESC, region, name;
