---
title: Configuration — MCP Web Tools
description: Full configuration reference for MCP Web Tools — every .env variable, complete parameter tables for the web_search and web_extractor MCP tools, and the FastAPI dev playground.
---

# Configuration

Everything is set via `.env` (see [`.env.example`](https://github.com/datvietvac-techhub/mcp-web-tools/blob/main/.env.example)).

## Environment variables

| var | default | purpose |
|---|---|---|
| `SEARXNG_SECRET` | _(required)_ | HMAC signing key for SearXNG — **not** an API key |
| `CRAWL4AI_API_TOKEN` | _(empty)_ | optional bearer token if Crawl4AI is locked down |
| `MCP_TRANSPORT` | `http` | `http` (streamable-http) or `stdio` (subprocess) |
| `MCP_PORT` | `8000` | host port for the MCP server (also used for `make smoke`) |
| `PLAYGROUND_PORT` | `8001` | host port for `make playground` |
| `MCP_CACHE_TTL` | `300` | `web_search` cache TTL in seconds (`0` disables) |
| `EXTRACT_CACHE_TTL` | `1800` | `web_extractor` cache TTL in seconds (`0` disables) |
| `REQUEST_TIMEOUT` | `30` | SearXNG request timeout (s) |
| `EXTRACT_TIMEOUT` | `60` | Crawl4AI request timeout (s) |
| `MAX_CONCURRENCY` | `5` | parallel Crawl4AI requests per `web_extractor` call |
| `VALKEY_IMAGE` | `valkey/valkey:8-alpine` | pin Valkey image |
| `SEARXNG_IMAGE` | `searxng/searxng:latest` | pin SearXNG image |
| `CRAWL4AI_IMAGE` | `unclecode/crawl4ai:latest` | pin Crawl4AI image (recommended for prod) |

After changing `MCP_PORT`, run `make restart` (not just `up`) so the new host-port mapping takes effect.

`SEARXNG_SECRET` is **not** an API key — nothing sends it. SearXNG uses it server-side to sign image-proxy URLs (HMAC) and internal tokens; it just needs to be random and stable. `install.sh` generates it; the SearXNG container won't start without one.

Search quality is tuned in [`searxng/settings.yml`](https://github.com/datvietvac-techhub/mcp-web-tools/blob/main/searxng/settings.yml) (engines enabled, weights, categories) — restart the `searxng` service after editing.

## MCP tools

Tool implementations live in [`mcp/tools.py`](https://github.com/datvietvac-techhub/mcp-web-tools/blob/main/mcp/tools.py) and are shared with the dev playground.

### `web_search`

Queries the self-hosted SearXNG instance and returns ranked, de-duplicated results. Cached in-process for `MCP_CACHE_TTL` seconds. On failure the dict includes an `"error"` key and `"results": []`.

| param | type | default | notes |
|---|---|---|---|
| `query` | string | required | search query |
| `num_results` | int | `10` | clamped to `1..50` |
| `categories` | string | `"general"` | SearXNG category: `general`, `news`, `science`, `it`, `images`, … |
| `language` | string | `"auto"` | `"en"`, `"vi"`, …; `"auto"` lets SearXNG decide |
| `time_range` | string \| null | `null` | `"day"`, `"week"`, `"month"`, `"year"` |

Returns:

```json
{
  "query": "...",
  "results": [
    { "title": "...", "url": "https://...", "snippet": "...", "engine": "...", "score": 1.0 }
  ],
  "answers": [],
  "suggestions": ["..."],
  "number_of_results": 12345
}
```

Results are de-duplicated by normalized URL and truncated to `num_results`.

### `web_extractor`

Fetches one or more URLs via Crawl4AI and returns clean Markdown. URLs are fetched in parallel up to `MAX_CONCURRENCY`, max 20 per call. Cached for `EXTRACT_CACHE_TTL` seconds.

| param | type | default | notes |
|---|---|---|---|
| `urls` | string \| list[string] | required | one URL or a list — max **20** per call |
| `mode` | string | `"fit"` | `fit` (pruned main content), `raw` (full page), `bm25` / `llm` (relevance-filtered — requires `query`) |
| `query` | string \| null | `null` | focus query for `bm25` / `llm` mode |
| `bypass_cache` | bool | `false` | skip the local cache and ask Crawl4AI to re-fetch |

Returns:

```json
{
  "results": [
    {
      "url": "https://...",
      "status": "ok",
      "markdown": "# Heading\n...",
      "word_count": 1234,
      "error": "..."
    }
  ]
}
```

Order matches the input URL list. Per-URL failures surface as `{"status": "error", "error": "...", "markdown": ""}` without aborting the whole call. URLs must use `http` or `https`; `bm25` and `llm` mode return a per-URL error when `query` is missing.

The URL policy currently performs lightweight validation only. Crawl4AI's domain/link filters are useful for crawl behavior, but they are not treated as this project's SSRF protection boundary. If you expose the MCP server beyond a trusted local network, put it behind access control and add any deployment-specific URL restrictions in `mcp/url_policy.py`.

## Dev playground (FastAPI)

Useful for poking the tools from `curl` without wiring up an MCP client. Not in `docker-compose.yml` — run on demand as a one-shot container off the existing `web-mcp` image (the main stack must already be up).

```bash
make up           # if not already running
make playground   # alias: make play
```

Listens on `http://localhost:${PLAYGROUND_PORT}` (default `8001`). Ctrl-C stops it; container is removed automatically.

| method | path | body | description |
|---|---|---|---|
| GET | `/healthz` | — | liveness probe → `{"ok": true}` |
| POST | `/search` | `SearchReq` | calls `web_search_impl`, same shape as the MCP tool |
| POST | `/extract` | `ExtractReq` | calls `web_extractor_impl`, same shape as the MCP tool |

Bodies mirror the tool signatures one-for-one. Swagger UI is auto-generated at `/docs`, ReDoc at `/redoc`.

!!! warning "Dev-only"
    No auth, verbose errors, accepts arbitrary URLs. Don't expose `PLAYGROUND_PORT` publicly.
