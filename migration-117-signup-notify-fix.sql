-- 한끗독서 마이그레이션 117
-- 가입 알림이 운영진에게 안 가던 문제 — 가입 때의 「검색 경로」를 못박고, 실패하면 기록을 남긴다
--
-- 【증상】 청소년이 가입해도 운영진 알림함에 「새 청소년이 가입했어요」가 없다 (2026-10-11).
--   방아쇠도 켜져 있고 함수도 최신이고, 같은 알림을 손으로 보내면 잘 간다.
--
-- 【원인으로 보는 것】 가입은 로그인 시스템(auth)이 처리한다. 그 환경은 기본 검색 경로가 public 이 아니어서
--   함수 안의 `notifications`·`admin_user_ids()` 를 못 찾을 수 있다. 가입 알림 함수는 오류를 삼키게 만들어 둬서
--   (알림 때문에 가입이 막히면 안 되므로) 조용히 실패한다.
--
-- 【고침】 가입 알림에 쓰이는 세 함수의 검색 경로를 못박는다. 그리고 실패하면 notify_errors 에 이유를 남긴다 —
--   그래도 안 오면 그 표를 보면 원인이 나온다.
--
-- ⚠️ 78·81·108 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS notify_errors (
  id         bigserial PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  fn         text,
  msg        text
);
ALTER TABLE notify_errors ENABLE ROW LEVEL SECURITY;   -- 정책이 없으니 앱에서는 못 읽는다. 운영진은 SQL 편집기로 본다

-- 검색 경로를 못박는다
ALTER FUNCTION admin_user_ids()                              SET search_path = public, auth;
ALTER FUNCTION notify_push(uuid, text, text, text, text)     SET search_path = public;

-- 가입 알림 (81 판) — 실패하면 이유를 남긴다
CREATE OR REPLACE FUNCTION on_profile_created() RETURNS trigger AS $$
DECLARE a uuid; v_who text; v_where text;
BEGIN
  IF COALESCE(NEW.role, 'youth') <> 'youth' THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.admin_user_ids() a WHERE a = NEW.id) THEN RETURN NEW; END IF;

  v_who := COALESCE(NULLIF(btrim(NEW.name), ''), '이름 없음');
  IF COALESCE(btrim(NEW.nick), '') <> '' AND NEW.nick <> NEW.name THEN
    v_who := v_who || '(' || btrim(NEW.nick) || ')';
  END IF;
  v_where := COALESCE(NULLIF(btrim(NEW.region), ''), '지역 없음');

  FOR a IN SELECT * FROM public.admin_user_ids() LOOP
    PERFORM public.notify_push(a, '새 청소년이 가입했어요 🌱',
      v_who || ' · ' || v_where || ' · 확인해 주세요',
      '/youthit-book/admin.html#verify');
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- 알림 때문에 가입이 막히면 안 된다. 대신 이유를 남긴다
  BEGIN
    INSERT INTO public.notify_errors(fn, msg) VALUES ('on_profile_created', SQLERRM);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 검색경로 설정 3 / 기록표 1
SELECT (SELECT count(*) FROM pg_proc
         WHERE proname IN ('admin_user_ids', 'notify_push', 'on_profile_created')
           AND proconfig IS NOT NULL)                                   AS 검색경로_설정_3이어야,
       (SELECT count(*) FROM pg_class WHERE relname = 'notify_errors')  AS 기록표_1이어야;
