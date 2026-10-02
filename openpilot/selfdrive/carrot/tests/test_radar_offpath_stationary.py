"""carrot-wip-tj: adjacent-lane stationary front tracks must not become the vision-matched lead."""

from openpilot.selfdrive.carrot.radar_motion import VisionRadarMatcher, snapshot_radar_points
from openpilot.selfdrive.carrot.tests.test_radar_motion_predictor import (
  STRAIGHT_PATH,
  Point,
  model_with_lead,
)


def _selection(adjacent: Point, in_path: Point | None = None,
               vision_d_rel: float = 50.0, vision_v: float = 0.0) -> list[int | None]:
  matcher = VisionRadarMatcher()
  selected = []
  for index in range(10):
    raw = (adjacent,) if in_path is None else (adjacent, in_path)
    points = snapshot_radar_points(raw, v_ego=0.0)
    match = matcher.match(
      model_with_lead(vision_d_rel, 0.0, vision_v, probability=1.0),
      points,
      STRAIGHT_PATH,
      time_s=index * 0.05,
      stationary_points=points,
      prefer_primary_stationary=True,
    )
    selected.append(None if match is None else match.point.track_id)
  return selected


def test_rejects_adjacent_queue_nearer_than_vision() -> None:
  # 0000016b--dedac5c904--3: stopped car in the next lane, 10 m nearer than the
  # in-path vision lead, was held as leadOne and braked 49 -> 12 km/h.
  assert 41 not in _selection(Point(41, 40.0, 1.9))
  assert _selection(Point(41, 40.0, 1.9), Point(45, 50.0, 0.0))[-1] == 45


def test_rejects_adjacent_queue_farther_than_vision() -> None:
  assert 50 not in _selection(Point(50, 58.0, 1.9))


def test_rejects_adjacent_queue_slower_than_moving_vision() -> None:
  # 0000014b--a9964c3220--21: range agreed with a 6.7 m/s vision lead but the
  # off-path (dPath ~2 m) track was stopped.
  assert 50 not in _selection(Point(50, 41.0, 2.0), vision_d_rel=40.0, vision_v=6.7)


def test_keeps_near_path_track_nearer_than_vision() -> None:
  assert _selection(Point(41, 40.0, 1.2))[-1] == 41
