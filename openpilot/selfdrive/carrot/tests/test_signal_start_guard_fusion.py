"""carrot-wip-tj: occluded-red release of the stopped-car signal veto."""
from openpilot.selfdrive.carrot.signal_start_guard import SignalStartGuard, LeadContext

STRONG = [600, 150, 640, 190]   # 40 px tall, image centre
WEAK = [430, 160, 436, 166]     # 6 px, off-centre


def obs(ts, fid, tracks, session='s1'):
  return {'timestamp': ts, 'frame_id': fid, 'session': session,
          'tracks': [{'box': b, 'raw': c} for b, c in tracks]}


def ctx(**kw):
  base = dict(enabled=True, valid=True, drive=True, gas=False, speed=0.0, departure=True)
  base.update(kw)
  return base


def arm(g, box=STRONG, t=0.0):
  """Confirm a red (two samples, 0.2 s apart) and return the time after the second sample."""
  d = g.update(t+.3, obs(t, 1, [(box, 'red')]), **ctx())
  assert not d.hold
  d = g.update(t+.5, obs(t+.2, 2, [(box, 'red')]), **ctx())
  assert d.hold and d.reason == 'red'
  return t+.5


def test_strong_fresh_red_beats_model_and_lead():
  g = SignalStartGuard()
  t = arm(g)
  gone = LeadContext(True, 4.2, 0.0, 0.1)
  g.update(t, obs(t-.3, 3, [(STRONG, 'red')]), **ctx(), model_go=True, lead=gone)
  moving = LeadContext(True, 9.5, 3.0, 0.1)
  for i in range(1, 16):
    now = t+.1*i
    d = g.update(now, obs(now-.3, 3+i, [(STRONG, 'red')]), **ctx(), model_go=True, lead=moving)
    assert d.hold, (now, d)


def test_model_go_releases_when_red_unseen():
  g = SignalStartGuard()
  t = arm(g)
  # tracker keeps publishing frames but the housing is gone (occluded / above the camera)
  reasons = []
  for i in range(1, 25):
    now = t+.1*i
    d = g.update(now, obs(now-.3, 2+i, []), **ctx(), model_go=True)
    reasons.append(d.reason)
    if d.released:
      break
  assert d.released and d.reason == 'model_go_no_red'
  # red must be unseen for RED_FRESH (1.0 s after the last red capture at t-0.3) and model go sustained 0.5 s
  assert abs((t+.1*i)-(t-.3+1.0)) <= .15, (t, i)
  assert 'unconfirmed' in reasons or 'missing' in reasons or 'red' not in reasons[-3:]


def test_lead_departure_releases_when_red_unseen_and_model_silent():
  g = SignalStartGuard()
  t = arm(g)
  stopped = LeadContext(True, 4.2, 0.0, 0.2)
  g.update(t, obs(t-.3, 3, [(STRONG, 'red')]), **ctx(), lead=stopped)
  d = None
  for i in range(1, 40):
    now = t+.1*i
    lead = stopped if i < 5 else LeadContext(True, 4.2+1.0*(i-4), 2.0, 0.2)
    d = g.update(now, obs(now-.3, 3+i, []), **ctx(), model_go=False, lead=lead)
    if d.released:
      break
  assert d.released and d.reason == 'lead_departed_no_red'


def test_adjacent_lane_lead_cannot_release():
  g = SignalStartGuard()
  t = arm(g)
  g.update(t, obs(t-.3, 3, [(STRONG, 'red')]), **ctx(), lead=LeadContext(True, 4.0, 0.0, 2.5))
  for i in range(1, 40):
    now = t+.1*i
    d = g.update(now, obs(now-.3, 3+i, []), **ctx(), lead=LeadContext(True, 4.0+i, 3.0, 2.5))
  assert d.hold


def test_weak_red_needs_model_and_lead_to_yield():
  g = SignalStartGuard()
  t = arm(g, box=WEAK)
  g.update(t, obs(t-.3, 3, [(WEAK, 'red')]), **ctx(), lead=LeadContext(True, 4.2, 0.0, 0.0))
  # weak red stays fresh every frame; model alone must not release
  for i in range(1, 15):
    now = t+.1*i
    d = g.update(now, obs(now-.3, 3+i, [(WEAK, 'red')]), **ctx(), model_go=True,
                 lead=LeadContext(True, 4.2, 0.0, 0.0))
    assert d.hold, (i, d)
  # lead departs as well -> yield
  for i in range(15, 45):
    now = t+.1*i
    d = g.update(now, obs(now-.3, 3+i, [(WEAK, 'red')]), **ctx(), model_go=True,
                 lead=LeadContext(True, 4.2+1.0*(i-14), 2.5, 0.0))
    if d.released:
      break
  assert d.released and d.reason == 'weak_red_model_lead'


def test_red_timeout_without_any_evidence():
  g = SignalStartGuard()
  t = arm(g)
  d = g.update(t+119.0, obs(t+118.7, 3, []), **ctx())
  assert d.hold
  d = g.update(t+120.6, obs(t+120.3, 4, []), **ctx())
  assert d.released and d.reason == 'red_timeout'


def test_release_grace_blocks_weak_but_not_strong_red():
  g = SignalStartGuard()
  t = arm(g)
  for i in range(1, 20):
    now = t+.1*i
    d = g.update(now, obs(now-.3, 2+i, []), **ctx(), model_go=True)
    if d.released:
      break
  assert d.released
  t2 = now
  d = g.update(t2+.3, obs(t2, 50, [(WEAK, 'red')]), **ctx())
  d = g.update(t2+.5, obs(t2+.2, 51, [(WEAK, 'red')]), **ctx())
  assert not d.hold and d.reason == 'release_grace'
  d = g.update(t2+.8, obs(t2+.5, 52, [(STRONG, 'red')]), **ctx())
  d = g.update(t2+1.0, obs(t2+.7, 53, [(STRONG, 'red')]), **ctx())
  assert d.hold


def test_legacy_call_signature_still_holds_through_unknown():
  g = SignalStartGuard()
  t = arm(g)
  for i in range(1, 30):
    now = t+.1*i
    d = g.update(now, obs(now-.3, 2+i, []), **ctx())
  assert d.hold  # no model/lead inputs: behaves like upstream until the 120 s timeout
