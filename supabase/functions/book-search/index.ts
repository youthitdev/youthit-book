// 한끗독서 책 검색 — 카카오 책 검색 API 앞의 얇은 문지기.
// 호출: POST { q: "속초에서의 겨울" }  →  { books: [{title, authors, publisher, isbn}] }
//
// 【왜 굳이 함수를 하나 더 두나】
//   카카오 REST 키를 app.html 에서 직접 부르면 키가 화면 소스에 그대로 드러난다.
//   키는 여기에만 두고, 앱은 이 함수만 부른다.
//
// 【왜 로그인을 요구하나】
//   publishable 키는 app.html 에 적혀 있다. 그것만으로 열어두면 아무나
//   우리 카카오 할당량을 쓸 수 있다. 실제 로그인한 사람만 통과시킨다.
import { createClient } from "npm:@supabase/supabase-js@2";

const KAKAO = "https://dapi.kakao.com/v3/search/book";

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

// 카카오는 isbn 을 "8937460445 9788937460449" 처럼 옛것·새것을 붙여서 준다.
// 집계에 쓸 건 13자리 하나면 된다
const pickIsbn = (raw: string): string | null => {
  const parts = String(raw || "").split(/\s+/).filter(Boolean);
  return parts.find((p) => p.length === 13) ?? parts[0] ?? null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST만 지원해요" });

  const key = Deno.env.get("KAKAO_REST_KEY");
  // 키를 아직 안 넣었어도 앱이 멈추면 안 된다. 빈 목록으로 조용히 돌려보낸다
  if (!key) return json(200, { books: [], note: "KAKAO_REST_KEY 미설정" });

  const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
  if (authErr || !user) return json(403, { error: "로그인이 필요해요" });

  let b: { q?: string };
  try { b = await req.json(); } catch { return json(400, { error: "JSON 본문이 필요해요" }); }

  const q = (b.q ?? "").trim();
  if (q.length < 2) return json(200, { books: [] });

  const url = `${KAKAO}?query=${encodeURIComponent(q)}&size=8&sort=accuracy`;
  let res: Response;
  try {
    res = await fetch(url, { headers: { Authorization: `KakaoAK ${key}` } });
  } catch {
    // 카카오가 죽어도 인증·신청은 되어야 한다
    return json(200, { books: [], note: "검색 서버에 닿지 못했어요" });
  }
  if (!res.ok) return json(200, { books: [], note: `카카오 ${res.status}` });

  const data = await res.json();
  // thumbnail · year 는 고를 때만 쓴다. 저장하지 않는다 — 책장에 남는 표지는
  // 아이가 직접 찍은 사진이다. 「데미안」 네 판본 같은 걸 가르는 데만 필요하다
  const books = (data.documents ?? []).map((d: Record<string, unknown>) => ({
    title:     String(d.title ?? "").trim(),
    authors:   (d.authors as string[] ?? []).join(", "),
    publisher: String(d.publisher ?? "").trim(),
    isbn:      pickIsbn(String(d.isbn ?? "")),
    thumbnail: String(d.thumbnail ?? "") || null,
    year:      String(d.datetime ?? "").slice(0, 4) || null,
  })).filter((x: { title: string }) => x.title);

  return json(200, { books });
});
