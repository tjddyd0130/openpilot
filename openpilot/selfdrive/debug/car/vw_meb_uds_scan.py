#!/usr/bin/env python3
"""VW MEB UDS DataIdentifier 읽기 전용 스캐너.

두 가지 조사에 쓴다.
  1) 공조(0x746): 원격 공조를 진단 경로로 구동할 수 있는지. CAN 명령 메시지는 콤마가
     물린 버스에 없다는 것이 실차 로깅으로 확인됐고, UDS 경로만 미검증으로 남아 있다.
     ECU가 응답하는지, 어떤 DID를 갖는지부터 확인하는 것이 목적이다.
  2) 레이더(0x757): raw 오브젝트 트랙을 켜는 설정 DID가 있는지. 현대 Mando 레이더의
     EnableRadarTracks(DID 0x0142)에 해당하는 채널이 Continental 계열에도 있는지.

이 스크립트는 절대 쓰기를 하지 않는다. 사용하는 서비스는 세 개뿐이다.
  0x3E TesterPresent            (--scan-ecus 에서 존재 확인용)
  0x10 DiagnosticSessionControl (EXTENDED=0x03, 종료 시 DEFAULT=0x01)
  0x22 ReadDataByIdentifier

WriteDataByIdentifier(0x2E), SecurityAccess(0x27), RoutineControl(0x31),
InputOutputControl(0x2F), ECUReset(0x11), 그리고 레이더를 잠재우는
PROGRAMMING 세션(0x02)은 쓰지 않는다.

응답 해석이 핵심이다. 부정응답 코드로 DID의 존재 여부가 갈린다.
  0x31 requestOutOfRange  -> 그런 DID 없음 (대부분)
  0x33 securityAccessDenied -> DID는 있는데 잠겨 있음 (SFD 후보, 가장 중요)
  0x22 conditionsNotCorrect / 0x7E,0x7F -> DID는 있는데 지금 세션/조건이 아님
  긍정응답 -> DID 존재 + 값 확보

사용법 (차량 ACC ON, 시동 OFF, 정차, openpilot/tmux 정지 상태에서):
  cd /data/openpilot
  # 1단계: 어떤 진단 주소가 살아있는지부터 확인
  python selfdrive/debug/car/vw_meb_uds_scan.py --scan-ecus
  # 2단계: 대상 정해서 DID 스캔
  python selfdrive/debug/car/vw_meb_uds_scan.py --target climate
  python selfdrive/debug/car/vw_meb_uds_scan.py --addr 0x746 --full

결과는 jsonl로 저장되며 Ctrl-C로 중단해도 그때까지 내용이 남는다.
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime

from opendbc.car.carlog import carlog
from opendbc.car.structs import CarParams
from opendbc.car.uds import UdsClient, MessageTimeoutError, NegativeResponseError, SESSION_TYPE
from panda import Panda

RX_OFFSET = 0x6a

# 이름으로 고를 수 있는 대상. 진단 주소는 --addr 로 직접 줘도 된다.
# radar/camera/srs 는 openpilot 핑거프린트가 실제로 응답을 받는 주소라 확실하다.
# climate 는 VAG 08번(Klimaanlage) 진단 주소로 알려진 값이며 MEB 에서는 미검증이다.
TARGETS = {
  "radar":   (0x757, "전방 레이더 (fwdRadar, 핑거프린트로 응답 확인됨)"),
  "camera":  (0x74F, "전방 카메라 (fwdCamera, 핑거프린트로 응답 확인됨)"),
  "srs":     (0x715, "에어백 (srs, 핑거프린트로 응답 확인됨)"),
  "climate": (0x746, "공조 (VAG 08번 Klimaanlage, MEB 미검증)"),
  "gateway": (0x710, "게이트웨이 (VAG 19번)"),
}

# ECU 탐색 시 훑을 진단 주소 범위 (11비트 물리 주소 관례)
ECU_SCAN_RANGE = (0x700, 0x7FF)

# 존재하지 않는 DID를 뜻하는 부정응답. 이건 조용히 넘긴다.
NRC_NOT_PRESENT = 0x31

# DID는 있으나 접근이 막힌 경우. SFD/세션 문제라 별도로 모은다.
NRC_BLOCKED = {
  0x22: "conditionsNotCorrect",
  0x33: "securityAccessDenied",
  0x7E: "subFunctionNotSupportedInActiveSession",
  0x7F: "serviceNotSupportedInActiveSession",
}

# 참고용 라벨. 스캔 범위를 제한하지는 않는다.
KNOWN_DIDS = {
  0x0142: "Hyundai Mando EnableRadarTracks 위치 (MEB에 있을 이유는 없음, 확인용)",
  0x0600: "VW Codierung (long coding)",
  0xF186: "ActiveDiagnosticSession",
  0xF187: "VW Spare Part Number",
  0xF189: "VW Application Software Version",
  0xF18A: "VW System Supplier Identifier",
  0xF191: "VW ECU Hardware Number",
  0xF19E: "ODX File (ASAM dataset)",
  0xF1A2: "VW ASAM Dataset Version",
}

# 기본 스캔 범위. --full 을 주면 0x0000-0xFFFF 전체를 훑는다.
DEFAULT_RANGES = [
  (0x0000, 0x0FFF),   # VW 어댑션/코딩이 주로 사는 대역 (0x0600 코딩 포함)
  (0x1000, 0x1FFF),   # 측정값(Messwerte) 대역
  (0x2000, 0x2FFF),
  (0xF100, 0xF1FF),   # 표준 식별 정보
]


def iter_dids(ranges):
  for lo, hi in ranges:
    yield from range(lo, hi + 1)


def make_client(panda, addr, rx_offset, bus, timeout):
  return UdsClient(panda, addr, addr + rx_offset, bus, timeout=timeout)


def open_session(panda, addr, rx_offset, bus, timeout):
  """해당 버스에서 대상 ECU와 확장 진단 세션을 연다. 성공하면 UdsClient 반환."""
  client = make_client(panda, addr, rx_offset, bus, timeout)
  try:
    client.diagnostic_session_control(SESSION_TYPE.EXTENDED_DIAGNOSTIC)
    return client
  except Exception:
    return None


def scan_ecus(panda, bus, rx_offset, timeout):
  """진단 주소 범위에 TesterPresent(0x3E)만 보내 응답하는 ECU 를 찾는다.

  TesterPresent 는 세션을 바꾸지 않는 가장 무해한 UDS 서비스다. 어느 ECU 와
  대화가 되는지부터 알아야 그다음 DID 스캔 대상을 정할 수 있다.
  """
  lo, hi = ECU_SCAN_RANGE
  found = []
  print(f"[ECU 탐색] 버스 {bus}, 0x{lo:03X}-0x{hi:03X} 에 TesterPresent 송신")
  for addr in range(lo, hi + 1):
    client = make_client(panda, addr, rx_offset, bus, timeout)
    try:
      client.tester_present()
    except NegativeResponseError:
      # 부정응답도 "거기 누가 있다" 는 뜻이다
      pass
    except Exception:
      continue
    label = next((d for a, d in TARGETS.values() if a == addr), "")
    found.append(addr)
    # 부품번호(F187)를 읽어 정체를 밝힌다. 주소만으로는 무슨 ECU인지 알 수 없다.
    part = ""
    try:
      raw = client.read_data_by_identifier(0xF187)
      part = raw.decode("utf-8", "replace").strip().rstrip("\x00")
    except Exception:
      pass
    extra = f"  [{part}]" if part else ""
    print(f"  + 0x{addr:03X} 응답  {label}{extra}")
  if not found:
    print("  응답한 ECU 없음")
  return found


def main():
  # 파일로 리다이렉트하면 파이썬이 stdout 을 블록 버퍼링해서, 중간에 전원이 끊기거나
  # 강제 종료되면 버퍼에 있던 결과가 통째로 사라진다. 차에서 돌리는 도구라 줄 단위로 흘린다.
  try:
    sys.stdout.reconfigure(line_buffering=True)
  except Exception:
    pass

  parser = argparse.ArgumentParser(
    description="VW MEB 전방 레이더(0x757)의 UDS DID를 읽기 전용으로 스캔한다.",
    epilog="차량 ACC ON / 시동 OFF / 정차 / openpilot 정지 상태에서 실행할 것. 쓰기는 하지 않는다.",
  )
  parser.add_argument("--target", choices=sorted(TARGETS), default="radar",
                      help="대상 ECU 이름 (기본 radar). --addr 를 주면 무시된다")
  parser.add_argument("--addr", type=lambda x: int(x, 0), default=None,
                      help="대상 진단 주소 직접 지정 (예: 0x746)")
  parser.add_argument("--rx-offset", type=lambda x: int(x, 0), default=RX_OFFSET,
                      help=f"응답 주소 오프셋 (기본 0x{RX_OFFSET:02X})")
  parser.add_argument("--scan-ecus", action="store_true",
                      help="DID 스캔 대신, 어떤 진단 주소가 응답하는지만 훑는다 (TesterPresent 만 송신)")
  parser.add_argument("--obd", action="store_true",
                      help="OBD 멀티플렉싱 켜기. 게이트웨이 뒤의 ECU(공조 등)는 이걸 켜야 닿는다")
  parser.add_argument("--bus", type=int, default=None, help="CAN 버스 지정. 기본은 0과 1을 자동 탐색")
  parser.add_argument("--full", action="store_true", help="0x0000-0xFFFF 전체 스캔")
  parser.add_argument("--start", type=lambda x: int(x, 0), default=None, help="스캔 시작 DID (예: 0x0100)")
  parser.add_argument("--end", type=lambda x: int(x, 0), default=None, help="스캔 종료 DID (포함)")
  parser.add_argument("--timeout", type=float, default=0.1, help="요청당 타임아웃 초 (기본 0.1)")
  parser.add_argument("--out", default=None, help="결과 jsonl 경로")
  parser.add_argument("--debug", action="store_true", help="ISO-TP/UDS 스택 디버그 출력")
  args = parser.parse_args()

  if args.debug:
    carlog.setLevel('DEBUG')

  if args.start is not None or args.end is not None:
    lo = args.start if args.start is not None else 0x0000
    hi = args.end if args.end is not None else 0xFFFF
    ranges = [(lo, hi)]
  elif args.full:
    ranges = [(0x0000, 0xFFFF)]
  else:
    ranges = DEFAULT_RANGES

  if args.addr is not None:
    addr, target_desc = args.addr, "직접 지정"
  else:
    addr, target_desc = TARGETS[args.target]

  total = sum(hi - lo + 1 for lo, hi in ranges)
  tag = args.target if args.addr is None else f"{addr:03X}"
  out_path = args.out or os.path.join(
    "/tmp", f"meb_uds_{tag}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.jsonl")

  panda = Panda()
  panda.set_safety_mode(CarParams.SafetyModel.elm327)
  # 게이트웨이 뒤의 ECU 는 OBD 멀티플렉싱을 켜야 닿는다. openpilot 펌웨어 조회도
  # bus1 + obd_multiplexing=True 조합을 쓴다 (values.py FW_QUERY_CONFIG).
  if args.obd:
    panda.set_obd(True)
    print("[OBD] 멀티플렉싱 ON\n")
  buses = [args.bus] if args.bus is not None else [0, 1]

  # --- ECU 탐색 모드: 누가 응답하는지만 보고 끝낸다 ---
  if args.scan_ecus:
    print("VW MEB 진단 주소 탐색 (읽기 전용, TesterPresent 만 송신)\n")
    for b in buses:
      scan_ecus(panda, b, args.rx_offset, args.timeout)
      print()
    print("응답한 주소를 --addr 로 지정해 DID 스캔을 돌리면 된다.")
    return 0

  print("VW MEB UDS DID 스캔 (읽기 전용)")
  print(f"  대상:   0x{addr:03X} -> rx 0x{addr + args.rx_offset:03X}  ({target_desc})")
  print(f"  범위:   {', '.join(f'0x{lo:04X}-0x{hi:04X}' for lo, hi in ranges)}  (총 {total}개)")
  print(f"  출력:   {out_path}")
  print("  쓰기 서비스는 사용하지 않음 (0x10 확장세션, 0x22 읽기만)\n")

  client, bus = None, None
  for b in buses:
    print(f"[세션] 버스 {b} 에서 확장 진단 세션 시도...")
    client = open_session(panda, addr, args.rx_offset, b, args.timeout)
    if client is not None:
      bus = b
      print(f"[세션] 버스 {b} 응답 확인\n")
      break
    print(f"[세션] 버스 {b} 무응답")

  if client is None:
    print(f"\n0x{addr:03X} 와 세션을 열지 못했다. 확인할 것:")
    print("  - 이 주소에 ECU 가 실제로 있는가 (--scan-ecus 로 먼저 확인)")
    print("  - 차량 ACC ON 상태인가 (시동은 꺼도 됨)")
    print("  - openpilot/tmux 가 정지되어 있는가 (pkill -f openpilot)")
    print("  - 하네스가 연결되어 있고 판다가 인식되는가")
    return 1

  # 식별 정보 먼저 뽑아둔다. 나중에 결과 대조할 때 어느 차/어느 펌웨어인지 알아야 한다.
  ident = {}
  for did in (0xF187, 0xF189, 0xF191, 0xF19E, 0xF1A2, 0xF18A):
    try:
      ident[f"0x{did:04X}"] = client.read_data_by_identifier(did).hex()
    except Exception:
      pass

  print("[식별]")
  for did, val in ident.items():
    label = KNOWN_DIDS.get(int(did, 16), "")
    try:
      text = bytes.fromhex(val).decode("utf-8").rstrip("\x00").strip()
    except UnicodeDecodeError:
      text = ""
    print(f"  {did}  {label:44s} {text or val}")
  print()

  found, blocked, errors = 0, 0, 0
  started = time.monotonic()
  eta_printed = False

  with open(out_path, "w") as f:
    f.write(json.dumps({
      "type": "meta",
      "target": args.target if args.addr is None else "custom",
      "tx_addr": addr,
      "rx_addr": addr + args.rx_offset,
      "bus": bus,
      "session": "extended",
      "ranges": ranges,
      "ident": ident,
      "timestamp": datetime.now().isoformat(),
    }) + "\n")
    f.flush()

    try:
      for i, did in enumerate(iter_dids(ranges)):
        rec = None
        try:
          data = client.read_data_by_identifier(did)
          rec = {"did": f"0x{did:04X}", "result": "ok", "len": len(data), "data": data.hex()}
          found += 1
          label = KNOWN_DIDS.get(did, "")
          print(f"  + 0x{did:04X}  ({len(data):3d}B) {data.hex()}  {label}")
        except NegativeResponseError as e:
          if e.error_code == NRC_NOT_PRESENT:
            pass
          elif e.error_code in NRC_BLOCKED:
            rec = {"did": f"0x{did:04X}", "result": "blocked",
                   "nrc": f"0x{e.error_code:02X}", "nrc_name": NRC_BLOCKED[e.error_code]}
            blocked += 1
            print(f"  ! 0x{did:04X}  존재하나 접근 거부 (NRC 0x{e.error_code:02X} {NRC_BLOCKED[e.error_code]})")
          else:
            rec = {"did": f"0x{did:04X}", "result": "nrc", "nrc": f"0x{e.error_code:02X}"}
            errors += 1
        except MessageTimeoutError:
          pass
        except KeyboardInterrupt:
          raise
        except Exception as e:
          # 응답 DID 에코 불일치(ValueError), ISO-TP assert 등. 긴 스캔이 중간에 죽으면
          # 안 되니 전부 기록만 하고 계속 진행한다.
          rec = {"did": f"0x{did:04X}", "result": "error", "error": f"{type(e).__name__}: {e}"}
          errors += 1

        if rec is not None:
          f.write(json.dumps(rec) + "\n")
          f.flush()

        if i and i % 256 == 0:
          rate = (i + 1) / (time.monotonic() - started)
          remain = (total - i - 1) / max(rate, 1e-6)
          print(f"  ... {i + 1}/{total}  ({rate:.0f} DID/s, 남은 시간 약 {remain / 60:.1f}분)")
          if not eta_printed and remain > 3600:
            print("  ! 이 속도면 매우 오래 걸린다. Ctrl-C 로 멈추고 --start/--end 로 범위를 줄이는 걸 권장.")
            eta_printed = True

    except KeyboardInterrupt:
      print("\n[중단] 사용자가 멈춤. 여기까지 결과는 저장됨.")
    finally:
      # 레이더를 확장 세션에 남겨두지 않는다.
      try:
        client.diagnostic_session_control(SESSION_TYPE.DEFAULT)
      except Exception:
        pass

  elapsed = time.monotonic() - started
  print(f"\n[완료] {elapsed / 60:.1f}분 소요")
  print(f"  읽힌 DID:      {found}")
  print(f"  존재하나 잠김: {blocked}   <- SFD 후보. 여기가 제일 중요하다")
  print(f"  기타 응답:     {errors}")
  print(f"\n결과 파일: {out_path}")
  print("이 파일을 그대로 보내주면 된다.")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
