#!/usr/bin/env bash
# Wayon 원격 기능 기기측 설정 스크립트 (콤마 기기에서 실행)
#
# docs/cloudflare-세팅.md 의 STEP 6 (명령 8개)을 한 번에 처리한다.
#   - /data/wayon_cloud/config.json 작성 (텔레메트리·라이브뷰 기동 조건)
#   - (선택) cloudflared 내려받기 + 터널 토큰 + supervisor 설치
#   - comma 서비스 재시작
#
# 토큰은 인자로 받지 않는다. 셸 히스토리에 남기지 않기 위해 환경변수 또는
# 화면에 표시되지 않는 입력으로 받는다.
#
# 사용:
#   ./wayon_setup.sh --endpoint https://wayon-cloud.<계정>.workers.dev
#   ./wayon_setup.sh --endpoint https://... --tunnel     # 라이브뷰·원격SSH까지
#   ./wayon_setup.sh --check                             # 설정 상태만 점검
#
# 토큰을 미리 넣어두려면 (히스토리에 남기지 않으려면 앞에 공백 한 칸):
#    export WAYON_UPLOAD_TOKEN=...
#    export WAYON_TUNNEL_TOKEN=...

set -euo pipefail

CONFIG_DIR=/data/wayon_cloud
CONFIG_PATH="$CONFIG_DIR/config.json"
REMOTE_DIR=/data/wayon-remote
CLOUDFLARED_BIN="$REMOTE_DIR/bin/cloudflared"
TUNNEL_TOKEN_PATH="$REMOTE_DIR/tunnel.token"
SUPERVISOR_PATH="$REMOTE_DIR/wayon_remote_supervisor.sh"
DONGLE_PATH=/data/params/d/DongleId
CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

endpoint=""
device_id=""
want_tunnel=0
check_only=0

die() { printf '오류: %s\n' "$*" >&2; exit 1; }
ok()  { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [실패] %s\n' "$*"; }
info(){ printf '%s\n' "$*"; }

usage() {
  # 상단 주석 블록만 출력한다 (셔뱅 다음부터 첫 비주석 줄 전까지).
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint)  endpoint="${2:-}"; shift 2 ;;
    --device-id) device_id="${2:-}"; shift 2 ;;
    --tunnel)    want_tunnel=1; shift ;;
    --check)     check_only=1; shift ;;
    -h|--help)   usage ;;
    *) die "알 수 없는 인자: $1  (--help 참고)" ;;
  esac
done

# ---------------------------------------------------------------- 점검 모드
run_check() {
  info "Wayon 설정 점검"
  info ""

  local cfg_endpoint=""
  if [ -f "$CONFIG_PATH" ]; then
    ok "config.json 있음 ($CONFIG_PATH)"
    # 토큰은 출력하지 않는다
    cfg_endpoint="$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH")"
    local cfg_device
    cfg_device="$(sed -n 's/.*"device_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_PATH")"
    [ -n "$cfg_endpoint" ] && ok "endpoint: $cfg_endpoint" || bad "endpoint 없음"
    [ -n "$cfg_device" ]   && ok "device_id: $cfg_device"   || bad "device_id 없음"
    grep -q '"token"[[:space:]]*:[[:space:]]*"..*"' "$CONFIG_PATH" \
      && ok "token 설정됨" || bad "token 없음"
    local perm
    perm="$(stat -c '%a' "$CONFIG_PATH" 2>/dev/null || echo '?')"
    [ "$perm" = "600" ] && ok "권한 600" || bad "권한이 $perm 이다 (600 권장)"
  else
    bad "config.json 없음 -> wayon 프로세스가 기동하지 않는다"
  fi

  # 터널을 아예 설치하지 않았으면(--no-tunnel 구성) 관련 항목을 실패로 표시하지 않는다.
  local tunnel_installed=0
  if [ -x "$CLOUDFLARED_BIN" ] || [ -r "$TUNNEL_TOKEN_PATH" ] || [ -x "$SUPERVISOR_PATH" ]; then
    tunnel_installed=1
  fi

  info ""
  info "프로세스"
  local found=0
  for p in wayon_vehicle_telemetry wayon_live_stream wayon_remote; do
    if pgrep -f "$p" >/dev/null 2>&1; then ok "$p 실행 중"; found=$((found+1))
    else bad "$p 미실행"; fi
  done
  if [ "$tunnel_installed" -eq 1 ]; then
    pgrep -f cloudflared >/dev/null 2>&1 && ok "cloudflared 실행 중" \
      || bad "cloudflared 미실행 (주행 중이면 정상 - supervisor 가 오프로드에서만 올린다)"
  fi
  [ "$found" -eq 0 ] && info "  (config.json 작성 후 재부팅 또는 sudo systemctl restart comma 필요)"

  info ""
  if [ "$tunnel_installed" -eq 0 ]; then
    info "터널: 미설치"
    info "  --no-tunnel 로 설정했다면 정상이다. 배터리·주차위치·주행기록·스냅샷은 동작하고"
    info "  360 라이브뷰와 원격 SSH 만 사용할 수 없다."
    info "  나중에 붙이려면 PC 에서 --no-tunnel 없이 wayon_cloud_setup.sh 를 다시 돌린 뒤"
    info "  이 스크립트를 --tunnel 로 실행하면 된다."
  else
    info "터널"
    [ -x "$CLOUDFLARED_BIN" ] && ok "cloudflared 설치됨" || bad "cloudflared 없음"
    [ -r "$TUNNEL_TOKEN_PATH" ] && ok "터널 토큰 있음" || bad "터널 토큰 없음"
    [ -x "$SUPERVISOR_PATH" ] && ok "supervisor 설치됨" || bad "supervisor 없음"
  fi

  if [ -n "$cfg_endpoint" ]; then
    info ""
    info "클라우드 응답 (조회 토큰이 없으므로 unauthorized 가 정상)"
    # curl 은 실패해도 %{http_code} 로 000 을 출력하므로 폴백에서 값을 덧붙이면 안 된다.
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$cfg_endpoint/api/json" || true)"
    [ -n "$code" ] || code="000"
    case "$code" in
      000) bad "연결 실패 - 주소 또는 네트워크 확인" ;;
      401|403) ok "서버 살아있음 (HTTP $code)" ;;
      200) ok "서버 응답 200" ;;
      *) bad "예상치 못한 응답 HTTP $code" ;;
    esac
  fi
  info ""
}

if [ "$check_only" -eq 1 ]; then
  run_check
  exit 0
fi

# ---------------------------------------------------------------- 설정 모드
[ -n "$endpoint" ] || die "--endpoint 가 필요하다 (예: --endpoint https://wayon-cloud.xxx.workers.dev)"
case "$endpoint" in
  https://*) ;;
  *) die "endpoint 는 https:// 로 시작해야 한다 (앱이 HTTPS만 허용한다)" ;;
esac
endpoint="${endpoint%/}"

if [ -z "$device_id" ]; then
  [ -r "$DONGLE_PATH" ] || die "DongleId 를 읽을 수 없다 ($DONGLE_PATH). --device-id 로 직접 지정하라"
  device_id="$(tr -d '\r\n ' < "$DONGLE_PATH")"
  [ -n "$device_id" ] || die "DongleId 가 비어 있다"
fi

upload_token="${WAYON_UPLOAD_TOKEN:-}"
if [ -z "$upload_token" ]; then
  printf '업로드 토큰(WAYON_UPLOAD_TOKEN)을 입력하라 (화면에 표시되지 않음): '
  read -r -s upload_token
  printf '\n'
fi
[ -n "$upload_token" ] || die "업로드 토큰이 비어 있다"
# JSON 에 그대로 넣으므로 따옴표·역슬래시가 섞이면 파일이 깨진다.
# Cloudflare 시크릿은 openssl rand -hex 로 만들라고 안내하므로 정상 값은 여기 걸리지 않는다.
case "$upload_token" in
  *[\"\\]*|*' '*) die "업로드 토큰에 따옴표/역슬래시/공백이 들어 있다. 값을 다시 확인하라" ;;
esac

tunnel_token=""
if [ "$want_tunnel" -eq 1 ]; then
  tunnel_token="${WAYON_TUNNEL_TOKEN:-}"
  if [ -z "$tunnel_token" ]; then
    printf '터널 토큰(WAYON_TUNNEL_TOKEN)을 입력하라 (화면에 표시되지 않음): '
    read -r -s tunnel_token
    printf '\n'
  fi
  [ -n "$tunnel_token" ] || die "터널 토큰이 비어 있다"
fi

info ""
info "설정할 내용"
info "  endpoint : $endpoint"
info "  device_id: $device_id"
info "  터널     : $([ "$want_tunnel" -eq 1 ] && echo '설치 (라이브뷰·원격SSH)' || echo '건너뜀')"
info ""

# --- config.json (기존 파일이 있으면 백업)
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_PATH" ]; then
  cp -p "$CONFIG_PATH" "$CONFIG_PATH.bak"
  info "기존 config.json 을 config.json.bak 으로 백업했다"
fi
umask 077
tmp="$CONFIG_PATH.tmp"
printf '{"device_id":"%s","endpoint":"%s","token":"%s"}\n' \
  "$device_id" "$endpoint" "$upload_token" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$CONFIG_PATH"
ok "config.json 작성 ($CONFIG_PATH)"

# --- 터널 (선택)
if [ "$want_tunnel" -eq 1 ]; then
  mkdir -p "$REMOTE_DIR/bin"

  if [ -x "$CLOUDFLARED_BIN" ]; then
    ok "cloudflared 이미 설치됨 (다시 받지 않는다)"
  else
    info "cloudflared 내려받는 중..."
    if curl -fL --retry 3 --retry-delay 2 -o "$CLOUDFLARED_BIN.tmp" "$CLOUDFLARED_URL"; then
      chmod +x "$CLOUDFLARED_BIN.tmp"
      mv "$CLOUDFLARED_BIN.tmp" "$CLOUDFLARED_BIN"
      ok "cloudflared 설치"
    else
      rm -f "$CLOUDFLARED_BIN.tmp"
      die "cloudflared 내려받기 실패 (네트워크 확인)"
    fi
  fi

  printf '%s' "$tunnel_token" > "$TUNNEL_TOKEN_PATH"
  chmod 600 "$TUNNEL_TOKEN_PATH"
  ok "터널 토큰 저장"

  if [ -f "$SCRIPT_DIR/wayon_remote_supervisor.sh" ]; then
    cp "$SCRIPT_DIR/wayon_remote_supervisor.sh" "$SUPERVISOR_PATH"
  else
    die "supervisor 스크립트를 찾을 수 없다 ($SCRIPT_DIR/wayon_remote_supervisor.sh)"
  fi
  chmod +x "$SUPERVISOR_PATH"
  ok "supervisor 설치 ($SUPERVISOR_PATH)"

  # supervisor 는 sudo -n 으로 ip/systemctl 을 부른다. 미리 확인해준다.
  if sudo -n true 2>/dev/null; then
    ok "sudo 비밀번호 없이 사용 가능 (supervisor 정상 동작 조건)"
  else
    bad "sudo -n 이 안 된다. 터널이 루프백 별칭을 못 붙여 라이브뷰가 실패할 수 있다"
  fi
fi

info ""
info "comma 서비스를 재시작한다..."
if sudo -n systemctl restart comma 2>/dev/null; then
  ok "재시작 완료"
else
  bad "자동 재시작 실패. 직접 실행하라:  sudo systemctl restart comma"
fi

info ""
info "약 30초 뒤 아래로 확인하라."
info "  $0 --check"
info ""
info "앱 설정에 넣을 값"
info "  클라우드 주소  : $endpoint"
info "  기기 ID        : $device_id"
info "  라이브 토큰    : WAYON_LIVE_TOKEN (Cloudflare 에서 만든 값)"
info "  Wayon Cloud Key: WAYON_VIEW_TOKEN (Cloudflare 에서 만든 값)"
info ""
