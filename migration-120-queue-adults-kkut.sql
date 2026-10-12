-- 한끗독서 마이그레이션 120
-- 청소년으로 가입했지만 어른인 사람을 「끗짱 승인 대기」로 옮긴다
--
-- 【왜】 청소년 가입이 만 20세까지로 바뀌었다 (2026-10-12). 그 전에 청소년으로 가입한 어른(만 21세 이상)이
--   「청소년 확인」 명단에 섞여 있다. 어른은 청소년 확인 대상이 아니고, 끗짱이 되는 길로 안내해야 한다.
--   바로 끗짱으로 세우지 않는다 — 신청 폼(구글폼)으로 한 번 확인한 뒤 「끗짱 승인」에서 승인한다 (2026-10-11 결정).
--
-- 【하는 일】 고른 사람마다 「끗짱 신청서」를 **대기(pending)** 로 만든다. 그러면
--   · 「청소년 확인」 명단에서 빠지고 「끗짱 승인」의 심사 대기에 보인다 (admin.html 의 vqPool 이 신청서 유무로 가른다).
--   · 승인하기 전에는 권한이 생기지 않는다 (can_lead·role 은 그대로).
--   · 이미 신청서가 있는 사람은 건드리지 않는다.
--   · 신청서는 운영진이 대신 만든 것이라 경험·약속 칸은 비어 있다 (「이전에 낸 신청서예요」로 보인다).
--
-- ⚠️ 78·79·103 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION admin_queue_kkut(p_users uuid[]) RETURNS int AS $$
DECLARE u uuid; v_n int := 0; v_age int; v_region text; v_contact text; v_aff text; v_rows int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '운영진만 할 수 있어요'; END IF;

  FOREACH u IN ARRAY COALESCE(p_users, '{}') LOOP
    -- 운영진 본인은 옮기지 않는다
    IF EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = u) THEN CONTINUE; END IF;

    SELECT COALESCE(age_years(pp.birth_date), 0), NULLIF(btrim(p.region), ''),
           NULLIF(btrim(pp.phone), ''), NULLIF(btrim(p.school_status), '')
      INTO v_age, v_region, v_contact, v_aff
      FROM profiles p LEFT JOIN profiles_private pp ON pp.id = p.id
     WHERE p.id = u;
    IF NOT FOUND THEN CONTINUE; END IF;

    INSERT INTO kkut_applications
      (user_id, age, affiliation, region, contact, intro, motive, status, applied_at)
    VALUES
      (u, GREATEST(v_age, 14),
       COALESCE(v_aff, '없음'), COALESCE(v_region, '미상'),
       COALESCE(v_contact, '운영진이 따로 확인'),
       '청소년으로 가입한 어른이라 운영진이 끗짱 승인 대기로 옮겼어요. 신청 폼 확인 전이에요.',
       '운영진이 옮겼어요',
       'pending', now())
    ON CONFLICT (user_id) DO NOTHING;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_n := v_n + v_rows;
  END LOOP;
  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_queue_kkut(uuid[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_queue_kkut(uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무도 옮기지 않는다. 기대: 함수 1
SELECT count(*) AS 함수_1이어야 FROM pg_proc WHERE proname = 'admin_queue_kkut';
