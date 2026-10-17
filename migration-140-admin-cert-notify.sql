-- 한끗독서 마이그레이션 140
-- 운영진(관리자 계정)도 루틴에 인증이 올라오면 알림을 받는다 (2026-10-17 사용자)
--
-- 【왜】 운영진은 어느 루틴의 참여자도 끗짱도 아니라서, 아이들이 인증을 올려도 알림이 오지 않았다.
--   앱을 열어 보기 전에는 인증이 올라오는 걸 알 수 없었다.
--
-- 【무엇을】 116 판의 on_cert_to_lead() 에 운영진(admin_user_ids())을 받는 사람으로 더한다.
--   · 운영진은 여러 루틴을 보므로, 알림 내용 앞에 **루틴 이름**을 붙인다 (참여자·끗짱에게는 지금처럼 책 이름만).
--   · 눌러서 들어가면 그 인증이 열린다. 앱의 「운영진 보기」(읽기만)가 이 길을 받아 준다.
--   · 알림 종류는 그대로 'friends' 다 — 앱의 알림 설정에서 「친구들 소식」을 끄면 운영진도 끌 수 있다.
--   · 운영진이 직접 올린 인증이면 자기에게는 보내지 않는다. 운영진이 그 루틴의 참여자·끗짱이면 한 번만 간다 (UNION).
--
-- 【그대로인 것】 참여자·끗짱에게 가는 알림, 인증이 알림 때문에 안 올라가는 일이 없게 하는 EXCEPTION 은 116 판과 같다.
--
-- ⚠️ 78(admin_user_ids)·108·116 뒤에 돌린다. 여러 번 돌려도 된다 (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION on_cert_to_lead() RETURNS trigger AS $$
DECLARE v_title text; v_lead uuid; v_who text; v_book text; v_body text; u uuid;
BEGIN
  SELECT r.title, r.led_by INTO v_title, v_lead FROM routines r WHERE r.id = NEW.routine_id;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  -- 누가 했는지는 제목에, 책은 내용에 (알림을 누르면 그 인증이 열린다)
  v_book := COALESCE('『' || NULLIF(left(btrim(NEW.book_title), 40), '') || '』', '');

  -- 끗짱 + 승인된 참여자 + 운영진. 올린 사람은 뺀다. UNION 이 겹침도 걷어 준다
  FOR u IN
    SELECT x FROM (
      SELECT v_lead AS x
      UNION
      SELECT rp.user_id FROM routine_participants rp
       WHERE rp.routine_id = NEW.routine_id AND rp.status = 'approved'
      UNION
      SELECT a FROM public.admin_user_ids() a
    ) t
    WHERE x IS NOT NULL AND x <> NEW.user_id
  LOOP
    -- 운영진에게만 루틴 이름을 붙인다. 여러 루틴의 인증이 한꺼번에 오기 때문이다
    IF EXISTS (SELECT 1 FROM public.admin_user_ids() a WHERE a = u) AND u IS DISTINCT FROM v_lead
       AND NOT EXISTS (SELECT 1 FROM routine_participants rp
                        WHERE rp.routine_id = NEW.routine_id AND rp.user_id = u AND rp.status = 'approved') THEN
      v_body := COALESCE(v_title, '루틴') || CASE WHEN v_book <> '' THEN ' · ' || v_book ELSE '' END;
    ELSE
      v_body := v_book;
    END IF;
    PERFORM notify_push(u, COALESCE(v_who, '친구') || '님이 인증했어요 📖', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id || '&cert=' || NEW.id, 'friends');
  END LOOP;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;   -- 117 처럼: 함수 안의 표·함수를 못 찾는 일을 막는다

-- 트리거는 104 에서 이미 걸려 있다 (함수만 바뀐다). 혹시 없으면 다시 건다
DROP TRIGGER IF EXISTS certs_lead_notify ON certifications;
CREATE TRIGGER certs_lead_notify AFTER INSERT ON certifications
  FOR EACH ROW EXECUTE FUNCTION on_cert_to_lead();

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 새 판 1 (운영진을 받는 사람으로 더한 판) · 운영진 계정 수 (보통 1~2)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'on_cert_to_lead' AND prosrc LIKE '%admin_user_ids%') AS 새판_1이어야,
       (SELECT count(*) FROM public.admin_user_ids())                                                   AS 운영진_계정수;
