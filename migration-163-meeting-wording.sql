-- 한끗독서 마이그레이션 163
-- 「루틴」→「모임」 문구 통일 — 알림·오류 안내 문구 (2026-11-12 사용자: 「커뮤니티가 핵심이라 모임으로 통일」)
--
-- 【배경】 화면 문구(app·admin·끗짱 안내·홈페이지)는 코드에서 이미 「모임」으로 바꿨다.
--   그런데 푸시 알림과 오류 안내처럼 **DB 함수 안에 적힌 문구**는 코드로 못 바꾼다 (예: 「이번 루틴은 열리지 못했어요」,
--   「모집이 끝난 루틴이에요」). 그 문구들도 같이 바꾼다.
--
-- 【하는 일】 public 스키마 함수 중 본문에 「루틴」이 들어 있는 것을 찾아 「모임」으로 바꿔서 다시 만든다.
--   · 「한끗루틴」(다른 서비스 이름)은 건드리지 않는다.
--   · 함수의 권한·옵션(SECURITY DEFINER 등)은 그대로 유지된다 (CREATE OR REPLACE).
--   · 이미 보낸 알림, 청소년·끗짱이 직접 쓴 글(모임 이름·소개·후기)은 건드리지 않는다.
--
-- ⚠️ 여러 번 돌려도 된다 (두 번째부터는 바꿀 게 없다). 162 뒤에 돌린다.

DO $$
DECLARE
  f record;
  d text;
  n int := 0;
BEGIN
  FOR f IN
    SELECT p.oid
      FROM pg_proc p
      JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.prokind = 'f'
       AND replace(p.prosrc, '한끗루틴', '') LIKE '%루틴%'
  LOOP
    d := pg_get_functiondef(f.oid);
    d := replace(replace(replace(d, '한끗루틴', '@@HK@@'), '루틴', '모임'), '@@HK@@', '한끗루틴');
    EXECUTE d;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '모임으로 바꾼 함수: %개', n;
END $$;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 남은 함수 0 / 자동 폐강 알림에 새 문구 1 / 폐강 함수의 알림 문구 1
SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
         WHERE ns.nspname = 'public' AND p.prokind = 'f'
           AND replace(p.prosrc, '한끗루틴', '') LIKE '%루틴%')                                     AS 남은_함수_0이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'sync_routine_status'
           AND prosrc LIKE '%모임이 열리지 못했어요%')                                              AS 자동폐강_문구_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'admin_cancel_routine'
           AND prosrc LIKE '%이번 모임은 열리지 못했어요%')                                         AS 폐강_문구_1이어야;
