// Supabase Edge Function "notify" — 포워드 알림 보내기
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const out = (x: unknown, s = 200) => new Response(JSON.stringify(x), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
async function keys() {
  let { data } = await sb.from("fw_conf").select("v").eq("k", "vapid").maybeSingle();
  if (!data) {
    await sb.from("fw_conf").insert({ k: "vapid", v: webpush.generateVAPIDKeys() });
    ({ data } = await sb.from("fw_conf").select("v").eq("k", "vapid").single());
  }
  return data!.v as { publicKey: string; privateKey: string };
}
async function who(token: string) {
  const { data } = await sb.from("fw_sess").select("role,uid").eq("token", token).maybeSingle();
  return data;
}
async function staffIds(ownerOnly = false) {
  const { data } = await sb.from("fw_rec").select("id,data").eq("col", "T").not("data", "is", null);
  return (data || []).filter((r) => !ownerOnly || r.data?.role === "owner").map((r) => r.id as string);
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const b = await req.json();
    const v = await keys();
    if (b.op === "key") return out({ key: v.publicKey });
    let to: string[] = [];
    let title = String(b.title || "포워드 영어학원").slice(0, 60), body = String(b.body || "").slice(0, 160);
    if (b.op === "inquiry") {
      const since = new Date(Date.now() - 3 * 60 * 1000).toISOString();
      const { count } = await sb.from("fw_rec").select("id", { count: "exact", head: true }).eq("col", "I").gt("updated_at", since);
      if (!count) return out({ sent: 0 });
      to = await staffIds(); title = "📥 새 상담 신청";
    } else {
      const s = await who(String(b.token || ""));
      if (!s) return out({ error: "auth" }, 401);
      if (b.op === "sub") {
        const sub = b.sub;
        if (!sub?.endpoint) return out({ error: "bad" }, 400);
        await sb.from("fw_push_subs").upsert({ endpoint: sub.endpoint, uid: s.uid, role: s.role, sub, at: new Date().toISOString() });
        return out({ ok: true });
      }
      if (b.op === "unsub") { await sb.from("fw_push_subs").delete().eq("endpoint", String(b.endpoint || "")); return out({ ok: true }); }
      if (b.op === "who") { if (s.role === "student") return out({ uids: [] }); const { data } = await sb.from("fw_push_subs").select("uid"); return out({ uids: [...new Set((data || []).map((r) => r.uid))] }); }
      const want: string[] = (Array.isArray(b.to) ? b.to : []).map(String).slice(0, 200);
      if (s.role === "student") { const st = await staffIds(); to = want.filter((x) => st.includes(x)); }
      else to = want;
    }
    to = to.filter(Boolean);
    if (!to.length) return out({ sent: 0 });
    webpush.setVapidDetails("https://forwardeng.co.kr", v.publicKey, v.privateKey);
    const { data: subs } = await sb.from("fw_push_subs").select("endpoint,sub").in("uid", to);
    let sent = 0; const fails: string[] = [];
    await Promise.all((subs || []).map(async (r) => {
      try { await webpush.sendNotification(r.sub, JSON.stringify({ title, body, url: "/app/index.html", tag: b.tag })); sent++; }
      catch (e) { const c = (e as { statusCode?: number }).statusCode; fails.push(String(c || (e as Error).message).slice(0, 60)); if (c === 404 || c === 410) await sb.from("fw_push_subs").delete().eq("endpoint", r.endpoint); }
    }));
    console.log(JSON.stringify({ op: b.op || "send", title, to: to.length, devices: (subs || []).length, sent, fails }));
    return out({ sent });
  } catch (e) { return out({ error: String(e) }, 500); }
});
