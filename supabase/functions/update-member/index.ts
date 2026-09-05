import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const AUTH_DOMAIN = "fund.local";

// Edit a member's details. Officers may edit anyone (incl. status); a member may edit their own
// name, phone and username. Username changes also update the hidden auth email so login keeps working.
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") ?? "";

  const caller = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const [{ data: me }, { data: isOfficer }] = await Promise.all([caller.rpc("me"), caller.rpc("is_officer")]);
  if (!me) return json({ error: "Not a member" }, 403);

  let body: { member_id?: string; username?: string; full_name?: string; phone?: string | null; status?: string; language?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid body" }, 400); }
  const memberId = body.member_id ?? me;
  const isSelf = memberId === me;
  if (!isSelf && !isOfficer) return json({ error: "Officers only" }, 403);

  const patch: Record<string, unknown> = {};
  if (body.full_name !== undefined) {
    const n = String(body.full_name).trim(); if (n.length < 2) return json({ error: "Name too short" }, 400); patch.full_name = n;
  }
  if (body.phone !== undefined) patch.phone = body.phone ? String(body.phone).trim() : null;
  if (body.language !== undefined && ["en", "sw"].includes(String(body.language))) patch.language = body.language;
  if (body.status !== undefined) {
    if (!isOfficer) return json({ error: "Only officers can change status" }, 403);
    if (!["active", "suspended", "exited"].includes(String(body.status))) return json({ error: "Invalid status" }, 400);
    patch.status = body.status;
    if (body.status === "exited") patch.exited_on = new Date().toISOString().slice(0, 10);
  }
  let newUsername: string | null = null;
  if (body.username !== undefined) {
    newUsername = String(body.username).toLowerCase().trim();
    if (!/^[a-z0-9_]{3,20}$/.test(newUsername)) return json({ error: "Username must be 3-20 chars: a-z, 0-9, _" }, 400);
    patch.username = newUsername;
  }
  if (!Object.keys(patch).length) return json({ error: "Nothing to change" }, 400);

  const admin = createClient(url, service);
  const { data: member, error: findErr } = await admin.from("members").select("id, user_id, username").eq("id", memberId).maybeSingle();
  if (findErr || !member) return json({ error: "Member not found" }, 404);

  if (newUsername && newUsername !== member.username) {
    const { data: clash } = await admin.from("members").select("id").eq("username", newUsername).neq("id", memberId).maybeSingle();
    if (clash) return json({ error: "That username is already taken" }, 409);
    if (member.user_id) {
      const { error: authErr } = await admin.auth.admin.updateUserById(member.user_id, { email: `${newUsername}@${AUTH_DOMAIN}`, email_confirm: true });
      if (authErr) return json({ error: authErr.message }, 500);
    }
  }

  const { error: updErr } = await admin.from("members").update(patch).eq("id", memberId);
  if (updErr) return json({ error: updErr.message }, 500);
  return json({ ok: true, member_id: memberId, changed: Object.keys(patch) });
});
