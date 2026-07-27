#!/usr/bin/env python3
"""주차 상태에서 CAN을 장시간 스니핑한다. 예약공조가 발동하는 순간을 잡는 게 목적.

배경: 국내 사양 ID.4는 통신유닛(OCU)이 없어 앱 원격 공조가 불가능하지만 예약공조는 동작한다.
즉 차량은 이미 주차 상태에서 스스로 깨어나 HV를 켜고 공조를 돌릴 능력이 있다. 그 방아쇠가
되는 메시지를 찾으면 openpilot이 같은 것을 보낼 수 있는지 판단할 수 있다.

이 스크립트는 읽기만 한다. CAN 송신도, 파라미터 쓰기도 없다.
pandad가 항상 실행되는 프로세스(always_run)라 시동이 꺼져 있어도 'can' 소켓으로 프레임이
계속 올라온다. 그래서 openpilot을 죽이거나 판다를 직접 열 필요가 없다.

기본은 변화분만 기록한다. 버스가 자는 동안은 거의 아무것도 안 쌓이고, 차가 깨어나는
순간에 폭발적으로 기록된다. 그 경계가 바로 우리가 찾는 지점이다.

사용법:
  1. 차량 인포테인먼트에서 예약공조 시각을 10~15분 뒤로 설정
  2. SSH로 접속해 백그라운드로 실행
       cd /data/openpilot && nohup python selfdrive/debug/car/vw_meb_parked_can_sniff.py \
         --out /data/media/0/parked_can.jsonl > /data/media/0/sniff.log 2>&1 &
  3. 시동 끄고 내려서 문 잠그기
  4. 예약 시각 지나 공조가 도는 것을 확인한 뒤 접속해서 종료
       pkill -f vw_meb_parked_can_sniff
  5. /data/media/0/parked_can.jsonl 회수

주의: 상시전원이라도 12V 방전은 실재한다. MaxTimeOffroadMin 설정과 무관하게 저전압에서는
openpilot이 셧다운하므로, 장시간 방치보다 예약 시각 직전에 시작하는 편이 안전하다.
"""

import argparse
import json
import os
import time
from datetime import datetime

import openpilot.cereal.messaging as messaging

# 이 시간 이상 아무 프레임도 안 오면 버스가 잔 것으로 본다.
SLEEP_GAP_S = 3.0

# 기본 파일 크기 상한. 넘으면 기록을 멈추고 통계만 이어간다.
DEFAULT_MAX_MB = 200


def main():
  parser = argparse.ArgumentParser(
    description="주차 중 CAN 장시간 스니핑 (읽기 전용). 예약공조 발동 시점의 프레임을 잡는다.",
  )
  parser.add_argument("--out", default=None, help="결과 jsonl 경로")
  parser.add_argument("--all", action="store_true",
                      help="모든 프레임 기록 (기본은 페이로드가 바뀐 것만)")
  parser.add_argument("--max-mb", type=int, default=DEFAULT_MAX_MB,
                      help=f"파일 크기 상한 MB (기본 {DEFAULT_MAX_MB})")
  parser.add_argument("--stats-sec", type=float, default=60.0,
                      help="콘솔 통계 출력 주기 초 (기본 60)")
  args = parser.parse_args()

  out_path = args.out or os.path.join(
    "/tmp", f"parked_can_{datetime.now().strftime('%Y%m%d_%H%M%S')}.jsonl")
  max_bytes = args.max_mb * 1024 * 1024

  print("주차 중 CAN 스니핑 (읽기 전용)")
  print(f"  출력:     {out_path}")
  print(f"  모드:     {'전체 프레임' if args.all else '변화분만'}")
  print(f"  크기상한: {args.max_mb} MB")
  print("  송신은 하지 않음. Ctrl-C 또는 pkill 로 종료.\n")

  logcan = messaging.sub_sock('can', timeout=1000)

  last_payload: dict[tuple[int, int], bytes] = {}
  seen_count: dict[tuple[int, int], int] = {}
  total_frames = 0
  written = 0
  capped = False

  start_wall = datetime.now()
  start_mono = time.monotonic()
  last_frame_mono: float | None = None
  last_stats = start_mono
  wake_events = 0

  f = open(out_path, "w")
  f.write(json.dumps({
    "type": "meta",
    "started": datetime.now().isoformat(),
    "mode": "all" if args.all else "changes",
    "note": "주차 중 예약공조 방아쇠 탐색",
  }) + "\n")
  f.flush()

  try:
    while True:
      msgs = messaging.drain_sock(logcan, wait_for_one=False)
      now_mono = time.monotonic()

      if msgs:
        # 버스가 자다가 깨어난 경계를 표시한다. 이게 분석의 앵커가 된다.
        if last_frame_mono is not None and (now_mono - last_frame_mono) > SLEEP_GAP_S:
          gap = now_mono - last_frame_mono
          wake_events += 1
          rec = {
            "type": "wake",
            "t": round(now_mono - start_mono, 3),
            "wall": datetime.now().isoformat(),
            "silence_sec": round(gap, 2),
          }
          f.write(json.dumps(rec) + "\n")
          f.flush()
          print(f"  [WAKE] {gap:.1f}초 침묵 뒤 버스 재개  ({datetime.now().strftime('%H:%M:%S')})")
        last_frame_mono = now_mono

      for msg in msgs:
        # t는 우리 시계 기준 경과초. logMonoTime은 CLOCK_BOOTTIME 기반이라 time.monotonic()과
        # 오프셋이 보장되지 않으므로 섞지 않고 raw 값을 따로 남긴다.
        t = round(now_mono - start_mono, 4)
        mono = msg.logMonoTime
        for c in msg.can:
          key = (c.src, c.address)
          data = bytes(c.dat)
          total_frames += 1
          seen_count[key] = seen_count.get(key, 0) + 1

          if not args.all:
            prev = last_payload.get(key)
            if prev == data:
              continue
            first = prev is None
          else:
            first = key not in last_payload
          last_payload[key] = data

          if capped:
            continue

          f.write(json.dumps({
            "t": t,
            "mono": mono,
            "bus": c.src,
            "addr": c.address,
            "len": len(data),
            "dat": data.hex(),
            **({"first": True} if first else {}),
          }) + "\n")
          written += 1

          if written % 200 == 0:
            f.flush()
            if f.tell() > max_bytes:
              capped = True
              f.flush()
              print(f"  ! 크기 상한 {args.max_mb}MB 도달. 기록 중단, 통계만 계속.")

      if now_mono - last_stats >= args.stats_sec:
        last_stats = now_mono
        elapsed = now_mono - start_mono
        silent = "" if last_frame_mono is None else f", 마지막 프레임 {now_mono - last_frame_mono:.0f}초 전"
        size_mb = f.tell() / 1024 / 1024
        clock = datetime.now().strftime('%H:%M:%S')
        head = f"  [{clock}] {elapsed / 60:.0f}분 경과"
        body = f"프레임 {total_frames}  기록 {written}  주소 {len(seen_count)}개"
        tail = f"{size_mb:.1f}MB  깨어남 {wake_events}회{silent}"
        print(f"{head}  {body}  {tail}")
        f.flush()

      if not msgs:
        time.sleep(0.05)

  except KeyboardInterrupt:
    print("\n[중단] 사용자가 멈춤.")
  finally:
    f.flush()
    f.close()

  elapsed = time.monotonic() - start_mono
  print(f"\n[완료] {elapsed / 3600:.2f}시간 ({elapsed / 60:.1f}분)")
  print(f"  총 프레임:   {total_frames}")
  print(f"  기록된 줄:   {written}")
  print(f"  등장한 주소: {len(seen_count)}개")
  print(f"  깨어남 이벤트: {wake_events}회")
  print(f"  시작 시각:   {start_wall.isoformat()}")
  print(f"\n결과 파일: {out_path}")
  print("이 파일을 보내주면 예약공조 발동 시점 프레임을 분석한다.")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
