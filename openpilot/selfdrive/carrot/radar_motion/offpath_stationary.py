"""Reject adjacent-lane stationary front-radar tracks as the vision-matched lead.

carrot-wip-tj (KIA_EV_SK3) field fix, kept in its own module so upstream
merges only touch the small hook in primary.VisionRadarMatcher.match().

A stopped car in a neighbouring lane can be paired with the in-path vision
lead by the loose stationary range/speed gates and then held while it drifts
up to 4 m off the path, braking ego hard (0000016b--dedac5c904--3: 49 -> 12 km/h
with its own lane clear). A stationary front track that is off the model path
AND disagrees with the strong vision lead in range or speed is not the lead.
Corner-radar corroborated objects are excluded by the caller.
"""

from __future__ import annotations

from typing import Any

OFFPATH_MAX_DPATH_M = 1.6
OFFPATH_MAX_VISION_RANGE_ERROR_M = 6.0
OFFPATH_MAX_VISION_SPEED_ERROR_MPS = 4.0


def offpath_stationary_vision_mismatch(stationary: Any | None, vision: Any | None) -> bool:
  """True when the stationary match is an off-path front track that disagrees with vision."""
  if stationary is None or vision is None or stationary.point.source != "frontRadar":
    return False
  return (
    abs(stationary.d_path) > OFFPATH_MAX_DPATH_M
    and (
      abs(stationary.point.d_rel - vision.d_rel) > OFFPATH_MAX_VISION_RANGE_ERROR_M
      or abs(stationary.point.v_lead - vision.velocity) > OFFPATH_MAX_VISION_SPEED_ERROR_MPS
    )
  )
