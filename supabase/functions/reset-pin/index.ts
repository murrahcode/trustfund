import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Officer resets a member's PIN. Caller must be a current officer (checked via is_officer()).
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") ?? "";

  const caller = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: isOfficer, error: roleErr } = await caller.rpc("is_officer");
  if (roleErr || !isOfficer) return json({ error: "Officers only" }, 403);

  let body: { username?: string; new_pin?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid body" }, 400); }
  const username = (body.username ?? "").toLowerCase().trim();
  const pin = body.new_pin ?? "";
  if (!/^[a-z0-9_]{3,20}$/.test(username)) return json({ error: "Invalid username" }, 400);
  if (!/^\d{6}$/.test(pin)) return json({ error: "PIN must be exactly 6 digits" }, 400);

  const admin = createClient(url, service);
  const { data: member } = await admin.from("members").select("user_id, full_name").eq("username", username).maybeSingle();
  if (!member) return json({ error: "No member with that username" }, 404);
  if (!member.user_id) return json({ error: "This member has not set up their account yet" }, 409);

  const { error } = await admin.auth.admin.updateUserById(member.user_id, { password: pin });
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true, member: member.full_name });
});
