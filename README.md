# mcp-web-tool

A single `docker compose` stack that gives AI agents two web tools over MCP:

- **`web_search`** — web search via a self-hosted [SearXNG](https://docs.searxng.org/) metasearch instance (no third-party API keys).
- **`web_extractor`** — fetch one or more URLs and return clean Markdown via [Crawl4AI](https://docs.crawl4ai.com/) (headless-browser crawler).

The MCP server is a thin [FastMCP](https://github.com/jlowin/fastmcp) wrapper that calls SearXNG and Crawl4AI over the internal Docker network, normalizes their output, and adds a small TTL cache on top of each service's own caching.

## Architecture

```
docker-compose.yml  (network: web-tool-net)
  valkey     valkey/valkey:8-alpine                  cache / limiter backend for SearXNG
  searxng    searxng/searxng        :8080            metasearch, JSON API enabled
  crawl4ai   unclecode/crawl4ai     :11235           REST crawler (/md, /crawl), shm_size 1g
  web-mcp    build ./mcp           :${MCP_PORT:-8000}  MCP server — tools: web_search, web_extractor

on-demand (make playground, not in compose):
  playground = same image, runs FastAPI on :${PLAYGROUND_PORT:-8001}
               POST /search, POST /extract — wraps the same tool impls
```

## Install

**Requirements on the target machine:** Docker Engine + the `docker compose` v2 plugin. That's it — everything else runs in containers.

```bash
git clone <this-repo> mcp-web-tool
cd mcp-web-tool
./install.sh        # bootstrap: prereq checks, .env, SEARXNG_SECRET — does NOT start containers
make up             # start the stack
make smoke          # verify endpoints
```

`install.sh` is **bootstrap-only** and idempotent (safe to re-run). It checks prerequisites, creates `.env` from `.env.example`, and generates `SEARXNG_SECRET`. It does not run `compose up` — that's `make up`. First `make up` pulls the Crawl4AI image (~GB, includes Chromium) — budget a couple of minutes.

Prefer a single command? `make install` runs bootstrap + `compose up -d --build` + smoke in one go.

Flags on `install.sh`: `--pull` (pull upstream images now), `--skip-checks`, `--help`.

If `docker` needs `sudo` on your box, run `sudo ./install.sh` (or add yourself to the `docker` group: `sudo usermod -aG docker "$USER" && newgrp docker`).

### Day-to-day (`make`)

```
make bootstrap  # ./install.sh only (prereqs, .env, secret) — no compose up
make install    # one-shot: bootstrap + up + smoke (forward flags with ARGS="--pull")
make up         # start              make down       # stop (keeps cache volume)
make restart    # restart            make ps         # status
make logs       # tail logs          make smoke      # re-run endpoint smoke tests
make build      # rebuild web-mcp    make pull       # refresh upstream images
make playground # run the FastAPI dev API (alias: make play)
make secret     # print a fresh SEARXNG_SECRET value
make clean      # stop + remove the valkey cache volume
```

### Manual install (no script)

```bash
cp .env.example .env
echo "SEARXNG_SECRET=$(openssl rand -hex 32)" >> .env   # or edit .env by hand
docker compose up -d --build
docker compose ps        # wait until searxng + crawl4ai are "healthy"
```

## Smoke tests

```bash
# SearXNG JSON API
curl -s "http://localhost:8080/search?q=anthropic+claude&format=json" | jq '.results[0]'

# Crawl4AI markdown endpoint
curl -s -X POST http://localhost:11235/md \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","f":"fit"}' | jq '.markdown'

# MCP server: inspect tools
npx @modelcontextprotocol/inspector       # then connect to http://localhost:${MCP_PORT:-8000}/mcp
```

## Connecting an agent

The MCP server listens on **`http://<host>:${MCP_PORT}/mcp`** (Streamable HTTP) by default — `MCP_PORT` defaults to `8000`.

Claude Code:

```bash
claude mcp add --transport http web-tool http://localhost:8000/mcp
```

Any MCP client config (Hermes, etc.):

```json
{
  "mcpServers": {
    "web-tool": { "transport": "http", "url": "http://localhost:8000/mcp" }
  }
}
```

To run the MCP server over stdio instead (single local client launches it as a subprocess), set `MCP_TRANSPORT=stdio` in `.env`. In that mode you typically don't expose port 8000; point the client at `python mcp/server.py` (or `docker compose run`).

## MCP tools

The server exposes two tools at `http://<host>:${MCP_PORT}/mcp`. Implementations live in `mcp/tools.py` and are shared with the dev playground below.

### `web_search`

Search the web via the self-hosted SearXNG instance.

| param | type | default | notes |
|---|---|---|---|
| `query` | string | required | search query |
| `num_results` | int | `10` | clamped to `1..50` |
| `categories` | string | `"general"` | SearXNG category: `general`, `news`, `science`, `it`, `images`, … |
| `language` | string | `"auto"` | `"en"`, `"vi"`, …; `"auto"` lets SearXNG decide |
| `time_range` | string \| null | `null` | `"day"`, `"week"`, `"month"`, `"year"` |

**Returns**

```json
{
  "query": "...",
  "results": [
    { "title": "...", "url": "https://...", "snippet": "...", "engine": "...", "score": 1.0 }
  ],
  "answers": [...],
  "suggestions": ["...", "..."],
  "number_of_results": 12345
}
```

Results are de-duplicated by normalized URL and truncated to `num_results`. Cached in-process for `MCP_CACHE_TTL` seconds (default `300`). On failure the dict includes an `"error"` key and `"results": []`.

### `web_extractor`

Fetch one or more URLs through Crawl4AI and return clean Markdown.

| param | type | default | notes |
|---|---|---|---|
| `urls` | string \| list[string] | required | one URL or a list — max **20** per call |
| `mode` | string | `"fit"` | `fit` (pruned main content), `raw` (full page), `bm25` / `llm` (relevance-filtered — requires `query`) |
| `query` | string \| null | `null` | focus query for `bm25` / `llm` mode |
| `bypass_cache` | bool | `false` | skip the local cache and ask Crawl4AI to re-fetch |

**Returns**

```json
{
  "results": [
    {
      "url": "https://...",
      "status": "ok",          // "ok" | "empty" | "error"
      "markdown": "# Heading\n...",
      "word_count": 1234,
      "error": "..."            // only on status=error
    }
  ]
}
```

Order matches the input URL list. URLs are fetched in parallel up to `MAX_CONCURRENCY` (default 5). Cached for `EXTRACT_CACHE_TTL` seconds (default `1800`).

## Dev playground (FastAPI)

Useful when you want to poke `web_search` / `web_extractor` results from `curl` without wiring up an MCP client. The playground is a thin FastAPI app that imports the same impls from `mcp/tools.py`, so it always matches the MCP server's behavior.

**Not in `docker-compose.yml`** — it's run on demand as a one-shot container off the existing `web-mcp` image. The main stack must already be up (it talks to `searxng` and `crawl4ai` over the compose network).

```bash
make up           # if not already running
make playground   # alias: make play
```

Listens on `http://localhost:${PLAYGROUND_PORT}` (default `8001`). Ctrl-C stops it; container is removed automatically (`--rm`).

### Endpoints

| method | path | body | description |
|---|---|---|---|
| GET | `/healthz` | — | liveness probe → `{"ok": true}` |
| POST | `/search` | `SearchReq` | calls `web_search_impl` and returns the same shape as the MCP tool |
| POST | `/extract` | `ExtractReq` | calls `web_extractor_impl` and returns the same shape as the MCP tool |

Bodies mirror the tool signatures one-for-one (all optional params have the same defaults):

```jsonc
// POST /search
{ "query": "anthropic claude", "num_results": 5, "categories": "general",
  "language": "auto", "time_range": "week" }

// POST /extract
{ "urls": ["https://example.com", "https://anthropic.com"],
  "mode": "fit", "query": null, "bypass_cache": false }
```

### Quick examples

```bash
# health
curl -s http://localhost:8001/healthz
# → {"ok":true}

# search
curl -s -X POST http://localhost:8001/search \
  -H 'content-type: application/json' \
  -d '{"query":"hello world","num_results":3}' | jq '.results[0].title'

# extract a single URL
curl -s -X POST http://localhost:8001/extract \
  -H 'content-type: application/json' \
  -d '{"urls":"https://example.com"}' | jq '.results[0].markdown' | head -5

# extract multiple URLs in parallel
curl -s -X POST http://localhost:8001/extract \
  -H 'content-type: application/json' \
  -d '{"urls":["https://example.com","https://anthropic.com"],"mode":"fit"}' \
  | jq '.results[] | {url, status, word_count}'
```

FastAPI also auto-generates Swagger UI at `http://localhost:8001/docs` and a ReDoc view at `http://localhost:8001/redoc`.

> **Dev-only.** No auth, verbose errors, accepts arbitrary URLs. Don't expose `PLAYGROUND_PORT` publicly.

## Configuration

Everything is set via `.env` (see `.env.example`):

| var | default | purpose |
|---|---|---|
| `SEARXNG_SECRET` | _(required)_ | HMAC signing key for SearXNG — not an API key |
| `CRAWL4AI_API_TOKEN` | _(empty)_ | optional bearer token if Crawl4AI is locked down |
| `MCP_TRANSPORT` | `http` | `http` (streamable-http) or `stdio` (subprocess) |
| `MCP_PORT` | `8000` | host port for the MCP server (also used for `make smoke`) |
| `PLAYGROUND_PORT` | `8001` | host port for `make playground` |
| `MCP_CACHE_TTL` | `300` | `web_search` cache TTL in seconds (`0` disables) |
| `EXTRACT_CACHE_TTL` | `1800` | `web_extractor` cache TTL in seconds (`0` disables) |
| `REQUEST_TIMEOUT` | `30` | SearXNG request timeout (s) |
| `EXTRACT_TIMEOUT` | `60` | Crawl4AI request timeout (s) |
| `MAX_CONCURRENCY` | `5` | parallel Crawl4AI requests per `web_extractor` call |
| `VALKEY_IMAGE` / `SEARXNG_IMAGE` / `CRAWL4AI_IMAGE` | `:latest` | pin image versions for reproducible installs |

After changing `MCP_PORT`, run `make restart` (not just `up`) so the new host-port mapping takes effect.

`SEARXNG_SECRET` is **not** an API key — nothing sends it. SearXNG uses it server-side to sign image-proxy URLs (HMAC) and internal tokens; it just needs to be random and stable. `install.sh` generates it; the SearXNG container won't start without one.

Search quality is tuned in `searxng/settings.yml` (which engines are enabled, weights, categories) — restart the `searxng` service after editing. Pinning `CRAWL4AI_IMAGE` to a specific version is recommended in production — its `/md` request shape has shifted between releases.

## Notes / gotchas

- **SearXNG JSON API must be enabled** — `searxng/settings.yml` already lists `json` under `search.formats`. Without it the API returns `403`.
- **`SEARXNG_SECRET` is required** — the SearXNG container fails to start without it. The compose file errors out early if it's unset; `install.sh` generates it.
- **Limiter is disabled** (`limiter: false`) because the instance is only reachable inside the compose network. Enable and configure it if you ever expose port 8080 publicly.
- **Pin the Crawl4AI image** in production — set `CRAWL4AI_IMAGE=unclecode/crawl4ai:<version>` in `.env`; its API has changed between releases. If `web_extractor` ever returns empty markdown, check `http://localhost:11235/playground` to see the current `/md` request shape.
- **`shm_size: 1g`** on the `crawl4ai` service avoids Chromium crashes on large pages.

## Stopping

```bash
docker compose down            # keep the Valkey volume
docker compose down -v         # also remove cached data
```
