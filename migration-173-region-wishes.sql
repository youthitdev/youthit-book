-- 한끗독서 마이그레이션 173
-- 교환하러 갈 만한 동네 (최대 3곳) — 「N명의 청소년이 기다리고 있어요」 숫자에 합쳐 센다 (2026-11-13 사용자, 2단계)
--
-- 【하는 일】
--   1. region_wishes 표: 청소년이 고른 「교환하러 갈 만한 동네」. 본인 것만 읽는다. 쓰기는 아래 함수로만 한다.
--   2. set_region_wishes(동네 목록) — 내 목록을 통째로 바꾼다. 최대 3곳, 「시·도 시·군·구」 모양만 받고 같은 동네는 한 번만.
--   3. region_waiting(지역) — 172 의 함수를 고쳐서, 「그 시·군·구에 살거나, 그 동네를 가고 싶다고 고른」 청소년을 센다.
--      같은 사람은 한 번만 센다 (여러 곳을 골라도 동네마다 1명). 청소년 회원만, 끗짱·어른·탈퇴한 회원은 뺀다.
-- 되돌리려면: 172 의 region_waiting 정의를 다시 돌리고, DROP FUNCTION set_region_wishes(text[]); DROP TABLE region_wishes;
-- ⚠️ 172 뒤에 돌린다. 여러 번 돌려도 된다.

-- 「서산시」·「서산」처럼 끝의 시·군·구 글자만 다른 표기를 같게 맞춘다
CREATE OR REPLACE FUNCTION rg_norm(r text) RETURNS text AS $$
  SELECT regexp_replace(regexp_replace(btrim(COALESCE(r, '')), '\s+', ' ', 'g'), '(시|군|구)$', '')
$$ LANGUAGE sql IMMUTABLE;

CREATE TABLE IF NOT EXISTS region_wishes (
  user_id    uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  region     text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, region)
);
ALTER TABLE region_wishes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS region_wishes_own_read ON region_wishes;
CREATE POLICY region_wishes_own_read ON region_wishes FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION set_region_wishes(p_regions text[]) RETURNS jsonb AS $$
DECLARE v_u uuid := auth.uid(); v_list text[]; r text;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  -- 공백 정리 · 빈 값 빼기 · 같은 동네는 한 번만
  SELECT COALESCE(array_agg(DISTINCT x), '{}') INTO v_list
    FROM (SELECT regexp_replace(btrim(v), '\s+', ' ', 'g') AS x FROM unnest(COALESCE(p_regions, '{}')) v) t
   WHERE x <> '';
  IF cardinality(v_list) > 3 THEN RAISE EXCEPTION '교환하러 갈 동네는 최대 3곳까지 고를 수 있어요'; END IF;
  FOREACH r IN ARRAY v_list LOOP
    IF char_length(r) > 30 OR r !~ '^\S+ \S+' THEN RAISE EXCEPTION '동네는 「시·도 시·군·구」로 골라 주세요'; END IF;
  END LOOP;

  DELETE FROM region_wishes WHERE user_id = v_u AND NOT (region = ANY (v_list));
  INSERT INTO region_wishes (user_id, region)
    SELECT v_u, x FROM unnest(v_list) x ON CONFLICT DO NOTHING;
  RETURN jsonb_build_object('ok', true, 'regions', to_jsonb(v_list));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION set_region_wishes(text[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION set_region_wishes(text[]) TO authenticated;

CREATE OR REPLACE FUNCTION region_waiting(p_region text) RETURNS int AS $$
  SELECT count(*)::int
    FROM profiles p
   WHERE NULLIF(btrim(COALESCE(p_region, '')), '') IS NOT NULL
     AND p.withdrawn_at IS NULL
     AND COALESCE(p.role, 'youth') = 'youth'
     AND NOT COALESCE(p.can_lead, false)
     AND ( rg_norm(p.region) = rg_norm(p_region)
        OR EXISTS (SELECT 1 FROM region_wishes w
                    WHERE w.user_id = p.id AND rg_norm(w.region) = rg_norm(p_region)) )
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION region_waiting(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION region_waiting(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 표 1 / 함수 둘(set_region_wishes · rg_norm) 2 / 강동구 숫자(172 때와 같거나 더 큼)
SELECT (SELECT count(*) FROM pg_tables WHERE tablename = 'region_wishes')                              AS 표_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname IN ('set_region_wishes', 'rg_norm'))                AS 함수_2여야,
       region_waiting('서울 강동구')                                                                    AS 서울_강동구_청소년수;
