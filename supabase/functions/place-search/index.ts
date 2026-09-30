// 한끗독서 장소 검색 — 카카오 로컬(키워드) API 앞의 얇은 문지기.
// 호출: POST { q: "속초 당신의강릉" }
//   →  { places: [{ name, road, addr, lat, lng, url, phone }] }
//
// 【왜 굳이 함수를 하나 더 두나】
//   book-search 와 같은 이유다. 카카오 REST 키를 app.html 에서 직접 부르면
//   키가 화면 소스에 그대로 드러난다. 키는 여기에만 두고, 앱은 이 함수만 부른다.
//   책과 장소는 부르는 주소가 달라(v3/search/book vs v2/local/search) 함수를 갈랐다.
//
// 【왜 로그인을 요구하나】
//   publishable 키는 app.html 에 적혀 있다. 그것만으로 열어두면 아무나
//   우리 카카오 할당량을 쓸 수 있다. 실제 로그인한 사람만 통과시킨다.
//
// 【검색이 죽어도 루틴은 만들어져야 한다】
//   장소는 손으로 적어도 된다 — 학교 도서관, 누구네 집처럼 지도에 없는 곳도 있다.
//   그래서 키가 없거나 카카오가 죽으면 빈 목록으로 조용히 돌려보낸다.
import { createClient } from "npm:@supabase/supabase-js@2";

const KAKAO = "https://dapi.kakao.com/v2/local/search/keyword.json";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// app.html 은 github.io 에서 돈다. 다른 도메인이라 CORS 헤더가 없으면 막힌다
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (status: number, data: unknown) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...cors },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST만 지원해요" });

  const key = Deno.env.get("KAKAO_REST_KEY");
  if (!key) return json(200, { places: [], note: "KAKAO_REST_KEY 미설정" });

  const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
  if (authErr || !user) return json(403, { error: "로그인이 필요해요" });

  let b: { q?: string };
  try { b = await req.json(); } catch { return json(400, { error: "JSON 본문이 필요해요" }); }

  const q = (b.q ?? "").trim();
  if (q.length < 2) return json(200, { places: [] });

  const url = `${KAKAO}?query=${encodeURIComponent(q)}&size=8`;
  let res: Response;
  try {
    res = await fetch(url, { headers: { Authorization: `KakaoAK ${key}` } });
  } catch {
    return json(200, { places: [], note: "검색 서버에 닿지 못했어요" });
  }
  if (!res.ok) return json(200, { places: [], note: `카카오 ${res.status}` });

  const data = await res.json();
  // x 가 경도, y 가 위도다. 카카오가 문자열로 주므로 숫자로 바꿔 둔다 —
  // 길찾기 주소를 만들 때 그대로 끼워 넣어야 한다
  const places = (data.documents ?? []).map((d: Record<string, unknown>) => ({
    name:  String(d.place_name ?? "").trim(),
    road:  String(d.road_address_name ?? "").trim() || null,
    addr:  String(d.address_name ?? "").trim() || null,
    lat:   Number(d.y),
    lng:   Number(d.x),
    url:   String(d.place_url ?? "") || null,
    phone: String(d.phone ?? "") || null,
  })).filter((p: { name: string; lat: number; lng: number }) =>
    p.name && Number.isFinite(p.lat) && Number.isFinite(p.lng));

  return json(200, { places });
});
