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
#   ./wayon_cloud_setup.sh --dir ... --no-tunnel            # 라이브뷰·원격SSH 포기, 가장 단순
#   ./wayon_cloud_setup.sh --dir ... --tunnel-id <UUID>     # 대시보드에서 만든 터널 사용
#
# 도메인이 없다면 --tunnel-id 를 써라.
# 'cloudflared tunnel login' 은 Cloudflare 에 등록된 도메인(zone)이 하나는 있어야
# 완료된다. 도메인이 없으면 Zero Trust 대시보드에서 터널을 만들고(도메인 불필요),
# 터널 ID 와 토큰을 받아 --tunnel-id 로 넘기면 나머지는 그대로 자동화된다.
#
# --no-tunnel 을 쓰면 [[vpc_networks]] 가 빠져서 문서가 경고한 배포 실패(code 10196)를
# 아예 만나지 않는다. 배터리·주차위치·주행기록·스냅샷은 그대로 동작하고
# 360 라이브뷰와 원격 SSH 만 빠진다. 나중에 터널을 붙이려면 다시 실행하면 된다.
#
# 생성한 시크릿은 Cloudflare 가 다시 보여주지 않으므로, 이 스크립트를 실행한 위치에
# wayon-secrets.txt 로 저장한다. 토큰이 평문으로 들어 있으니 안전하게 보관하라.
#
# 재실행해도 기존 시크릿을 그대로 쓴다. 새로 만들면 이미 설정한 기기·앱의 토큰이
# 무효가 되어 갑자기 멈추기 때문이다. 일부러 바꾸려면 --rotate-secrets 를 준다.

set -euo pipefail

worker_dir=""
worker_name="wayon-cloud"
tunnel_name="wayon-comma"
db_name="wayon_cloud"
kv_binding="WAYON_SNAPSHOTS"
use_tunnel=1
tunnel_id_arg=""
rotate_secrets=0
# 시크릿은 실행한 위치에 남긴다. worker 디렉토리는 git 클론 안이라 실수로 커밋될 수 있다.
secrets_out="$(pwd)/wayon-secrets.txt"

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
    --tunnel-id)   tunnel_id_arg="${2:-}"; shift 2 ;;
    --no-tunnel)   use_tunnel=0; shift ;;
    --rotate-secrets) rotate_secrets=1; shift ;;
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

if [ "$use_tunnel" -eq 1 ] && [ -z "$tunnel_id_arg" ]; then
  # cloudflared CLI 로 터널을 만들려면 'cloudflared tunnel login' 이 필요하고,
  # 그 로그인은 Cloudflare 에 등록된 도메인(zone)이 하나는 있어야 완료된다.
  # 도메인이 없으면 대시보드에서 터널을 만든 뒤 --tunnel-id 로 넘겨라.
  command -v cloudflared >/dev/null || die "cloudflared 가 없다.
     다음 중 하나를 선택하라:
       - cloudflared 설치 후 'cloudflared tunnel login' (Cloudflare 에 도메인이 있어야 한다)
       - 대시보드에서 터널을 만들고  --tunnel-id <UUID> 로 실행
       - --no-tunnel 로 실행 (라이브뷰·원격SSH 포기)"
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
if [ "$use_tunnel" -eq 1 ] && [ -n "$tunnel_id_arg" ]; then
  # 대시보드에서 만든 터널을 쓰는 경로. 도메인이 없어도 된다.
  step "Cloudflare 터널 (대시보드에서 만든 것 사용)"
  tunnel_id="$tunnel_id_arg"
  ok "터널 ID: $tunnel_id"
  tunnel_token="${WAYON_TUNNEL_TOKEN:-}"
  if [ -z "$tunnel_token" ]; then
    printf '  터널 토큰(eyJhIjoi... )을 붙여넣어라 (화면에 표시되지 않음): ' >&2
    read -r -s tunnel_token
    printf '\n' >&2
  fi
  [ -n "$tunnel_token" ] && ok "터널 토큰 확보" || warn "터널 토큰 없음. 기기 설정 때 직접 넣어야 한다"
  warn "대시보드의 터널 상세 > Private Network 에 172.31.255.254/32 가 등록돼 있어야 한다."
  warn "빠지면 대시보드·주행기록은 되는데 360 라이브뷰만 실패한다."

elif [ "$use_tunnel" -eq 1 ]; then
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
# 재실행 시 원본 백업을 덮어쓰지 않는다 (한 번 생성한 toml 로 원본이 사라지는 것 방지)
if [ -f wrangler.toml ] && [ ! -f wrangler.toml.bak ]; then
  cp -p wrangler.toml wrangler.toml.bak
  info "기존 파일을 wrangler.toml.bak 으로 백업"
fi

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
# wrangler 는 --remote 실행 전에 "Ok to proceed?" 를 되묻는다. Git Bash(MSYS) 처럼
# TTY 가 온전치 않은 환경에서는 이 프롬프트 응답이 전달되지 않아 취소된다.
# -y 로 확인을 건너뛰고, 이 플래그를 모르는 구버전이면 없이 한 번 더 시도한다.
d1_exec() {  # d1_exec <sql파일>
  npx --yes wrangler d1 execute "$db_name" --remote --file="$1" -y </dev/null 2>&1 \
    || npx --yes wrangler d1 execute "$db_name" --remote --file="$1" </dev/null 2>&1
}

out="$(d1_exec ./schema.sql)" || { printf '%s\n' "$out"; die "스키마 적용 실패"; }
ok "schema.sql"

# migrations/ 는 예전에 만든 DB 를 올리기 위한 것이라, 최신 schema.sql 로 새로 만든
# DB 에는 이미 반영돼 있다. 0001 처럼 맨 ALTER TABLE ADD COLUMN 을 쓰는 파일은
# "duplicate column name" 으로 실패하는데 이건 정상이므로 건너뛴다.
for m in migrations/*.sql; do
  [ -e "$m" ] || continue
  name="$(basename "$m")"
  if out="$(d1_exec "$m")"; then
    ok "$name"
  elif printf '%s' "$out" | grep -qiE "duplicate column name|already exists"; then
    ok "$name (이미 반영됨, 건너뜀)"
  else
    printf '%s\n' "$out"
    die "마이그레이션 실패: $m"
  fi
done

# --------------------------------------------------------------- 5. 배포
# 시크릿보다 배포를 먼저 한다. Worker 가 아직 없는 상태에서 'wrangler secret put' 을
# 부르면 "그런 Worker 가 없다. 새로 만들까?" 를 되묻는데, Git Bash 처럼 TTY 가
# 온전치 않은 환경에서는 그 프롬프트에 답할 수 없어 막힌다.
# 시크릿은 배포 후에 넣어도 즉시 반영되므로 재배포가 필요 없다.
step "배포"
deploy_log="$(mktemp)"
if npx --yes wrangler deploy </dev/null 2>&1 | tee "$deploy_log"; then
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

# -------------------------------------------------------------- 6. 시크릿
step "시크릿 준비 및 등록"
gen() { openssl rand -hex 32; }

# 재실행 시 기존 시크릿을 그대로 쓴다. 새로 만들어버리면 이미 설정을 마친
# 콤마 기기와 앱의 토큰이 전부 무효가 되어 갑자기 동작을 멈춘다.
# 일부러 바꾸려면 --rotate-secrets 를 준다.
read_secret() {  # read_secret <이름>
  [ -f "$secrets_out" ] || return 1
  sed -n "s/^$1=\(.*\)$/\1/p" "$secrets_out" | head -1
}

UPLOAD_TOKEN=""; VIEW_TOKEN=""; LIVE_TOKEN=""; SSH_SECRET=""
if [ "$rotate_secrets" -eq 0 ] && [ -f "$secrets_out" ]; then
  UPLOAD_TOKEN="$(read_secret WAYON_UPLOAD_TOKEN || true)"
  VIEW_TOKEN="$(read_secret WAYON_VIEW_TOKEN || true)"
  LIVE_TOKEN="$(read_secret WAYON_LIVE_TOKEN || true)"
  SSH_SECRET="$(read_secret WAYON_SSH_SESSION_SECRET || true)"
  if [ -n "$UPLOAD_TOKEN" ] && [ -n "$VIEW_TOKEN" ] && [ -n "$LIVE_TOKEN" ] && [ -n "$SSH_SECRET" ]; then
    ok "기존 시크릿 재사용 ($secrets_out)"
    info "새로 만들려면 --rotate-secrets 를 주라 (기기·앱 설정도 함께 바꿔야 한다)"
  else
    warn "기존 파일이 불완전하다. 빠진 값만 새로 만든다"
  fi
fi
[ -n "$UPLOAD_TOKEN" ] || { UPLOAD_TOKEN="$(gen)"; ok "WAYON_UPLOAD_TOKEN 생성"; }
[ -n "$VIEW_TOKEN" ]   || { VIEW_TOKEN="$(gen)";   ok "WAYON_VIEW_TOKEN 생성"; }
[ -n "$LIVE_TOKEN" ]   || { LIVE_TOKEN="$(gen)";   ok "WAYON_LIVE_TOKEN 생성"; }
[ -n "$SSH_SECRET" ]   || { SSH_SECRET="$(gen)";   ok "WAYON_SSH_SESSION_SECRET 생성"; }

# 값은 stdin 으로만 넘긴다 (명령행/화면에 노출 금지).
put_secret() {  # put_secret <이름> <값>
  if printf '%s' "$2" | npx --yes wrangler secret put "$1" >/dev/null 2>&1; then
    ok "$1"
  else
    die "$1 등록 실패. 수동으로:  npx wrangler secret put $1"
  fi
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
