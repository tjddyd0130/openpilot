"""Ground-plane lateral camera offset for the driving model input (carrot-wip-tj-test).

The driving model places the car relative to the camera origin, and calibrationd only
estimates rotation (pitch/yaw) plus height, never a lateral translation. A device that
sits off the vehicle centreline, or a model that prefers one side of the lane, therefore
shows up as a distance-independent lateral bias that a yaw trim cannot fix (yaw rotates
the world, so its lateral effect grows with distance and is asymmetric in curves).

This module synthesises the view of a camera translated sideways by `offset_m` with a
shear applied in the model input pixel frame. The model frame is already the calibrated
(pitch/yaw aligned) view, so its horizon row is exactly the intrinsic `cy`; a ground
point at depth Z projects to row v = cy + fy*h/Z and column u = cx + fx*y/Z, hence a
lateral translation d shifts its column by fx*d/Z = (fx/fy)*(d/h)*(v - cy). Rows above
the horizon are left untouched (objects standing on the ground are only partly
corrected, which is why the range is kept small).

Sign convention matches CameraYawTrimDeg: a positive offset moves the car to the right.
"""
from __future__ import annotations

import numpy as np

CAMERA_OFFSET_MAX_M = 0.20
DEFAULT_CAMERA_HEIGHT_M = 1.22


def clip_camera_offset(offset_m: float) -> float:
  if not np.isfinite(offset_m):
    return 0.0
  return float(np.clip(offset_m, -CAMERA_OFFSET_MAX_M, CAMERA_OFFSET_MAX_M))


def camera_height_or_default(height) -> float:
  try:
    h = float(height[0])
  except (TypeError, IndexError, ValueError):
    return DEFAULT_CAMERA_HEIGHT_M
  if not np.isfinite(h) or h < 0.5 or h > 3.0:
    return DEFAULT_CAMERA_HEIGHT_M
  return h


def camera_offset_shear(model_intrinsics: np.ndarray, offset_m: float, height_m: float) -> np.ndarray:
  """Shear in model input pixels that mimics a camera translated sideways by offset_m.

  Positive offset_m = car should move right = the model must see a world shifted as if
  the camera had moved left, so sampled source columns move left on the ground plane.
  """
  fx = float(model_intrinsics[0, 0])
  fy = float(model_intrinsics[1, 1])
  cy = float(model_intrinsics[1, 2])
  k = -(fx / fy) * (offset_m / height_m)
  return np.array([[1.0, k, -k * cy],
                   [0.0, 1.0, 0.0],
                   [0.0, 0.0, 1.0]], dtype=np.float64)


def apply_camera_offset(warp: np.ndarray, model_intrinsics: np.ndarray, offset_m: float, height_m: float) -> np.ndarray:
  """Compose the ground-plane shear onto a model-frame -> camera-frame warp matrix."""
  offset_m = clip_camera_offset(offset_m)
  if offset_m == 0.0:
    return warp
  shear = camera_offset_shear(model_intrinsics, offset_m, height_m)
  return (np.asarray(warp, dtype=np.float64) @ shear).astype(np.float32)
