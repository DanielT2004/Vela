// Vela — Gemini Files API proxy (Supabase Edge Function, Deno).
//
// Purpose: keep GEMINI_API_KEY off the device. The iOS app no longer ships the
// key — it calls this function, which injects the key (stored as a Supabase
// secret) and forwards to Google's Generative Language API.
//
// Only the three KEY-BEARING control-plane calls are proxied. The heavy
// 5–50 MB proxy-video upload is NOT here: Google's resumable session URL is
// itself the credential, so the app PUTs the bytes phone→Google directly. We
// never stream video through this function.
//
// Ops (JSON body `{ "op": ..., ... }`):
//   start    { numBytes, mimeType?, displayName? }           -> { uploadUrl }          (key-bearing)
//   poll     { name }                                         -> Gemini file JSON (verbatim)
//   generate { payload, model? }                              -> generateContent JSON (verbatim)
//   analyze  { fileUri, fileName, mimeType, payload, model?, deviceToken?, apnsEnv? } -> { jobId } (async job)
//   status   { jobId }                                        -> { status, result?, error? }
// Any other op is rejected — this is an allowlist, not an open pass-through.
//
// ASYNC JOB RUNNER (analyze/status): the heavy poll-until-ACTIVE + generateContent +
// response-extraction loop used to run on the phone, so backgrounding the app killed it. Now
// `analyze` records a row in the `jobs` table, returns its id immediately, and finishes the work
// AFTER the HTTP response via `EdgeRuntime.waitUntil` — so it survives the client closing. The app
// polls `status` (and re-attaches on relaunch). The `jobs` table is service-role-only (see the
// 0001_jobs.sql migration); the client never touches it directly.
//
// Auth: JWT verification stays ON (deploy WITHOUT --no-verify-jwt). The Supabase
// gateway requires the app's anon key before this code runs. That blocks casual
// abuse only — the anon key still ships in the app.
// TODO (accounts milestone): per-user Supabase Auth + rate-limit / quota here.

// `EdgeRuntime` is a Supabase Edge runtime global (no import); declared so TypeScript is happy.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const GEMINI_BASE = "https://generativelanguage.googleapis.com";

// Auto-injected into every deployed Edge Function — the async job runner uses these to read/write
// the `jobs` table with service-role access (which bypasses RLS). Empty only in a bare local run.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// APNs (Apple Push) secrets — set these to light up "notify when the job finishes while the app is
// fully closed". All optional: if any is missing the worker just skips the push (the job still runs and
// the client's local notification still covers the foreground case). See 0002_jobs_apns.sql.
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "";
const APNS_AUTH_KEY = Deno.env.get("APNS_AUTH_KEY") ?? "";   // full .p8 PEM contents

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

// Pass Gemini's response straight back to the client — same status, same JSON body —
// so the app's existing error handling (HTTP code + body) keeps working unchanged.
function passthrough(text: string, status: number): Response {
  return new Response(text, {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

// --- jobs table access (PostgREST, service role bypasses RLS — no Supabase SDK) ----------------

function dbHeaders(): Record<string, string> {
  return {
    "apikey": SERVICE_ROLE,
    "Authorization": `Bearer ${SERVICE_ROLE}`,
    "Content-Type": "application/json",
  };
}

async function dbInsertJob(row: Record<string, unknown>): Promise<string> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/jobs`, {
    method: "POST",
    headers: { ...dbHeaders(), "Prefer": "return=representation" },
    body: JSON.stringify(row),
  });
  if (!r.ok) throw new Error(`insert jobs failed: ${r.status} ${await r.text()}`);
  const [created] = await r.json();
  return created.id as string;
}

async function dbUpdateJob(id: string, patch: Record<string, unknown>): Promise<void> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/jobs?id=eq.${id}`, {
    method: "PATCH",
    headers: dbHeaders(),
    body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() }),
  });
  if (!r.ok) throw new Error(`update jobs failed: ${r.status} ${await r.text()}`);
}

async function dbGetJob(
  id: string,
): Promise<{ status: string; result: string | null; error: string | null } | null> {
  const r = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${id}&select=status,result,error`,
    { headers: dbHeaders() },
  );
  if (!r.ok) return null;
  const rows = await r.json();
  return rows[0] ?? null;
}

/// Read just the push fields for a finished job — kept separate from dbGetJob so the worker can fetch
/// the device token without widening the client-facing `status` shape.
async function dbGetJobPush(
  id: string,
): Promise<{ device_token: string | null; apns_env: string | null } | null> {
  const r = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${id}&select=device_token,apns_env`,
    { headers: dbHeaders() },
  );
  if (!r.ok) return null;
  const rows = await r.json();
  return rows[0] ?? null;
}

// --- APNs push (HTTP/2 + ES256 JWT, no SDK) -----------------------------------------------------
//
// Notifies the device when a job finishes EVEN IF THE APP IS FULLY CLOSED — the one thing a local
// `UNUserNotificationCenter` notification can't do. The JWT is signed with the team's APNs Auth Key
// (.p8) via Web Crypto; Apple lets one token live 20–60 min, so we cache it.

function apnsB64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Decode a PKCS#8 PEM (the .p8 body) to raw DER bytes for crypto.subtle.importKey.
function apnsPemToPkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

let apnsJwtCache: { token: string; iat: number } | null = null;

async function apnsJwt(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (apnsJwtCache && now - apnsJwtCache.iat < 3000) return apnsJwtCache.token;   // reuse <50 min
  const header = apnsB64Url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID })));
  const claims = apnsB64Url(new TextEncoder().encode(JSON.stringify({ iss: APNS_TEAM_ID, iat: now })));
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8", apnsPemToPkcs8(APNS_AUTH_KEY),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput),
  ));
  // Web Crypto already emits the raw r||s signature APNs JWTs require (no DER unwrap needed).
  const token = `${signingInput}.${apnsB64Url(sig)}`;
  apnsJwtCache = { token, iat: now };
  return token;
}

/// Best-effort push. Never throws — a delivery failure must not flip a finished job to 'failed'.
async function sendApnsPush(
  deviceToken: string,
  title: string,
  body: string,
  env: "sandbox" | "production",
  custom: Record<string, unknown> = {},
): Promise<void> {
  if (!deviceToken || !APNS_AUTH_KEY || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_BUNDLE_ID) {
    console.log(`[apns] skip — missing device token or APNs secrets`);
    return;
  }
  // Hard timeout so a stalled APNs connection (e.g. an HTTP/2 negotiation that never completes on the
  // Edge runtime) can't hang the worker and starve/​orphan the analysis job. Best-effort: abort and move on.
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 10_000);
  try {
    const host = env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const jwt = await apnsJwt();
    const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default" }, ...custom });
    const r = await fetch(`https://${host}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        "authorization": `bearer ${jwt}`,
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: payload,
      signal: ctrl.signal,
    });
    if (r.status === 200) {
      console.log(`[apns] delivered to ${deviceToken.slice(0, 8)}… (${env})`);
      return;
    }
    const text = await r.text();
    console.error(`[apns] HTTP ${r.status} (${env}) — ${text}`);
    if (r.status === 410) console.warn(`[apns] token unregistered (410) — should be purged later`);
  } catch (e) {
    console.error(`[apns] send threw: ${e instanceof Error ? e.message : String(e)}`);
  } finally {
    clearTimeout(timer);
  }
}

/// Push the job's outcome to the device (if it registered a token). Reads the token/env back from the
/// row so it works regardless of which process wrote the result (e.g. the relaunch-recovery path).
async function notifyJobFinished(jobId: string, success: boolean): Promise<void> {
  // Fully isolated: a push is best-effort and must NEVER throw into runJob (which would flip a finished
  // job's outcome) — every failure mode is swallowed here and in `sendApnsPush`.
  try {
    const push = await dbGetJobPush(jobId);
    if (!push?.device_token) return;
    const env = push.apns_env === "production" ? "production" : "sandbox";
    if (success) {
      await sendApnsPush(push.device_token, "Your cut is ready 🍴", "Tap to see your results.", env,
                         { screen: "analysis", jobId });
    } else {
      await sendApnsPush(push.device_token, "Analysis hit a snag", "Open Vela to try again.", env,
                         { screen: "analysis", jobId });
    }
  } catch (e) {
    console.error(`[apns] notify threw for ${jobId}: ${e instanceof Error ? e.message : String(e)}`);
  }
}

// --- the async analysis worker (runs AFTER the HTTP response, via EdgeRuntime.waitUntil) --------
//
// This is the loop that used to run on the phone: poll files.get until ACTIVE, call
// generateContent, then extract the candidate text EXACTLY as GeminiService.generate() did
// (blockReason check → join candidates[0].content.parts[].text → empty ⇒ fail with finishReason).
// The result text is stored verbatim in jobs.result; the client still runs EditPlan.parse on it.
async function runJob(
  jobId: string,
  fileName: string,
  payload: unknown,
  model: string,
  key: string,
): Promise<void> {
  const t0 = Date.now();
  const elapsed = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`;
  // Mark the job failed AND push the bad news to the device (so a closed-app user isn't left waiting).
  const fail = async (error: string) => {
    await dbUpdateJob(jobId, { status: "failed", error });
    await notifyJobFinished(jobId, false);
  };
  try {
    console.log(`[runJob ${jobId}] start — polling files.get for ${fileName}`);
    // Step 1 — poll files.get until ACTIVE (mirrors waitUntilActive). ~170s budget so we self-bail
    // to 'failed' BEFORE the runtime's wall-clock cap rather than orphaning the row at 'active'.
    const deadline = Date.now() + 170_000;
    let state = "";
    while (Date.now() < deadline) {
      const g = await fetch(`${GEMINI_BASE}/v1beta/${fileName}?key=${key}`);
      if (!g.ok) {
        await fail(`poll HTTP ${g.status}: ${(await g.text()).slice(0, 300)}`);
        return;
      }
      const f = await g.json();
      state = f.state ?? "";
      if (state === "ACTIVE") break;
      if (state === "FAILED") {
        await fail("Gemini failed to process the uploaded video.");
        return;
      }
      await new Promise((res) => setTimeout(res, 2000));
    }
    if (state !== "ACTIVE") {
      await fail("Timed out: file never became ACTIVE.");
      return;
    }

    // Step 2 — generateContent (the long call). Forward the client's payload verbatim.
    await dbUpdateJob(jobId, { status: "generating" });
    console.log(`[runJob ${jobId}] file ACTIVE at ${elapsed()} — calling generateContent (${model})`);
    const g = await fetch(`${GEMINI_BASE}/v1beta/models/${model}:generateContent?key=${key}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const text = await g.text();
    console.log(`[runJob ${jobId}] generateContent HTTP ${g.status} at ${elapsed()}, ${text.length} chars`);
    if (!g.ok) {
      await fail(`Gemini HTTP ${g.status}: ${text.slice(0, 300)}`);
      return;
    }

    // Step 3 — extract the model text EXACTLY as the Swift client did.
    let parsed: {
      promptFeedback?: { blockReason?: string };
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> }; finishReason?: string }>;
    };
    try {
      parsed = JSON.parse(text);
    } catch {
      await fail("Gemini returned non-JSON.");
      return;
    }

    const block = parsed?.promptFeedback?.blockReason;
    if (block) {
      await fail(`Gemini returned no usable text (blocked: ${block}).`);
      return;
    }

    const out = (parsed?.candidates?.[0]?.content?.parts ?? [])
      .map((p) => p?.text ?? "")
      .join("");
    if (!out) {
      const finish = parsed?.candidates?.[0]?.finishReason ?? "none";
      await fail(`Gemini returned no usable text (finishReason: ${finish}).`);
      return;
    }

    await dbUpdateJob(jobId, { status: "done", result: out });
    console.log(`[runJob ${jobId}] done at ${elapsed()}, ${out.length} chars`);
    await notifyJobFinished(jobId, true);
  } catch (e) {
    // Capture the REAL error so we can diagnose (the old code swallowed it into a generic message).
    const detail = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
    console.error(`[runJob ${jobId}] worker threw at ${elapsed()}: ${detail}`,
                  e instanceof Error ? e.stack : "");
    try {
      await fail(`Worker error (${elapsed()}): ${detail}`.slice(0, 500));
    } catch (e2) {
      console.error(`[runJob ${jobId}] could not record failure:`, e2);
    }
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) return json({ error: "Server is missing the GEMINI_API_KEY secret" }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const op = body.op;

  try {
    switch (op) {
      // 1a — open a resumable upload session; hand the keyless session URL back to the app.
      case "start": {
        const numBytes = body.numBytes;
        const mimeType = typeof body.mimeType === "string" ? body.mimeType : "video/mp4";
        const displayName = typeof body.displayName === "string" ? body.displayName : "vela-merged";
        if (typeof numBytes !== "number" || numBytes <= 0) {
          return json({ error: "start requires a positive numBytes" }, 400);
        }
        const g = await fetch(`${GEMINI_BASE}/upload/v1beta/files?key=${key}`, {
          method: "POST",
          headers: {
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": String(numBytes),
            "X-Goog-Upload-Header-Content-Type": mimeType,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ file: { display_name: displayName } }),
        });
        if (!g.ok) return passthrough(await g.text(), g.status);
        const uploadUrl = g.headers.get("x-goog-upload-url");
        if (!uploadUrl) return json({ error: "Gemini did not return an upload URL" }, 502);
        return json({ uploadUrl });
      }

      // 2 — poll files.get until ACTIVE (the app runs the loop; each call is short).
      case "poll": {
        const name = body.name;
        if (typeof name !== "string" || !name) {
          return json({ error: "poll requires a file name" }, 400);
        }
        const g = await fetch(`${GEMINI_BASE}/v1beta/${name}?key=${key}`);
        return passthrough(await g.text(), g.status);
      }

      // 3 — generateContent (the long one, ~30–120s). Forward the app's full payload.
      case "generate": {
        const payload = body.payload;
        if (payload == null || typeof payload !== "object") {
          return json({ error: "generate requires a payload object" }, 400);
        }
        const model = typeof body.model === "string" ? body.model : "gemini-2.5-flash";
        const g = await fetch(
          `${GEMINI_BASE}/v1beta/models/${model}:generateContent?key=${key}`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(payload),
          },
        );
        return passthrough(await g.text(), g.status);
      }

      // 4 — analyze: record a job, return its id immediately, finish the work server-side (poll +
      //     generate + extract) via EdgeRuntime.waitUntil so it survives the client closing the app.
      case "analyze": {
        const fileUri = body.fileUri;
        const fileName = body.fileName;
        const mimeType = body.mimeType;
        const payload = body.payload;
        const model = typeof body.model === "string" ? body.model : "gemini-2.5-flash";
        // Optional APNs fields — let the worker push when the job finishes while the app is closed. Not
        // part of the validation gate: a tokenless client (perms denied / not yet registered) still runs.
        const deviceToken = typeof body.deviceToken === "string" && body.deviceToken ? body.deviceToken : null;
        const apnsEnv = body.apnsEnv === "production" ? "production" : "sandbox";
        if (
          typeof fileUri !== "string" || !fileUri ||
          typeof fileName !== "string" || !fileName ||
          typeof mimeType !== "string" || !mimeType ||
          payload == null || typeof payload !== "object"
        ) {
          return json({ error: "analyze requires fileUri, fileName, mimeType and a payload object" }, 400);
        }
        if (!SUPABASE_URL || !SERVICE_ROLE) {
          return json({ error: "Server is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY" }, 500);
        }
        const jobId = await dbInsertJob({
          status: "active",
          file_uri: fileUri,
          file_name: fileName,
          mime_type: mimeType,
          payload,
          model,
          device_token: deviceToken,
          apns_env: apnsEnv,
        });
        // Keep the worker alive past this HTTP response — the job runs to completion server-side.
        EdgeRuntime.waitUntil(runJob(jobId, fileName, payload, model, key));
        return json({ jobId });
      }

      // 5 — status: read a job's state for the client poll (and relaunch / kill-recovery).
      case "status": {
        const jobId = body.jobId;
        if (typeof jobId !== "string" || !jobId) {
          return json({ error: "status requires a jobId" }, 400);
        }
        if (!SUPABASE_URL || !SERVICE_ROLE) {
          return json({ error: "Server is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY" }, 500);
        }
        const row = await dbGetJob(jobId);
        if (!row) return json({ error: "job not found" }, 404);
        return json({ status: row.status, result: row.result ?? null, error: row.error ?? null });
      }

      default:
        return json({ error: `Unknown op: ${String(op)}` }, 400);
    }
  } catch (e) {
    // Never leak internals (could include the key in a stack); return a generic message.
    return json({ error: "Proxy request failed" }, 502);
  }
});
