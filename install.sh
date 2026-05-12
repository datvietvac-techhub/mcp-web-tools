#!/usr/bin/env bash
# install.sh — bootstrap the mcp-web-tool stack on a fresh machine.
#
#   git clone <repo> && cd mcp-web-tool && ./install.sh
#
# Bootstrap only — does NOT start containers. After this runs, use:
#   make up        # start the stack
#   make smoke     # verify endpoints
#   make install   # if you want the old one-shot (bootstrap + up + smoke)
#
# Idempotent: safe to re-run. It will
#   1. check prerequisites (docker, docker compose v2, daemon reachable, free ports)
#   2. create .env from .env.example if missing
#   3. generate SEARXNG_SECRET if it's empty
#   4. optionally pull upstream images (--pull)
#
# Flags:
#   --pull         `docker compose pull` upstream images now
#   --skip-checks  skip the prerequisite checks (ports etc.)
#   -h, --help     show this help

set -euo pipefail

# ── locate repo root (this script's directory) ────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

# ── pretty output ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=; DIM=; RED=; GRN=; YLW=; CYN=; RST=
fi
info()  { printf '%s\n' "${DIM}  $*${RST}"; }
step()  { printf '\n%s\n' "${BOLD}${CYN}▸ $*${RST}"; }
ok()    { printf '%s\n' "${GRN}  ✓ $*${RST}"; }
warn()  { printf '%s\n' "${YLW}  ⚠ $*${RST}"; }
die()   { printf '%s\n' "${RED}  ✗ $*${RST}" >&2; exit 1; }

# ── args ──────────────────────────────────────────────────────────────────────
DO_PULL=0 DO_CHECKS=1
for arg in "$@"; do
  case "$arg" in
    --pull)        DO_PULL=1 ;;
    --skip-checks) DO_CHECKS=0 ;;
    -h|--help)
      # print the leading comment block (skip the shebang, stop at first code line)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    *) die "unknown flag: $arg (try --help)" ;;
  esac
done

# ── compose wrapper (v2 plugin only) ──────────────────────────────────────────
export COMPOSE_BAKE=false   # silence the "configured to build using Bake" notice
compose() { docker compose "$@"; }

# ── 1. prerequisites ──────────────────────────────────────────────────────────
step "Checking prerequisites"

command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine: https://docs.docker.com/engine/install/"
ok "docker: $(docker --version | sed 's/^Docker version //')"

if ! docker compose version >/dev/null 2>&1; then
  die "'docker compose' (v2 plugin) not found. Install the Compose plugin: https://docs.docker.com/compose/install/"
fi
ok "compose: $(docker compose version --short 2>/dev/null || docker compose version | head -1)"

docker_err="$(docker info 2>&1 1>/dev/null || true)"
if ! docker info >/dev/null 2>&1; then
  case "$docker_err" in
    *[Pp]ermission\ denied*)
      die "Cannot talk to the Docker daemon (permission denied).
       Either re-run as root:               sudo ./install.sh
       or add yourself to the docker group: sudo usermod -aG docker \"\$USER\" && newgrp docker" ;;
    *)
      die "Cannot talk to the Docker daemon — is it running?  (try: sudo systemctl start docker)" ;;
  esac
fi
ok "docker daemon reachable"

command -v openssl >/dev/null 2>&1 || warn "openssl not found — will fall back to python3/urandom for secret generation"

if [ "$DO_CHECKS" -eq 1 ]; then
  port_busy() {
    # returns 0 if something is listening on $1
    if command -v ss >/dev/null 2>&1;       then ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q ":$1 "
    elif command -v lsof >/dev/null 2>&1;   then lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else return 1; fi
  }
  for p in 8080 11235 8000; do
    if port_busy "$p"; then
      # ours is fine — only complain about foreign listeners
      if docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":$p->"; then
        info "port $p in use by this stack already (ok)"
      else
        warn "port $p is already in use by another process — the stack may fail to bind it"
      fi
    fi
  done
fi

# ── 2. .env ───────────────────────────────────────────────────────────────────
step "Configuring .env"
if [ ! -f .env ]; then
  cp .env.example .env
  ok "created .env from .env.example"
else
  info ".env already exists — leaving it as is"
fi

# ── 3. SEARXNG_SECRET ─────────────────────────────────────────────────────────
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import secrets;print(secrets.token_hex(32))'
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
current_secret="$(grep -E '^SEARXNG_SECRET=' .env | head -1 | cut -d= -f2- || true)"
if [ -z "$current_secret" ]; then
  secret="$(gen_secret)"
  # portable in-place edit
  tmp="$(mktemp)"; awk -v s="$secret" '/^SEARXNG_SECRET=/{print "SEARXNG_SECRET=" s; next} {print}' .env > "$tmp" && mv "$tmp" .env
  grep -qE '^SEARXNG_SECRET=' .env || printf 'SEARXNG_SECRET=%s\n' "$secret" >> .env
  ok "generated SEARXNG_SECRET (32 random bytes, hex)"
else
  ok "SEARXNG_SECRET already set"
fi

# ── 4. optional image pull ────────────────────────────────────────────────────
if [ "$DO_PULL" -eq 1 ]; then
  step "Pulling upstream images"
  compose pull valkey searxng crawl4ai
fi

# ── done ──────────────────────────────────────────────────────────────────────
mcp_port="$(grep -E '^MCP_PORT=' .env | cut -d= -f2- || echo 8000)"
play_port="$(grep -E '^PLAYGROUND_PORT=' .env | cut -d= -f2- || echo 8001)"
printf '\n%s\n' "${BOLD}${GRN}✔ bootstrap complete${RST}"
cat <<EOF

  ${BOLD}Next${RST}
    make up           # start the stack
    make smoke        # verify endpoints
    make playground   # launch the FastAPI dev API on :${play_port:-8001}

  ${BOLD}Endpoints (once up)${RST}
    SearXNG    http://localhost:8080
    Crawl4AI   http://localhost:11235   (playground: /playground)
    MCP        http://localhost:${mcp_port:-8000}/mcp

EOF
exit 0
