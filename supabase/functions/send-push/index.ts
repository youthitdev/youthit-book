// 한끗독서 웹푸시 발송.
// 호출: POST { user_id | user_ids | target:'all' | target:'routine'+routine_id,
//              title, body?, url?, from_db? }
// 권한: service_role 키 또는 관리자 계정 JWT 만.
//   anon 키는 app.html 에 그대로 적혀 있다. 그걸로 발송을 허용하면
//   누구나 아무에게나 푸시를 보낼 수 있다.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const ADMINS = ["dev@youthvoice.or.kr", "yv@youthvoice.or.kr"];
const HOME = "/youthit-book/app.html";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:yv@youthvoice.or.kr",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

// admin.html 은 github.io 에서 돈다. 다른 도메인이라 CORS 헤더가 없으면
// 브라우저가 요청 자체를 막는다
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (status: number, data: unknown) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...cors },
  });

// 문자열 비교는 옛 JWT 키만 잡힌다. 새 sb_secret 키는 실제로 관리자 API 가
// 열리는지 찔러 봐야 안다
async function isServiceKey(token: string): Promise<boolean> {
  if (!token) return false;
  if (token === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return true;
  try {
    const probe = createClient(Deno.env.get("SUPABASE_URL")!, token);
    const { error } = await probe.auth.admin.listUsers({ page: 1, perPage: 1 });
    return !error;
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST만 지원해요" });

  const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  if (!(await isServiceKey(token))) {
    const { data: { user }, error } = await supabase.auth.getUser(token);
    if (error || !user || !ADMINS.includes(user.email ?? "")) {
      return json(403, { error: "관리자만 발송할 수 있어요" });
    }
  }

  let b: {
    user_id?: string; user_ids?: string[]; target?: "all" | "routine"; routine_id?: number;
    title?: string; body?: string; url?: string; from_db?: boolean;
  };
  try { b = await req.json(); } catch { return json(400, { error: "JSON 본문이 필요해요" }); }
  if (!b.title) return json(400, { error: "title은 필수예요" });

  const cols = "id,user_id,endpoint,p256dh,auth";
  let subs: { id: number; user_id: string; endpoint: string; p256dh: string; auth: string }[] | null = null;
  let subErr: { message: string } | null = null;

  if (b.target === "all") {
    ({ data: subs, error: subErr } = await supabase.from("push_subscriptions").select(cols));
  } else if (b.target === "routine") {
    if (!b.routine_id) return json(400, { error: "routine_id가 필요해요" });
    const { data: approved, error: rpErr } = await supabase
      .from("routine_participants").select("user_id")
      .eq("routine_id", b.routine_id).eq("status", "approved");
    if (rpErr) return json(500, { error: rpErr.message });
    const ids = (approved ?? []).map((p) => p.user_id);
    ({ data: subs, error: subErr } = ids.length
      ? await supabase.from("push_subscriptions").select(cols).in("user_id", ids)
      : { data: [], error: null });
  } else {
    const targets = b.user_ids ?? (b.user_id ? [b.user_id] : null);
    if (!targets?.length) return json(400, { error: "user_id·user_ids 또는 target이 필요해요" });
    ({ data: subs, error: subErr } = await supabase.from("push_subscriptions").select(cols).in("user_id", targets));
  }
  if (subErr) return json(500, { error: subErr.message });

  // 배너는 그 순간 못 보면 사라진다. 앱 안 알림함에도 남긴다.
  // 단 notify_push() 가 부른 거면 DB 가 이미 넣었다 (from_db) — 두 번 쌓이면 안 된다.
  // 한 사람이 폰·노트북 두 대면 구독도 두 줄이라 user_id 로 접는다
  if (!b.from_db) {
    const uniq = [...new Set((subs ?? []).map((s) => s.user_id))];
    if (uniq.length) {
      await supabase.from("notifications").insert(uniq.map((uid) => ({
        user_id: uid, title: b.title, body: b.body ?? "", link: b.url ?? HOME,
      })));
    }
  }

  const payload = JSON.stringify({ title: b.title, body: b.body ?? "", url: b.url ?? HOME });

  let sent = 0, removed = 0, failed = 0;
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload);
      sent++;
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode;
      // 410 Gone / 404: 구독이 끊겼다 (앱을 지웠거나 알림을 껐다) → 치운다
      if (status === 404 || status === 410) {
        await supabase.from("push_subscriptions").delete().eq("id", s.id);
        removed++;
      } else failed++;
    }
  }));

  return json(200, { sent, removed, failed, total: subs?.length ?? 0 });
});
