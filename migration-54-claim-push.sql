-- 한끗독서 마이그레이션 54
-- 이 기기의 구독을 지금 로그인한 사람 것으로 넘겨받는다
--
-- 【무엇이 틀어졌나】
--   구독(push_subscriptions)은 **기기**에 붙고, 알림함(notifications)은 **계정**에 붙는다.
--   한 기기에서 계정을 바꿔 로그인하면 구독 줄은 앞사람 것으로 남는다. 그러면
--     · 배너는 이 기기로 온다 (앞사람에게 보낸 알림이다)
--     · 그런데 지금 사람의 알림함은 비어 있다
--   화면은 「켜져 있어요」라고 말한다 — pushState() 가 브라우저 구독만 보기 때문이다.
--
-- 【왜 앱에서 못 고치나】
--   ps_update 정책이 USING (user_id = auth.uid()) 라, upsert 의 ON CONFLICT DO UPDATE 가
--   앞사람 줄에 막힌다. 「알림 켜기」를 다시 눌러도 저장에 실패한다.
--
-- 【안전한가】
--   endpoint 는 브라우저가 발급하는 긴 난수 주소다. 그 값을 가졌다는 건 그 기기에서
--   구독을 만들었다는 뜻이다. 표는 RLS 로 가려져 있어 남의 endpoint 를 알아낼 길이 없다.
--   최악의 경우도 「내 알림이 남의 기기로 간다」이지, 남의 정보가 새지는 않는다.

CREATE OR REPLACE FUNCTION claim_push(p_endpoint text, p_p256dh text, p_auth text)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF COALESCE(btrim(p_endpoint), '') = '' THEN RETURN; END IF;

  INSERT INTO push_subscriptions(user_id, endpoint, p256dh, auth)
  VALUES (auth.uid(), p_endpoint, p_p256dh, p_auth)
  ON CONFLICT (endpoint) DO UPDATE
    SET user_id = auth.uid(),
        p256dh  = EXCLUDED.p256dh,
        auth    = EXCLUDED.auth;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION claim_push(text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION claim_push(text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT p.proname AS 함수, pg_get_function_identity_arguments(p.oid) AS 인자,
       p.prosecdef AS 정의자권한
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'claim_push';
