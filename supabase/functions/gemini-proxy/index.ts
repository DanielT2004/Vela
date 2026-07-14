// Vela — Gemini Files API proxy (Supabase Edge Function, Deno).
//
// Rev: 2026-07-12 — chained server-side consolidation: the style push now fires at TRUE completion
// (template fully built), not at last-extraction. Client authors the payload; server only substitutes.
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
//   analyze  { fileUri, fileName, mimeType, payload, model?, deviceToken?, apnsEnv?, notifyOnFinish?, notifyKind?, batchId?, batchSize?, batchIndex?, consolidation? } -> { jobId } (async job)
//   status   { jobId }                                        -> { status, result?, error?, consolidationJobId? }
//   chain    { jobId }  INTERNAL (service-role only)          -> { ok } (runs a text-only chained job)
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
): Promise<{ status: string; result: string | null; error: string | null; consolidation_job_id: string | null } | null> {
  const r = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${id}&select=status,result,error,consolidation_job_id`,
    { headers: dbHeaders() },
  );
  // A non-ok PostgREST fetch is a TRANSIENT DB error, not a missing job — throw so the `status` handler
  // can answer 503 (retryable) instead of collapsing it to a 404 the client treats as terminal (#11).
  if (!r.ok) throw new Error(`dbGetJob fetch failed: ${r.status} ${await r.text()}`);
  const rows = await r.json();
  return rows[0] ?? null;   // null now means ONLY a genuine 0-row (the job truly doesn't exist)
}

/// Read just the push fields for a finished job — kept separate from dbGetJob so the worker can fetch
/// the device token without widening the client-facing `status` shape.
async function dbGetJobPush(
  id: string,
): Promise<{ device_token: string | null; apns_env: string | null; notify_kind: string | null } | null> {
  const r = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${id}&select=device_token,apns_env,notify_kind`,
    { headers: dbHeaders() },
  );
  if (!r.ok) return null;
  const rows = await r.json();
  return rows[0] ?? null;
}

// --- batch grouping (0005_jobs_batch.sql) — one push per multi-video style learn -----------------

/// Read a finished job's batch membership (null batch_id ⇒ standalone job, per-job push behavior).
async function dbGetJobBatch(
  id: string,
): Promise<{ batch_id: string | null; batch_size: number | null } | null> {
  const r = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${id}&select=batch_id,batch_size`,
    { headers: dbHeaders() },
  );
  if (!r.ok) return null;
  const rows = await r.json();
  return rows[0] ?? null;
}

/// How many of the batch's sibling jobs have reached 'done'. Callers count AFTER committing their own
/// status flip, so when all N truly finished at least one sibling is guaranteed to observe N/N.
async function dbCountBatchDone(batchId: string): Promise<number> {
  const r = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?batch_id=eq.${batchId}&status=eq.done&select=id`,
    { headers: dbHeaders() },
  );
  if (!r.ok) throw new Error(`count batch done failed: ${r.status} ${await r.text()}`);
  return ((await r.json()) as unknown[]).length;
}

/// Exactly-once latch: flip the batch's rows `batch_notified false → true` in ONE statement and ask
/// PostgREST to return the updated rows. Two near-simultaneous finishers both attempting the claim
/// resolve at the row locks — the loser's UPDATE matches zero rows and gets an empty body back.
async function dbClaimBatchNotify(batchId: string): Promise<boolean> {
  const r = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?batch_id=eq.${batchId}&batch_notified=eq.false`,
    {
      method: "PATCH",
      headers: { ...dbHeaders(), "Prefer": "return=representation" },
      body: JSON.stringify({ batch_notified: true }),
    },
  );
  if (!r.ok) throw new Error(`claim batch notify failed: ${r.status} ${await r.text()}`);
  return ((await r.json()) as unknown[]).length > 0;
}

// --- chained consolidation (0006_jobs_consolidation.sql) — push at TRUE completion ---------------
//
// The style pipeline's final merge is a text-only Gemini call whose prompt needs the N extraction
// RESULTS — which only exist when the last sibling finishes. The client can't be trusted to be alive
// then (closed phone), so it authors the COMPLETE payload at submit time with «VELA_SRC_i» tokens
// standing in for the results, and the latch winner substitutes + chains. The server owns ZERO prompt
// text — it only pastes strings into a client-authored template (no prompt drift, no TS mirror).

/// Mirror of the Swift client's fence-strip (EditPlan.parse) — extraction results are schema-
/// constrained JSON, so this is belt-and-braces for a stray ``` wrapper.
function stripFences(s: string): string {
  let t = s.trim();
  if (t.startsWith("```")) {
    t = t.replace(/^```[a-zA-Z]*\s*/, "").replace(/```\s*$/, "").trim();
  }
  return t;
}

/// Replace every «VELA_SRC_i» token (see StyleConsolidator.sourcePlaceholder — keep in lockstep) in
/// every string leaf of the payload with that slot's extraction result.
function substituteSources(node: unknown, bySlot: Map<number, string>): unknown {
  if (typeof node === "string") {
    let out = node;
    for (const [i, text] of bySlot) out = out.split(`«VELA_SRC_${i}»`).join(text);
    return out;
  }
  if (Array.isArray(node)) return node.map((n) => substituteSources(n, bySlot));
  if (node && typeof node === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(node as Record<string, unknown>)) out[k] = substituteSources(v, bySlot);
    return out;
  }
  return node;
}

/// Start the chained consolidation for a completed batch (caller already WON the latch). Returns true
/// when the chain is handed off — the "style is ready" push then belongs to the chained job's own
/// completion (the TRUE end of the pipeline). false (no spec — old client / N=1) or throw ⇒ the
/// caller falls back to pushing at extractions-done, exactly the pre-chain behavior.
async function startConsolidationChain(winnerJobId: string, batchId: string): Promise<boolean> {
  // The spec + push routing ride the winner's row (identical copies were sent with every sibling).
  const w = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${winnerJobId}&select=consolidation,device_token,apns_env`,
    { headers: dbHeaders() },
  );
  if (!w.ok) throw new Error(`chain: read winner failed: ${w.status}`);
  const winner = (await w.json())[0];
  const spec = winner?.consolidation;
  if (!spec || typeof spec !== "object" || spec.payload == null) return false;

  const sib = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?batch_id=eq.${batchId}&select=batch_index,result`,
    { headers: dbHeaders() },
  );
  if (!sib.ok) throw new Error(`chain: read siblings failed: ${sib.status}`);
  const bySlot = new Map<number, string>();
  for (const row of await sib.json()) {
    if (typeof row.batch_index === "number" && typeof row.result === "string" && row.result) {
      bySlot.set(row.batch_index, stripFences(row.result));
    }
  }
  const payload = substituteSources(spec.payload, bySlot);
  // An unfilled token means a missing slot/result — bail to the fallback push rather than send a
  // placeholder to the model.
  if (JSON.stringify(payload).includes("«VELA_SRC_")) throw new Error("chain: unfilled source placeholder");

  const model = typeof spec.model === "string" && spec.model ? spec.model : "gemini-pro-latest";
  const jobId = await dbInsertJob({
    status: "active",
    payload,
    model,
    device_token: winner.device_token ?? null,
    apns_env: winner.apns_env ?? null,
    notify_kind: "style",   // standalone notifying job → its completion/failure pushes via the existing path
  });
  // Point every sibling at the chained job so the client (live or kill-resumed) discovers it from any
  // sibling's `status` and simply awaits the result instead of re-running the merge on-device.
  const stamp = await fetch(`${SUPABASE_URL}/rest/v1/jobs?batch_id=eq.${batchId}`, {
    method: "PATCH",
    headers: dbHeaders(),
    body: JSON.stringify({ consolidation_job_id: jobId }),
  });
  if (!stamp.ok) console.error(`[chain] stamping consolidation_job_id failed: ${stamp.status}`);
  // Run the actual model call in a FRESH invocation (its own wall-clock budget) via the internal
  // `chain` op — this worker is already deep into its own ~170s window. Await only the tiny 200.
  const h = await fetch(`${SUPABASE_URL}/functions/v1/gemini-proxy`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": SERVICE_ROLE,
      "Authorization": `Bearer ${SERVICE_ROLE}`,
    },
    body: JSON.stringify({ op: "chain", jobId }),
  });
  if (!h.ok) {
    // Hand-off failed — mark the orphan so the client's discovery doesn't await a job nobody runs.
    await dbUpdateJob(jobId, { status: "failed", error: `chain handoff HTTP ${h.status}` }).catch(() => {});
    throw new Error(`chain: handoff HTTP ${h.status}`);
  }
  console.log(`[chain] consolidation ${jobId} handed off for batch ${batchId}`);
  return true;
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
    // Style-learning jobs get their own copy + tap target ("template"); everything else is an edit job.
    const isStyle = push.notify_kind === "style";
    if (success) {
      await sendApnsPush(
        push.device_token,
        isStyle ? "Your style is ready ✨" : "Your first cut is ready 🍴",
        isStyle ? "Tap to review your template." : "Tap to watch it.",
        env,
        { screen: isStyle ? "template" : "analysis", jobId },
      );
    } else {
      await sendApnsPush(
        push.device_token,
        isStyle ? "Style analysis hit a snag" : "Your cut hit a snag",
        "Open Vela to try again.",
        env,
        { screen: isStyle ? "template" : "analysis", jobId },
      );
    }
  } catch (e) {
    console.error(`[apns] notify threw for ${jobId}: ${e instanceof Error ? e.message : String(e)}`);
  }
}

/// Batch-aware wrapper around `notifyJobFinished` — the ONLY way runJob should push. Standalone jobs
/// (batch_id null: every edit job, plus style learns from pre-batch clients) pass straight through.
/// Batched jobs (multi-video style learns) push ONCE per batch: on success only when ALL siblings are
/// 'done', and in every case only after winning the `batch_notified` latch — so a 3-video learn sends
/// one "style is ready" when the LAST extraction lands (or one "hit a snag" on the first failure),
/// never three. Same isolation contract as notifyJobFinished: never throws into runJob.
async function maybeNotifyBatch(jobId: string, success: boolean): Promise<void> {
  try {
    const batch = await dbGetJobBatch(jobId);
    if (!batch?.batch_id) {
      await notifyJobFinished(jobId, success);
      return;
    }
    const size = batch.batch_size ?? 1;
    if (success) {
      const done = await dbCountBatchDone(batch.batch_id);
      if (done < size) {
        console.log(`[apns] batch ${batch.batch_id}: ${done}/${size} done — holding the push for the last sibling`);
        return;
      }
    }
    if (await dbClaimBatchNotify(batch.batch_id)) {
      if (success) {
        // All extractions landed — chain the consolidation when the client provided a spec, so the
        // "style is ready" push fires when the template is FULLY built (the chained job's completion),
        // not now. No spec (old client / N=1) or a chain failure ⇒ push now, the pre-chain behavior.
        try {
          if (await startConsolidationChain(jobId, batch.batch_id)) return;
        } catch (e) {
          console.error(`[chain] failed for batch ${batch.batch_id} — falling back to extraction-done push: ${e instanceof Error ? e.message : String(e)}`);
        }
      }
      await notifyJobFinished(jobId, success);
    } else {
      console.log(`[apns] batch ${batch.batch_id} already notified — skipping duplicate push`);
    }
  } catch (e) {
    // Same policy as a failed dbGetJobPush: a DB hiccup costs the push, never the job's outcome.
    console.error(`[apns] batch notify threw for ${jobId}: ${e instanceof Error ? e.message : String(e)}`);
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
  fileName: string | null,   // null ⇒ text-only (a chained consolidation) — no Gemini file to poll
  payload: unknown,
  model: string,
  key: string,
  notifyOnSuccess: boolean,
): Promise<void> {
  const t0 = Date.now();
  const elapsed = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`;
  // Mark the job failed AND push the bad news to the device (so a closed-app user isn't left waiting).
  // Batch-aware: a multi-video learn pushes ONE snag alert (first failure wins the latch), not one per job.
  const fail = async (error: string) => {
    await dbUpdateJob(jobId, { status: "failed", error });
    await maybeNotifyBatch(jobId, false);
  };
  try {
    // ~170s budget so we self-bail to 'failed' BEFORE the runtime's wall-clock cap rather than
    // orphaning the row at 'active'/'generating'. Shared by the file poll AND the generate retry.
    const deadline = Date.now() + 170_000;
    if (fileName) {
      console.log(`[runJob ${jobId}] start — polling files.get for ${fileName}`);
      // Step 1 — poll files.get until ACTIVE (mirrors waitUntilActive).
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
    } else {
      console.log(`[runJob ${jobId}] start — text-only (chained consolidation), skipping files.get`);
    }

    // Step 2 — generateContent (the long call). Forward the client's payload verbatim. Retry a transient
    // 5xx/429 once more (KNOWN_ISSUES #2 — an overloaded Gemini usually 503s fast), but ONLY while another
    // attempt + backoff still fits under the ~170s self-bail deadline, so a slow late failure never triggers
    // a retry that would blow past the wall-clock and orphan the row at 'generating'.
    await dbUpdateJob(jobId, { status: "generating" });
    console.log(`[runJob ${jobId}] file ACTIVE at ${elapsed()} — calling generateContent (${model})`);
    const RETRYABLE = new Set([429, 500, 502, 503, 504]);
    const maxAttempts = 2;
    let g: Response | null = null;
    let text = "";
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      g = await fetch(`${GEMINI_BASE}/v1beta/models/${model}:generateContent?key=${key}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      text = await g.text();
      console.log(`[runJob ${jobId}] generateContent HTTP ${g.status} (attempt ${attempt}/${maxAttempts}) at ${elapsed()}, ${text.length} chars`);
      if (g.ok || !RETRYABLE.has(g.status)) break;   // success or a terminal error (400/401/403…) — stop
      const backoffMs = 500;
      if (attempt < maxAttempts && Date.now() + backoffMs < deadline - 5000) {
        console.log(`[runJob ${jobId}] transient HTTP ${g.status} — retrying in ${backoffMs}ms`);
        await new Promise((res) => setTimeout(res, backoffMs));
      } else break;   // out of deadline budget (or last attempt) — fail below rather than risk an orphan
    }
    if (!g || !g.ok) {
      await fail(`Gemini HTTP ${g?.status ?? 0}: ${text.slice(0, 300)}`);
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
    // Only push "cut is ready" when THIS job is the finish. In the two-call pipeline the PERCEIVE
    // `analyze` job is only the first half (DECIDE still follows on-device), so the client sends
    // notifyOnFinish=false for it — the client posts the ping itself after the on-device Gemini DECIDE ships.
    // Batched style jobs additionally hold the push until the LAST sibling is done (see maybeNotifyBatch).
    if (notifyOnSuccess) await maybeNotifyBatch(jobId, true);
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
        const model = typeof body.model === "string" ? body.model : "gemini-flash-latest";
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
        const model = typeof body.model === "string" ? body.model : "gemini-flash-latest";
        // Optional APNs fields — let the worker push when the job finishes while the app is closed. Not
        // part of the validation gate: a tokenless client (perms denied / not yet registered) still runs.
        const deviceToken = typeof body.deviceToken === "string" && body.deviceToken ? body.deviceToken : null;
        const apnsEnv = body.apnsEnv === "production" ? "production" : "sandbox";
        // Whether THIS job's completion is the finish (→ push "cut is ready"). Default true keeps the
        // monolith correct; the two-call PERCEIVE call sends false (DECIDE still follows). Style
        // extraction sends TRUE (+ notifyKind 'style') — its push is additionally batch-gated below.
        const notifyOnFinish = typeof body.notifyOnFinish === "boolean" ? body.notifyOnFinish : true;
        // Which completion copy/screen the worker pushes: 'style' for style-learning, 'edit' otherwise.
        const notifyKind = body.notifyKind === "style" ? "style" : "edit";
        // Optional batch grouping (multi-video style learns): sibling jobs share a batchId and the worker
        // pushes once per BATCH — when the last sibling reaches a terminal state — instead of per job.
        // Both fields or neither: a partial pair is ignored (→ per-job behavior, matches older clients).
        // Shape-checked to uuid so a malformed value degrades to per-job pushes instead of a 502 at insert.
        const batchId = typeof body.batchId === "string" &&
            /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.batchId)
          ? body.batchId : null;
        const batchSize = typeof body.batchSize === "number" && body.batchSize >= 1
          ? Math.floor(body.batchSize) : null;
        const batched = batchId !== null && batchSize !== null;
        // This job's slot in its batch (fills «VELA_SRC_batchIndex» in the consolidation payload) and
        // the client-authored consolidation spec { payload, model } — identical on every sibling; the
        // batch-latch winner reads its own copy and chains the merge (see startConsolidationChain).
        const batchIndex = typeof body.batchIndex === "number" && body.batchIndex >= 0
          ? Math.floor(body.batchIndex) : null;
        const consolidation = body.consolidation && typeof body.consolidation === "object"
          ? body.consolidation : null;
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
          notify_kind: notifyKind,
          ...(batched ? { batch_id: batchId, batch_size: batchSize, batch_index: batchIndex, consolidation } : {}),
        });
        // Keep the worker alive past this HTTP response — the job runs to completion server-side.
        EdgeRuntime.waitUntil(runJob(jobId, fileName, payload, model, key, notifyOnFinish));
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
        let row;
        try {
          row = await dbGetJob(jobId);
        } catch (e) {
          // Transient DB fetch error → 503 (the client retries), NOT 404 (which it now treats as terminal).
          console.error(`[status] dbGetJob failed for ${jobId}: ${e instanceof Error ? e.message : String(e)}`);
          return json({ error: "Database temporarily unavailable" }, 503);
        }
        if (!row) return json({ error: "job not found" }, 404);   // genuine 0-row → the job is really gone
        return json({
          status: row.status,
          result: row.result ?? null,
          error: row.error ?? null,
          // Batched style jobs: the chained consolidation job, once the latch winner stamped it — the
          // client awaits THAT for the final template instead of re-running the merge on-device.
          consolidationJobId: row.consolidation_job_id ?? null,
        });
      }

      // 6 — chain (INTERNAL): run an already-inserted TEXT-ONLY job in a fresh invocation with its own
      //     wall-clock budget. Called only by startConsolidationChain (server→server) — the extraction
      //     worker that wins the batch latch is already deep into its own ~170s window, so the ~60-100s
      //     consolidation call must not ride on it. Locked to the service role: the anon key that ships
      //     in the app must not be able to re-trigger (paid) model calls on arbitrary job rows.
      case "chain": {
        if (req.headers.get("authorization") !== `Bearer ${SERVICE_ROLE}`) {
          return json({ error: "chain is internal" }, 403);
        }
        const jobId = body.jobId;
        if (typeof jobId !== "string" || !jobId) return json({ error: "chain requires a jobId" }, 400);
        const r = await fetch(
          `${SUPABASE_URL}/rest/v1/jobs?id=eq.${jobId}&select=status,payload,model`,
          { headers: dbHeaders() },
        );
        if (!r.ok) return json({ error: "Database temporarily unavailable" }, 503);
        const job = (await r.json())[0];
        if (!job) return json({ error: "job not found" }, 404);
        if (job.status !== "active") return json({ ok: true, note: "already running or terminal" });
        EdgeRuntime.waitUntil(runJob(jobId, null, job.payload, job.model, key, true));
        return json({ ok: true });
      }

      default:
        return json({ error: `Unknown op: ${String(op)}` }, 400);
    }
  } catch (e) {
    // Never leak internals (could include the key in a stack); return a generic message.
    return json({ error: "Proxy request failed" }, 502);
  }
});
