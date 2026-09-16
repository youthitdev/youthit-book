-- 한끗독서 마이그레이션 27
-- 가입할 때 받은 사는 곳을 프로필에 옮긴다
--
-- 【배경】 지역을 가입 화면에서 필수로 받기로 했다. 앱은 signUp 의
--   raw_user_meta_data 에 region 을 실어 보내는데, handle_new_user() 가
--   name·role 만 꺼내 쓰고 있어 지역이 버려졌다.
--
-- 【형식】 '서울 성북구' — 앞은 시·도, 뒤는 시·군·구. bookstores.region 과
--   같은 모양이어야 '내 근처' 판정이 맞는다. 앱이 시·도를 드롭다운으로 받아
--   이 형식을 지킨다.

CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger AS $$
BEGIN
  BEGIN
    INSERT INTO profiles (id, name, role, region)
    VALUES (NEW.id,
            COALESCE(NEW.raw_user_meta_data->>'name', '이름없음'),
            COALESCE(NEW.raw_user_meta_data->>'role', 'youth'),
            NULLIF(btrim(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''))
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    -- 이 트리거가 실패해도 가입은 막지 않는다 (한끗루틴에서 500 으로 가입이
    -- 통째로 막혔던 적이 있다). 실패하면 앱이 프로필을 직접 만든다
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
