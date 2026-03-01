/**
 * LINE ↔ ntfy Bridge — Cloudflare Worker
 *
 * Flow: LINE Webhook → signature verify → extract text → POST to ntfy → LINE reply
 *
 * Required secrets (set via `wrangler secret set`):
 *   LINE_CHANNEL_SECRET       — for HMAC-SHA256 signature verification
 *   LINE_CHANNEL_ACCESS_TOKEN — for LINE reply API
 *
 * ntfy topic: https://ntfy.sh/REDACTED_NTFY_TOPIC
 */

const NTFY_URL = "https://ntfy.sh/REDACTED_NTFY_TOPIC";
const NTFY_TOKEN = "REDACTED_TOKEN";
const LINE_REPLY_URL = "https://api.line.me/v2/bot/message/reply";

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const url = new URL(request.url);

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

    // Process events (non-blocking: don't await all)
    const tasks = events.map((event) => handleEvent(event, env));
    await Promise.allSettled(tasks);

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
async function handleEvent(event, env) {
  if (event.type !== "message" || event.message?.type !== "text") {
    return;
  }

  const text = event.message.text;
  const userId = event.source?.userId ?? "unknown";
  const replyToken = event.replyToken;

  // Post to ntfy
  await postToNtfy(text, userId);

  // No auto-reply — darkninja replies manually via line_push.sh
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
