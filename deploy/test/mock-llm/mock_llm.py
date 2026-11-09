"""A tiny OpenAI-compatible endpoint for smoke-testing the deployment plumbing.

It is not a model. It exists so the whole chain -- Open WebUI -> Hermes ->
upstream LLM -- can be exercised on a cluster that has no real model, and so a
broken URL, key or trust bundle shows up before a paid endpoint is involved.

Behaviour:
  GET  /v1/models            lists one model (MOCK_MODEL), with a context window
  POST /v1/chat/completions  replies to the last user message, streaming or not
       - "Reply with exactly: X"  -> replies "X"
       - anything else            -> "mock-llm received: <first 200 chars>"
  GET  /healthz              liveness

If MOCK_API_KEY is set, every /v1 request must carry "Authorization: Bearer
<MOCK_API_KEY>" or gets a 401 -- which is what proves Hermes is sending its key.

Standard library only, so it runs on a stock UBI Python image with no build.
"""

import json
import os
import re
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = os.environ.get("MOCK_MODEL", "mock-model")
API_KEY = os.environ.get("MOCK_API_KEY", "")
PORT = int(os.environ.get("PORT", "8000"))
CONTEXT = int(os.environ.get("MOCK_CONTEXT_LENGTH", "131072"))
EXACT = re.compile(r"Reply with exactly:\s*(.+)", re.IGNORECASE | re.DOTALL)


def text_of(content):
    """Message content may be a string or a list of typed parts."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def reply_for(messages):
    last = next((text_of(m.get("content")) for m in reversed(messages)
                 if m.get("role") == "user"), "")
    match = EXACT.search(last)
    if match:
        return match.group(1).strip().splitlines()[0].strip()
    snippet = " ".join(last.split())[:200]
    return f"mock-llm received: {snippet}"


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-llm/1"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        if not API_KEY:
            return True
        if self.headers.get("Authorization", "") == f"Bearer {API_KEY}":
            return True
        self._json(401, {"error": {"message": "invalid API key", "type": "invalid_request_error"}})
        return False

    def do_GET(self):
        if self.path == "/healthz":
            return self._json(200, {"status": "ok"})
        if self.path.rstrip("/") == "/v1/models":
            if not self._authorized():
                return None
            return self._json(200, {"object": "list", "data": [{
                "id": MODEL, "object": "model", "owned_by": "mock-llm",
                "created": int(time.time()), "context_length": CONTEXT,
            }]})
        return self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._json(404, {"error": {"message": "not found"}})
        if not self._authorized():
            return None
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": {"message": "invalid JSON"}})

        text = reply_for(body.get("messages") or [])
        cid = f"chatcmpl-mock-{uuid.uuid4().hex[:12]}"
        created = int(time.time())
        usage = {"prompt_tokens": 1, "completion_tokens": len(text.split()),
                 "total_tokens": 1 + len(text.split())}

        if not body.get("stream"):
            return self._json(200, {
                "id": cid, "object": "chat.completion", "created": created, "model": MODEL,
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": text}}],
                "usage": usage,
            })

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def chunk(delta, finish=None, extra=None):
            payload = {"id": cid, "object": "chat.completion.chunk", "created": created,
                       "model": MODEL,
                       "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if extra:
                payload.update(extra)
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        chunk({"role": "assistant", "content": ""})
        for i, word in enumerate(text.split(" ")):
            chunk({"content": word if i == 0 else " " + word})
        chunk({}, finish="stop")
        if (body.get("stream_options") or {}).get("include_usage"):
            self.wfile.write(f"data: {json.dumps({'id': cid, 'object': 'chat.completion.chunk', 'created': created, 'model': MODEL, 'choices': [], 'usage': usage})}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        return None


if __name__ == "__main__":
    print(f"mock-llm serving model '{MODEL}' on :{PORT} (auth {'on' if API_KEY else 'off'})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
