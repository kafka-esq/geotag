// geo# ARCore token: signs a one-hour JWT so the app can use Cloud Anchors that last a year.
// Only members (people who redeemed an invite) get a token.
//
// Deploy:  supabase functions deploy arcore-token
// Secret:  supabase secrets set GOOGLE_SA_JSON="$(cat service-account.json)"
// The service account needs the "ARCore API" enabled on its project; no extra roles are required.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

const sa = JSON.parse(Deno.env.get("GOOGLE_SA_JSON") ?? "{}");

Deno.serve(async (req) => {
  const auth = req.headers.get("Authorization") ?? "";
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: me, error } = await supabase.rpc("me");
  if (error || !me) return new Response(JSON.stringify({ error: "not_a_member" }), { status: 403 });
  if (!sa.private_key || !sa.client_email) {
    return new Response(JSON.stringify({ error: "token_not_configured" }), { status: 501 });
  }

  const key = await importPKCS8(sa.private_key, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const token = await new SignJWT({ uid: me.id })
    .setProtectedHeader({ alg: "RS256", typ: "JWT", kid: sa.private_key_id })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://arcore.googleapis.com/")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  return new Response(JSON.stringify({ token, expires_in: 3600 }), {
    headers: { "Content-Type": "application/json" },
  });
});
