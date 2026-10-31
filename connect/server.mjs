import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { parseUserReference } from "@withone/connect/server";

loadEnv({ path: join(dirname(fileURLToPath(import.meta.url)), "..", ".env") });

const PORT = Number(process.env.CONNECT_PORT || 8788);
const SCORIA = (process.env.SCORIA_API_URL || "http://127.0.0.1:8080").replace(/\/$/, "");
const INTERNAL = process.env.SCORIA_INTERNAL_SECRET || "";
const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "public", "index.html"), "utf8");

const PERSON = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function cookiePath() {
  try {
    const path = new URL(process.env.ONE_REDIRECT_URI).pathname.replace(/\/[^/]*$/, "");
    return path || "/";
  } catch {
    return "/one";
  }
}

function readCookie(req, name) {
  const header = req.headers.cookie || "";
  for (const part of header.split(";")) {
    const [rawName, ...rest] = part.trim().split("=");
    if (rawName === name) return decodeURIComponent(rest.join("="));
  }
  return "";
}

function personId(req) {
  const url = new URL(req.url, "http://local");
  const fromQuery = url.searchParams.get("person") || "";
  if (PERSON.test(fromQuery)) return fromQuery;
  const fromCookie = readCookie(req, "maia_person");
  if (PERSON.test(fromCookie)) return fromCookie;
  const fromHeader = req.headers["x-scoria-person"] || "";
  return PERSON.test(fromHeader) ? fromHeader : null;
}

async function postGrant(person, reference, connections) {
  const parsed = reference ? parseUserReference(reference) : null;
  if (!reference) return;
  const body = {
    person_id: person,
    reference,
    one_user_id: reference,
    space_id: parsed?.organizationId || parsed?.projectId || null,
  };
  if (connections) {
    body.platforms = [...new Set(connections.map((row) => row.platform).filter(Boolean))];
    body.connections = connections.map((row) => ({
      platform: row.platform,
      key: row.key,
      name: row.name || row.title || row.platform,
      access: row.access ?? null,
    }));
  }
  const r = await fetch(`${SCORIA}/internal/one/grant`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-maia-internal": INTERNAL },
    body: JSON.stringify(body),
  });
  if (!r.ok) console.warn("One grant save:", r.status, await r.text());
}

const userStore = {
  async saveUser(appUserId, reference) {
    await postGrant(appUserId, reference, null);
  },
  async loadUser(appUserId) {
    const r = await fetch(`${SCORIA}/internal/one/grant`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-maia-internal": INTERNAL },
      body: JSON.stringify({ person_id: appUserId, lookup: true }),
    });
    if (!r.ok) return null;
    const row = await r.json();
    if (!row || row.revoked_at) return null;
    if (typeof row.reference === "string" && row.reference) return row.reference;
    if (typeof row.one_user_id === "string" && row.one_user_id.startsWith("cu_")) {
      return row.one_user_id;
    }
    return null;
  },
  async clearUser(appUserId) {
    await fetch(`${SCORIA}/internal/one/grant`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-maia-internal": INTERNAL },
      body: JSON.stringify({ person_id: appUserId, revoked: true }),
    });
  },
};

let connect;
let handlers;
try {
  const mod = await import("@withone/connect/server");
  const handlersMod = await import("@withone/connect/node");
  if (process.env.ONE_CLIENT_ID && process.env.ONE_CONNECT_KEY) {
    const redirectUri = process.env.ONE_REDIRECT_URI || "http://127.0.0.1:8090/one/callback";
    process.env.ONE_REDIRECT_URI = redirectUri;
    connect = mod.createOneConnect({
      clientId: process.env.ONE_CLIENT_ID,
      clientSecret: process.env.ONE_CLIENT_SECRET,
      redirectUri,
      permissionSet: process.env.ONE_PERMISSION_SET || undefined,
      connectKey: process.env.ONE_CONNECT_KEY,
      returnTo: "/one/done",
      userStore,
    });
    handlers = handlersMod.createOneConnectHandlers(connect, {
      identifyUser: (req) => personId(req),
      onComplete: async ({ userId, result }) => {
        if (result.outcome !== "connected") return;
        const rows = await connect.listConnections(userId);
        const reference = await userStore.loadUser(userId);
        if (reference) await postGrant(userId, reference, rows);
      },
    });
  }
} catch (err) {
  console.warn("One Connect SDK not configured:", err.message);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  if (url.pathname === "/" || url.pathname === "/index.html") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(html);
    return;
  }
  if (url.pathname === "/api/one/connections" && req.method === "GET") {
    if (!connect) {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "one_unconfigured", accounts: [] }));
      return;
    }
    const person = url.searchParams.get("person");
    if (!person) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "person required" }));
      return;
    }
    try {
      const rows = await connect.listConnections(person);
      const reference = await userStore.loadUser(person);
      if (reference) await postGrant(person, reference, rows);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        accounts: rows.map((row) => ({
          platform: row.platform,
          key: row.key,
          name: row.name || row.title || row.platform,
          access: row.access ?? null,
        })),
      }));
    } catch (err) {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: err.message || "list failed" }));
    }
    return;
  }
  if (url.pathname === "/api/one/pull" && req.method === "POST") {
    if (!connect) {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "one_unconfigured" }));
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString() || "{}");
    const person = body.person;
    const platform = body.platform;
    if (!person || !platform) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "person and platform required" }));
      return;
    }
    try {
      const rows = await connect.listConnections(person);
      const conn = rows.find((row) => row.platform === platform);
      if (!conn) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: `no grant for ${platform}` }));
        return;
      }
      const intent = body.intent || "list recent records";
      const actions = await connect.searchActions(person, platform, intent);
      const action = actions[0];
      if (!action) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: `no action for ${platform}` }));
        return;
      }
      let reply;
      let last = actions[0];
      for (const candidate of actions.slice(0, 3)) {
        last = candidate;
        reply = await connect.runAction(person, {
          connectionKey: conn.key,
          actionId: candidate._id,
        });
        if (reply.ok) break;
        if (reply.blockedByGrant || reply.refusal === "grant") break;
      }
      if (reply?.refusal === "reconnect_required" || /reconnect_required/.test(String(reply?.data ?? ""))) {
        res.writeHead(409, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "reconnect_required", action: last?._id }));
        return;
      }
      res.writeHead(reply.ok ? 200 : reply.status || 502, {
        "content-type": "application/json",
      });
      res.end(JSON.stringify(reply.data ?? { blocked: reply.blockedByGrant }));
    } catch (err) {
      const message = err.message || "pull failed";
      const reconnect = err.code === "reconnect_required" || /reconnect_required/.test(message);
      res.writeHead(reconnect ? 409 : 502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: reconnect ? "reconnect_required" : message }));
    }
    return;
  }
  if (url.pathname.startsWith("/api/one/")) {
    if (handlers) {
      const action = url.pathname.split("/").pop();
      req.url = url.pathname + url.search;
      if (action === "authorize") {
        const person = url.searchParams.get("person");
        if (person && PERSON.test(person)) {
          const extra = `maia_person=${encodeURIComponent(person)}; Path=${cookiePath()}; Max-Age=1800; HttpOnly; SameSite=Lax`;
          const orig = res.setHeader;
          res.setHeader = function setHeader(name, value) {
            if (String(name).toLowerCase() === "set-cookie") {
              const list = Array.isArray(value) ? value.slice() : [value];
              list.push(extra);
              return orig.call(this, name, list);
            }
            return orig.call(this, name, value);
          };
        }
      }
      if (typeof handlers === "function") {
        return handlers(req, res);
      }
      const fn = handlers[action] || handlers.GET || handlers.handle;
      if (fn) return fn(req, res);
    }
    res.writeHead(503, { "content-type": "text/html; charset=utf-8" });
    res.end(`<!doctype html><meta charset="utf-8"><title>One Connect</title>
<body style="font:16px/1.4 system-ui;max-width:36rem;margin:3rem auto">
<h1>One is not configured</h1>
<p>This Maia has no <code>ONE_CLIENT_ID</code> / <code>ONE_CONNECT_KEY</code> yet, so there is nothing to authorize.</p>
<p>From <code>connect/</code>, run <code>one connect create</code>, approve Maia in the browser, and put the client secret and connect key in <code>.env</code>. Then restart Connect.</p>
</body>`);
    return;
  }
  if (url.pathname === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, connect: Boolean(connect) }));
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`one-connect on :${PORT} (sdk=${Boolean(connect)})`);
});
