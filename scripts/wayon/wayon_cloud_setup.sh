#!/usr/bin/env bash
# Wayon Cloud (Cloudflare Worker) 설정 스크립트 — 콤마 기기가 아니라 PC 에서 실행한다.
#
# docs/cloudflare-세팅.md 의 STEP 1~5 를 자동화한다.
#   터널 생성 + Private Network 등록 / D1 · KV 생성 / wrangler.toml 작성
#   스키마 적용 / 시크릿 4개 생성 및 등록 / 배포
#
# 사전 준비 (각 1회, 브라우저가 열린다):
#   npx wrangler login          # 반드시 OAuth 로그인. API 토큰으로는 VPC 배포가 안 된다
#   cloudflared tunnel login    # --no-tunnel 로 실행하면 생략 가능
#
# 사용:
#   ./wayon_cloud_setup.sh --dir <Wayon>/cloudflare/wayon-cloud
#   ./wayon_cloud_setup.sh --dir ... --no-tunnel   # 라이브뷰·원격SSH 포기, 설정이 훨씬 단순
#
# --no-tunnel 을 쓰면 [[vpc_networks]] 가 빠져서 문서가 경고한 배포 실패(code 10196)를
# 아예 만나지 않는다. 배터리·주차위치·주행기록·스냅샷은 그대로 동작하고
# 360 라이브뷰와 원격 SSH 만 빠진다. 나중에 터널을 붙이려면 다시 실행하면 된다.
#
# 생성한 시크릿은 Cloudflare 가 다시 보여주지 않으므로 wayon-secrets.txt 로 저장한다.
# 이 파일에는 토큰이 평문으로 들어 있다. 안전한 곳에 보관하고 저장소에 커밋하지 마라.

set -euo pipefail

worker_dir=""
worker_name="wayon-cloud"
tunnel_name="wayon-comma"
db_name="wayon_cloud"
kv_binding="WAYON_SNAPSHOTS"
use_tunnel=1
secrets_out="wayon-secrets.txt"

step_no=0

die()  { printf '\n오류: %s\n' "$*" >&2; exit 1; }
step() { step_no=$((step_no + 1)); printf '\n[%d] %s\n' "$step_no" "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [주의] %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)         worker_dir="${2:-}"; shift 2 ;;
    --name)        worker_name="${2:-}"; shift 2 ;;
    --tunnel-name) tunnel_name="${2:-}"; shift 2 ;;
    --no-tunnel)   use_tunnel=0; shift ;;
    -h|--help)     usage ;;
    *) die "알 수 없는 인자: $1  (--help 참고)" ;;
  esac
done

# ------------------------------------------------------------ 0. 사전 점검
step "사전 점검"

[ -n "$worker_dir" ] || die "--dir 로 wayon-cloud 디렉토리를 지정하라 (src/worker.js 가 있는 곳)"
[ -d "$worker_dir" ] || die "디렉토리가 없다: $worker_dir"
cd "$worker_dir"
[ -f src/worker.js ] || die "src/worker.js 가 없다. wayon-cloud 디렉토리가 맞는지 확인하라"
[ -f schema.sql ]    || die "schema.sql 이 없다"
ok "worker 디렉토리: $(pwd)"

command -v npx >/dev/null || die "npx 가 없다. Node.js 를 설치하라"
ok "npx 있음"

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  warn "CLOUDFLARE_API_TOKEN 이 설정돼 있다."
  if [ "$use_tunnel" -eq 1 ]; then
    die "VPC 바인딩이 있는 Worker 는 API 토큰으로 배포되지 않는다(code 10196).
     unset CLOUDFLARE_API_TOKEN 후 'npx wrangler login' 으로 다시 하라."
  fi
  warn "--no-tunnel 이라 진행은 하지만, 실패하면 unset 후 wrangler login 을 쓰라"
fi

if ! npx --yes wrangler whoami >/dev/null 2>&1; then
  die "wrangler 로그인이 안 돼 있다. 먼저 실행하라:  npx wrangler login"
fi
ok "wrangler 로그인 확인"

if [ "$use_tunnel" -eq 1 ]; then
  command -v cloudflared >/dev/null || die "cloudflared 가 없다. 설치하거나 --no-tunnel 로 실행하라"
  ok "cloudflared 있음"
fi

# ------------------------------------------------------- 유틸: ID 받아내기
# wrangler 출력 형식은 버전마다 달라진다. 자동 추출을 시도하고, 실패하면 직접 입력받는다.
extract_uuid() { grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1; }
extract_hex32() { grep -oE '[0-9a-f]{32}' | head -1; }

ask_value() {  # ask_value <설명> -> stdout
  local prompt="$1" value=""
  while [ -z "$value" ]; do
    printf '  %s: ' "$prompt" >&2
    read -r value
  done
  printf '%s' "$value"
}

# ------------------------------------------------------------- 1. 터널
tunnel_id=""
tunnel_token=""
if [ "$use_tunnel" -eq 1 ]; then
  step "Cloudflare 터널 준비 ($tunnel_name)"

  if cloudflared tunnel info "$tunnel_name" >/dev/null 2>&1; then
    ok "이미 있는 터널을 재사용한다"
  else
    info "터널 생성 중..."
    cloudflared tunnel create "$tunnel_name" >/tmp/wayon_tunnel_create.log 2>&1 \
      || { cat /tmp/wayon_tunnel_create.log; die "터널 생성 실패"; }
    ok "터널 생성"
  fi

  tunnel_id="$(cloudflared tunnel info "$tunnel_name" 2>/dev/null | extract_uuid || true)"
  [ -n "$tunnel_id" ] || tunnel_id="$(cloudflared tunnel list 2>/dev/null | grep -F "$tunnel_name" | extract_uuid || true)"
  [ -n "$tunnel_id" ] || tunnel_id="$(ask_value '터널 ID(UUID)를 붙여넣어라')"
  ok "터널 ID 확보"

  # Worker 가 다이얼할 사설 IP. 이걸 빼먹으면 대시보드는 되는데 라이브뷰만 실패한다.
  if cloudflared tunnel route ip add 172.31.255.254/32 "$tunnel_name" >/dev/null 2>&1; then
    ok "Private Network 172.31.255.254/32 등록"
  else
    warn "Private Network 등록 실패 (이미 등록됐을 수 있다). 대시보드에서 확인하라"
  fi

  tunnel_token="$(cloudflared tunnel token "$tunnel_name" 2>/dev/null | tr -d '\r\n ' || true)"
  [ -n "$tunnel_token" ] && ok "터널 토큰 확보" || warn "터널 토큰 자동 확보 실패. 대시보드에서 복사해야 한다"
fi

# ------------------------------------------------------------- 2. D1 / KV
step "D1 데이터베이스 준비 ($db_name)"
d1_out="$(npx --yes wrangler d1 create "$db_name" 2>&1 || true)"
if printf '%s' "$d1_out" | grep -qi "already exists"; then
  ok "이미 있는 DB 를 재사용한다"
  d1_out="$(npx --yes wrangler d1 list 2>&1 || true)"
fi
database_id="$(printf '%s' "$d1_out" | extract_uuid || true)"
[ -n "$database_id" ] || { printf '%s\n' "$d1_out"; database_id="$(ask_value 'database_id 를 붙여넣어라')"; }
ok "database_id 확보"

step "KV 네임스페이스 준비 ($kv_binding)"
kv_out="$(npx --yes wrangler kv namespace create "$kv_binding" 2>&1 || true)"
if printf '%s' "$kv_out" | grep -qi "already exists"; then
  ok "이미 있는 네임스페이스를 재사용한다"
  kv_out="$(npx --yes wrangler kv namespace list 2>&1 || true)"
fi
kv_id="$(printf '%s' "$kv_out" | extract_hex32 || true)"
[ -n "$kv_id" ] || { printf '%s\n' "$kv_out"; kv_id="$(ask_value 'KV namespace id 를 붙여넣어라')"; }
ok "KV id 확보"

# --------------------------------------------------------- 3. wrangler.toml
step "wrangler.toml 작성"
# 저장소에 커밋된 wrangler.toml 에는 원작자 계정의 ID 가 박혀 있고, 문서에 없는
# [[vpc_services]] 블록도 들어 있다. 부분 수정 대신 새로 만든다.
[ -f wrangler.toml ] && { cp -p wrangler.toml wrangler.toml.bak; info "기존 파일을 wrangler.toml.bak 으로 백업"; }

{
  printf 'name = "%s"\n' "$worker_name"
  printf 'main = "src/worker.js"\n'
  printf 'compatibility_date = "2026-05-14"\n'
  printf 'workers_dev = true\n\n'
  printf '[assets]\ndirectory = "./public"\nbinding = "ASSETS"\n'
  printf 'not_found_handling = "single-page-application"\nrun_worker_first = ["/api/*"]\n\n'
  printf '[[d1_databases]]\nbinding = "DB"\ndatabase_name = "%s"\ndatabase_id = "%s"\n\n' "$db_name" "$database_id"
  printf '[[kv_namespaces]]\nbinding = "SNAPSHOTS"\nid = "%s"\n' "$kv_id"
  if [ "$use_tunnel" -eq 1 ] && [ -n "$tunnel_id" ]; then
    printf '\n[[vpc_networks]]\nbinding = "COMMA_NETWORK"\ntunnel_id = "%s"\nremote = true\n' "$tunnel_id"
  fi
} > wrangler.toml
ok "작성 완료 ($([ "$use_tunnel" -eq 1 ] && echo 'VPC 바인딩 포함' || echo 'VPC 바인딩 없음'))"

# --------------------------------------------------------------- 4. 스키마
step "D1 스키마 적용 (--remote)"
npx --yes wrangler d1 execute "$db_name" --remote --file=./schema.sql \
  || die "스키마 적용 실패"
ok "schema.sql"
for m in migrations/*.sql; do
  [ -e "$m" ] || continue
  npx --yes wrangler d1 execute "$db_name" --remote --file="$m" || die "마이그레이션 실패: $m"
  ok "$(basename "$m")"
done

# -------------------------------------------------------------- 5. 시크릿
step "시크릿 생성 및 등록"
gen() { openssl rand -hex 32; }
UPLOAD_TOKEN="$(gen)"; VIEW_TOKEN="$(gen)"; LIVE_TOKEN="$(gen)"; SSH_SECRET="$(gen)"

put_secret() {  # put_secret <이름> <값>
  printf '%s' "$2" | npx --yes wrangler secret put "$1" >/dev/null 2>&1 \
    && ok "$1" || die "$1 등록 실패"
}
put_secret WAYON_UPLOAD_TOKEN       "$UPLOAD_TOKEN"
put_secret WAYON_VIEW_TOKEN         "$VIEW_TOKEN"
put_secret WAYON_LIVE_TOKEN         "$LIVE_TOKEN"
put_secret WAYON_SSH_SESSION_SECRET "$SSH_SECRET"

umask 077
{
  printf '# Wayon Cloud 시크릿 (Cloudflare 는 다시 보여주지 않는다. 안전하게 보관할 것)\n'
  printf '# 저장소에 커밋하지 마라.\n'
  printf 'WAYON_UPLOAD_TOKEN=%s\n' "$UPLOAD_TOKEN"
  printf 'WAYON_VIEW_TOKEN=%s\n'   "$VIEW_TOKEN"
  printf 'WAYON_LIVE_TOKEN=%s\n'   "$LIVE_TOKEN"
  printf 'WAYON_SSH_SESSION_SECRET=%s\n' "$SSH_SECRET"
  [ -n "$tunnel_token" ] && printf 'WAYON_TUNNEL_TOKEN=%s\n' "$tunnel_token"
} > "$secrets_out"
chmod 600 "$secrets_out"
ok "$secrets_out 에 저장 (권한 600)"

# --------------------------------------------------------------- 6. 배포
step "배포"
deploy_log="$(mktemp)"
if npx --yes wrangler deploy 2>&1 | tee "$deploy_log"; then
  ok "배포 완료"
else
  if grep -q "10196" "$deploy_log"; then
    die "code 10196 — API 토큰으로 배포를 시도했다.
     unset CLOUDFLARE_API_TOKEN 후 'npx wrangler login' 으로 다시 하라.
     (또는 --no-tunnel 로 실행하면 이 문제가 없다)"
  fi
  die "배포 실패. 위 로그를 확인하라"
fi

endpoint="$(grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' "$deploy_log" | head -1 || true)"
rm -f "$deploy_log"
[ -n "$endpoint" ] || endpoint="$(ask_value 'Worker 주소를 붙여넣어라 (https://....workers.dev)')"

# --------------------------------------------------------------- 마무리
cat <<EOS

========================================================================
완료. 아래 값을 쓴다. (전부 $secrets_out 에도 있다)

앱 설정에 입력할 값
  클라우드 주소   : $endpoint
  기기 ID         : 콤마에서  cat /data/params/d/DongleId
  라이브 토큰     : WAYON_LIVE_TOKEN
  Wayon Cloud Key : WAYON_VIEW_TOKEN

콤마 기기에서 실행할 명령
  export WAYON_UPLOAD_TOKEN=<위 파일의 값>
EOS
if [ "$use_tunnel" -eq 1 ]; then
  cat <<EOS
  export WAYON_TUNNEL_TOKEN=<위 파일의 값>
  /data/openpilot/scripts/wayon/wayon_setup.sh --endpoint $endpoint --tunnel
EOS
else
  cat <<EOS
  /data/openpilot/scripts/wayon/wayon_setup.sh --endpoint $endpoint

터널 없이 배포했다. 360 라이브뷰와 원격 SSH 는 동작하지 않고
배터리·주차위치·주행기록·스냅샷은 정상 동작한다.
나중에 라이브뷰가 필요하면 --no-tunnel 없이 이 스크립트를 다시 실행하라.
EOS
fi
printf '========================================================================\n\n'
