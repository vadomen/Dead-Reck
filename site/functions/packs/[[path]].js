// Serves road packs and their manifest from the R2 bucket bound as PACKS.
//   GET/HEAD /packs/manifest.json          -> R2 key packs/manifest.json
//   GET/HEAD /packs/v1/<name>-<hash>.roadpack
// Supports Range (resumable downloads) and If-None-Match / If-Match.
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
