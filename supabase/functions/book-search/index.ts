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
const KAKAO = "https://dapi.kakao.com/v3/search/book";

// 【왜 supabase-js 를 안 쓰나】
//   예전에는 service_role 키로 getUser(token) 을 불러 확인했다. 그런데 프로젝트가
//   새 API 키(sb_publishable_…)로 옮겨가면서 옛 service_role 키가 막히자,
//   로그인한 사람까지 전부 403 이 됐다. 검색이 통째로 멈췄다.
//
//   서명 검사는 게이트웨이가 이미 한다(verify_jwt). 여기서 가릴 것은
//   「사람의 토큰인가, 그냥 공개 키인가」뿐이다. 공개 키는 JWT 가 아니라
//   아래 해독에서 걸린다. 키가 또 바뀌어도 이 문은 안 닫힌다.
const isUser = (req: Request): boolean => {
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const part = jwt.split(".")[1];
  if (!part) return false;
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/");
    const p = JSON.parse(atob(b64 + "=".repeat((4 - b64.length % 4) % 4)));
    return p.role === "authenticated" && !!p.sub;
  } catch { return false; }
};

// 책방 사장님은 회원이 아니라 책방 열쇠로 들어온다 (store.html). 「이 열쇠가 맞는 책방인가」를 DB 에 물어 통과시킨다.
// 호출한 쪽이 보낸 공개 키(apikey)를 그대로 써서 묻는다 — 이 함수에 따로 비밀 키를 두지 않는다
const storeKeyOk = async (req: Request, key: unknown): Promise<boolean> => {
  const k = typeof key === "string" ? key : "";
  const apikey = req.headers.get("apikey") ?? "";
  const base = Deno.env.get("SUPABASE_URL") ?? "";
  if (!k || k.length > 200 || !apikey || !base) return false;
  try {
    const r = await fetch(`${base}/rest/v1/rpc/store_key_ok`, {
      method: "POST",
      headers: { apikey, Authorization: `Bearer ${apikey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_key: k }),
    });
    return r.ok && (await r.json()) === true;
  } catch { return false; }
};

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

  let b: { q?: string; store_key?: string };
  try { b = await req.json(); } catch { return json(400, { error: "JSON 본문이 필요해요" }); }

  // 로그인한 회원이거나, 맞는 책방 열쇠를 가진 사장님만
  if (!isUser(req) && !(await storeKeyOk(req, b.store_key))) return json(403, { error: "로그인이 필요해요" });

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
