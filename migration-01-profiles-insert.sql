-- 한끗독서 마이그레이션 01
-- profiles 에 INSERT 정책 추가
--
-- 가입 시 프로필은 handle_new_user 트리거가 만들지만, 그 트리거는 실패해도
-- 가입 자체를 막지 않도록 예외를 삼키게 해뒀다(한끗루틴에서 같은 트리거가
-- 500 에러를 내 가입이 통째로 막힌 적이 있어서). 그래서 트리거가 실패한
-- 경우 앱이 프로필을 직접 만들어야 하는데, INSERT 정책이 없으면 RLS에 막힌다.

DROP POLICY IF EXISTS profiles_self_insert ON profiles;
CREATE POLICY profiles_self_insert ON profiles FOR INSERT WITH CHECK (id = auth.uid());
