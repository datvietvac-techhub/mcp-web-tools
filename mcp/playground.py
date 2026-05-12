"""Dev-only FastAPI playground for quickly testing web_search / web_extractor.

Run via `make playground` (one-shot container off the existing mcp image) and
hit:
    curl -s http://localhost:8001/healthz
    curl -sX POST http://localhost:8001/search  -H 'content-type: application/json' \\
         -d '{"query":"hello","num_results":3}'
    curl -sX POST http://localhost:8001/extract -H 'content-type: application/json' \\
         -d '{"urls":"https://example.com"}'

Not exposed in production: it has no auth and is not wired into docker-compose.yml.
"""

import os

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel

from tools import web_extractor_impl, web_search_impl

app = FastAPI(title="web-tool playground", description="Dev API for web_search / web_extractor")


class SearchReq(BaseModel):
    query: str
    num_results: int = 10
    categories: str = "general"
    language: str = "auto"
    time_range: str | None = None


class ExtractReq(BaseModel):
    urls: str | list[str]
    mode: str = "fit"
    query: str | None = None
    bypass_cache: bool = False


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.post("/search")
async def search(req: SearchReq) -> dict:
    return await web_search_impl(**req.model_dump())


@app.post("/extract")
async def extract(req: ExtractReq) -> dict:
    return await web_extractor_impl(**req.model_dump())


if __name__ == "__main__":
    port = int(os.environ.get("PLAYGROUND_PORT", "8001"))
    uvicorn.run(app, host="0.0.0.0", port=port)
