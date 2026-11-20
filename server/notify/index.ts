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
// 숙제 마감 임박 알림 — 매일 한 번(서버 예약 작업이 부름). 오늘·내일 마감인데 아직 안 낸 숙제가 있는 학생에게만
const kst = (n = 0) => new Date(Date.now() + 9 * 3600e3 + n * 86400e3).toISOString().slice(0, 10);
async function remind() {
  const d0 = kst(0), d1 = kst(1);
  const { error: dup } = await sb.from("fw_conf").insert({ k: "remind:" + d0, v: { at: new Date().toISOString() } });
  if (dup) return { sent: 0, skip: "already sent today" };
  const { data: rows } = await sb.from("fw_rec").select("data").eq("col", "tasks").not("data", "is", null)
    .in("data->>status", ["todo", "redo"]).in("data->>date", [d0, d1]);
  const by: Record<string, { today: string[]; tmr: string[] }> = {};
  for (const r of rows || []) {
    const t = r.data as { sid?: string; date?: string; title?: string };
    if (!t?.sid) continue;
    const g = (by[t.sid] ||= { today: [], tmr: [] });
    (t.date === d0 ? g.today : g.tmr).push(String(t.title || "숙제"));
  }
  const sids = Object.keys(by);
  if (!sids.length) return { sent: 0, students: 0 };
  const v = await keys();
  webpush.setVapidDetails("https://forwardeng.co.kr", v.publicKey, v.privateKey);
  const { data: subs } = await sb.from("fw_push_subs").select("endpoint,uid,sub").in("uid", sids);
  const list = (a: string[]) => a.slice(0, 2).join(", ") + (a.length > 2 ? ` 외 ${a.length - 2}개` : "");
  let sent = 0;
  await Promise.all((subs || []).map(async (r) => {
    const g = by[r.uid];
    const title = g.today.length ? "⏰ 오늘 마감 숙제가 있어요!" : "⏰ 내일 마감 숙제가 있어요";
    const body = [g.today.length ? "오늘까지: " + list(g.today) : "", g.tmr.length ? "내일까지: " + list(g.tmr) : ""]
      .filter(Boolean).join(" · ") + " — 콩떡이가 기다려요 냥 🐾";
    try { await webpush.sendNotification(r.sub, JSON.stringify({ title, body: body.slice(0, 160), url: "/app/index.html", tag: "hw-remind" })); sent++; }
    catch (e) { const c = (e as { statusCode?: number }).statusCode; if (c === 404 || c === 410) await sb.from("fw_push_subs").delete().eq("endpoint", r.endpoint); }
  }));
  console.log(JSON.stringify({ op: "remind", day: d0, students: sids.length, devices: (subs || []).length, sent }));
  return { sent, students: sids.length };
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const b = await req.json();
    const v = await keys();
    if (b.op === "key") return out({ key: v.publicKey });
    let to: string[] = [];
    let title = String(b.title || "포워드 영어학원").slice(0, 60), body = String(b.body || "").slice(0, 160);
    if (b.op === "remind") return out(await remind());
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
