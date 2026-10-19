// Serves road packs and their manifest from the R2 bucket bound as PACKS.
//   GET/HEAD /packs/manifest.json          -> R2 key packs/manifest.json
//   GET/HEAD /packs/v1/<name>-<hash>.roadpack
// Supports Range (resumable downloads) and If-None-Match / If-Match.
// A range starting at or beyond the size gets 416 with `Content-Range: bytes */<size>`
// (R2 throws on it, which used to surface as a 500).
// Only /packs/* runs this Function; every other path stays a free static asset.

const KEY_RE = /^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/;

export async function onRequest({ request, env, params }) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405, headers: { allow: "GET, HEAD" } });
  }
  const path = Array.isArray(params.path) ? params.path.join("/") : String(params.path || "");
  if (!KEY_RE.test(path) || path.split("/").some((s) => s === "." || s === "..")) {
    return new Response("Not Found", { status: 404 });
  }
  const key = "packs/" + path;
  if (!env.PACKS) {
    return new Response("R2 binding PACKS is not configured for this Pages project", { status: 503 });
  }

  if (request.method === "HEAD") {
    const head = await env.PACKS.head(key);
    if (!head) return new Response(null, { status: 404 });
    return new Response(null, { status: 200, headers: baseHeaders(head) });
  }

  // If-Range is ignored on purpose: pack keys are immutable (name + content hash), so a
  // range of a key always refers to the same bytes. The manifest is small and never resumed.
  const range = parseRange(request.headers.get("range"));
  if (range) {
    const head = await env.PACKS.head(key);
    if (!head) return new Response("Not Found", { status: 404 });
    if (!satisfiable(range, head.size)) {
      const headers = baseHeaders(head);
      headers.set("content-range", `bytes */${head.size}`);
      headers.set("content-length", "0");
      return new Response(null, { status: 416, headers });
    }
  }

  const object = await env.PACKS.get(key, { range: request.headers, onlyIf: request.headers });
  if (object === null) return new Response("Not Found", { status: 404 });

  const headers = baseHeaders(object);
  // Precondition not met: R2 returns metadata without a body.
  if (!("body" in object) || object.body === null) {
    const status = request.headers.has("if-none-match") ? 304 : 412;
    return new Response(null, { status, headers });
  }

  if (request.headers.has("range") && object.range) {
    const { offset, length } = resolveRange(object.range, object.size);
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}

function baseHeaders(object) {
  const h = new Headers();
  object.writeHttpMetadata(h); // content-type, cache-control set at upload
  h.set("etag", object.httpEtag);
  h.set("accept-ranges", "bytes");
  h.set("content-length", String(object.size));
  h.set("access-control-allow-origin", "*");
  return h;
}

function resolveRange(range, size) {
  if ("suffix" in range && range.suffix !== undefined) {
    const length = Math.min(range.suffix, size);
    return { offset: size - length, length };
  }
  const offset = range.offset ?? 0;
  const length = range.length ?? size - offset;
  return { offset, length };
}

// One `bytes=` range ("a-", "a-b" or "-n"); anything else (several ranges, other units)
// returns null and is left to R2, as before.
function parseRange(value) {
  const m = /^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$/i.exec(value || "");
  if (!m || (m[1] === "" && m[2] === "")) return null;
  if (m[1] === "") return { suffix: Number(m[2]) };
  return { start: Number(m[1]), end: m[2] === "" ? undefined : Number(m[2]) };
}

// RFC 9110 §14.1.2: a first-byte position at or past the size, or a zero-length suffix,
// cannot be satisfied. An end before the start is invalid; R2 refuses it too.
function satisfiable(range, size) {
  if ("suffix" in range) return range.suffix > 0 && size > 0;
  if (range.end !== undefined && range.end < range.start) return false;
  return range.start < size;
}
