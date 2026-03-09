/**
 * LINE ↔ ntfy Bridge — Cloudflare Worker
 *
 * Flow: LINE Webhook → signature verify → extract text → POST to ntfy → LINE reply
 *
 * Required secrets (set via `wrangler secret set`):
 *   LINE_CHANNEL_SECRET       — for HMAC-SHA256 signature verification
 *   LINE_CHANNEL_ACCESS_TOKEN — for LINE reply API
 *   ANTHROPIC_API_KEY          — for Haiku instant reply (optional; falls back to fixed text)
 *
 * ntfy topic: https://ntfy.sh/REDACTED_NTFY_TOPIC
 */

const NTFY_URL = "https://ntfy.sh/REDACTED_NTFY_TOPIC";
const NTFY_TOKEN = "REDACTED_TOKEN";
const LINE_REPLY_URL = "https://api.line.me/v2/bot/message/reply";
const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const HAIKU_MODEL = "claude-haiku-4-5-20251001";
const HAIKU_TIMEOUT_MS = 8000;
const FALLBACK_REPLY = "受信しました。ダークニンジャが対応します。";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // GET /status — debug endpoint to inspect KV data
    if (request.method === "GET" && url.pathname === "/status") {
      try {
        const raw = env.STATUS_KV ? await env.STATUS_KV.get("agent_status") : null;
        if (!raw) {
          return new Response(JSON.stringify({ error: "no data in KV" }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(raw, {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    // Debug: test ntfy connectivity
    if (url.pathname === "/test-ntfy") {
      try {
        const resp = await fetch(NTFY_URL, {
          method: "POST",
          headers: { "Content-Type": "text/plain; charset=utf-8", "Title": "Worker test", "Authorization": `Bearer ${NTFY_TOKEN}` },
          body: "ntfy test from worker " + new Date().toISOString(),
        });
        return new Response(`ntfy response: ${resp.status} ${await resp.text()}`, { status: 200 });
      } catch (e) {
        return new Response(`ntfy error: ${e.message}`, { status: 500 });
      }
    }

    if (url.pathname !== "/webhook") {
      return new Response("Not Found", { status: 404 });
    }

    const bodyText = await request.text();

    // --- Signature Verification ---
    const signature = request.headers.get("x-line-signature");
    if (!signature) {
      return new Response("Forbidden: missing signature", { status: 403 });
    }

    const isValid = await verifySignature(bodyText, signature, env.LINE_CHANNEL_SECRET);
    if (!isValid) {
      return new Response("Forbidden: invalid signature", { status: 403 });
    }

    // --- Parse Events ---
    let body;
    try {
      body = JSON.parse(bodyText);
    } catch {
      return new Response("Bad Request: invalid JSON", { status: 400 });
    }

    const events = body.events || [];

    // Process events in background — return 200 OK immediately to LINE
    // LINE webhooks require fast response; Haiku API calls run via ctx.waitUntil
    for (const event of events) {
      ctx.waitUntil(handleEvent(event, env, ctx));
    }

    return new Response("OK", { status: 200 });
  },
};

/**
 * Verify LINE webhook signature using HMAC-SHA256
 */
async function verifySignature(body, signature, channelSecret) {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(channelSecret);
  const messageData = encoder.encode(body);

  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signatureBuffer = await crypto.subtle.sign("HMAC", cryptoKey, messageData);
  const expectedSignature = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));

  return expectedSignature === signature;
}

/**
 * Handle a single LINE event
 */
async function handleEvent(event, env, ctx) {
  try {
    if (event.type !== "message") {
      return;
    }

    const userId = event.source?.userId ?? "unknown";
    const replyToken = event.replyToken;
    const msgType = event.message?.type;
    if (msgType === "text") {
      const text = event.message.text;
      const wantsStatus = /状況/.test(text);

      if (wantsStatus) {
        const statusText = await getStatusText(env);
        const replyBody = statusText || "ステータス未登録（cron未起動の可能性）";
        await replyToLine(replyToken, replyBody, env.LINE_CHANNEL_ACCESS_TOKEN);
      } else {
        await handleTextWithHaiku(text, userId, replyToken, env, ctx);
      }
    } else if (msgType === "image" || msgType === "video" || msgType === "file") {
      const messageId = event.message.id;
      const fileName = event.message.fileName || null;
      await postToNtfy(`lineimg:${messageId}:${msgType}:${fileName || ""}`, userId);
    }
  } catch (e) {
    console.error(`handleEvent FATAL: ${e.message}\n${e.stack}`);
  }
}

/**
 * Get formatted status text from KV (returns null on any failure)
 */
async function getStatusText(env) {
  if (!env.STATUS_KV) return null;
  try {
    const raw = await env.STATUS_KV.get("agent_status");
    if (!raw) return null;
    const data = JSON.parse(raw);
    return formatStatusMessage(data);
  } catch {
    return null;
  }
}

/**
 * Format KV JSON into a compact LINE-friendly status message
 *
 * Output example:
 *   🖥️ peer-hostname 07:35 (load:0.8)
 *   dn:ON gry:ON souk:ON
 *   y1:cmd_347a y5:cmd_347b
 *   idle: y2,y3,y4,y6,y7
 *   🐢OK 🐦OK
 */
function formatStatusMessage(data) {
  const lines = [];

  // Header: machine, time, load
  const host = data.hostname || "?";
  const time = data.timestamp_jst || "??:??";
  const load = data.load_avg || "?";
  lines.push(`🖥️ ${host} ${time} (load:${load})`);

  // Agent summary
  const abbrev = {
    darkninja: "dn", gryakuza: "gry", soukaiya: "souk",
    master_tortoise: "🐢", master_crane: "🐦",
  };

  const agents = data.agents || [];
  const taskMap = {};
  for (const t of (data.tasks || [])) {
    if (t.task_id && t.status !== "idle") {
      taskMap[t.file] = t.task_id;
    }
  }

  // Core agents (non-yakuza)
  const coreAgents = agents.filter(a => !a.id.startsWith("yakuza"));
  const coreParts = coreAgents.map(a => {
    const label = abbrev[a.id] || a.id;
    const running = a.process === "claude" ? "ON" : "off";
    return `${label}:${running}`;
  });
  if (coreParts.length) lines.push(coreParts.join(" "));

  // Yakuza agents: active (with task) vs idle
  const yakuzas = agents.filter(a => a.id.startsWith("yakuza"));
  const activeYak = [];
  const idleYak = [];
  for (const y of yakuzas) {
    const num = y.id.replace("yakuza", "y");
    const task = taskMap[y.id];
    if (task) {
      activeYak.push(`${num}:${task}`);
    } else if (y.process !== "claude") {
      idleYak.push(num + ":off");
    } else {
      idleYak.push(num);
    }
  }
  if (activeYak.length) lines.push(activeYak.join(" "));
  if (idleYak.length) lines.push(`idle: ${idleYak.join(",")}`);

  // Heartbeats (other machines)
  for (const hb of (data.heartbeats || [])) {
    const icon = hb.machine === "tortoise" ? "🐢" : hb.machine === "crane" ? "🐦" : "📡";
    const st = hb.status === "alive" ? "OK" : hb.status.toUpperCase();
    const ctx = hb.context && hb.context !== "ok" ? `(${hb.context})` : "";
    lines.push(`${icon}${st}${ctx}`);
  }

  return lines.join("\n");
}

/**
 * POST message to ntfy
 */
async function postToNtfy(text, userId) {
  const resp = await fetch(NTFY_URL, {
    method: "POST",
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Title": `LINE: ${userId}`,
      "Authorization": `Bearer ${NTFY_TOKEN}`,
    },
    body: text,
  });
  if (!resp.ok) {
    console.error(`ntfy POST failed: ${resp.status} ${await resp.text()}`);
  }
}

/**
 * Send reply message via LINE Messaging API
 */
async function replyToLine(replyToken, text, accessToken) {
  await fetch(LINE_REPLY_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      replyToken,
      messages: [{ type: "text", text }],
    }),
  });
}

/**
 * Handle text message with Haiku instant reply + async ntfy forwarding
 */
async function handleTextWithHaiku(text, userId, replyToken, env, ctx) {
  let haikuReply = null;

  if (env.ANTHROPIC_API_KEY) {
    const agentStatus = await getStatusText(env);
    const customPrompt = env.STATUS_KV ? await env.STATUS_KV.get("haiku_system_prompt") : null;
    haikuReply = await callHaikuWithTimeout(text, agentStatus, customPrompt, env.ANTHROPIC_API_KEY, HAIKU_TIMEOUT_MS);
  }

  const replyText = haikuReply || FALLBACK_REPLY;
  await replyToLine(replyToken, replyText, env.LINE_CHANNEL_ACCESS_TOKEN);

  const ntfyBody = haikuReply
    ? `${text}\n[Haiku応答]: ${haikuReply}`
    : text;
  ctx.waitUntil(postToNtfy(ntfyBody, userId));
}

/**
 * Call Haiku API with timeout. Returns response text or null on failure.
 */
async function callHaikuWithTimeout(userMessage, agentStatus, customPrompt, apiKey, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const systemPrompt = buildHaikuSystemPrompt(agentStatus, customPrompt);
    const resp = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: HAIKU_MODEL,
        max_tokens: 500,
        system: systemPrompt,
        messages: [{ role: "user", content: userMessage }],
      }),
      signal: controller.signal,
    });

    if (!resp.ok) {
      console.error(`Haiku API error: ${resp.status}`);
      return null;
    }

    const data = await resp.json();
    const text = data.content?.[0]?.text;
    return text || null;
  } catch (e) {
    if (e.name === "AbortError") {
      console.error("Haiku API timeout");
    } else {
      console.error(`Haiku API error: ${e.message}`);
    }
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Build system prompt for Haiku instant reply
 * If customPrompt is set in KV (key: haiku_system_prompt), use it as base.
 * Otherwise fall back to default prompt.
 */
function buildHaikuSystemPrompt(agentStatus, customPrompt) {
  const statusBlock = agentStatus
    ? `\n\n現在のシステム状況:\n${agentStatus}`
    : "";

  if (customPrompt) {
    return `${customPrompt}${statusBlock}`;
  }

  return `あなたはLINEメッセージの一次応答担当です。ユーザーのメッセージに対して簡潔に返信してください。

ルール:
- 3行以内で簡潔に返信する
- メッセージの意図を理解し、適切に応答する
- 詳細な対応や判断が必要な場合は「詳しくはダークニンジャが後ほど対応します」と伝える
- 状況確認の場合はシステム状況を参照して回答する
- 日本語で返信する${statusBlock}`;
}
