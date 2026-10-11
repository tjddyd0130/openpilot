import numpy as np

from openpilot.common.transformations.camera import DEVICE_CAMERAS
from openpilot.common.transformations.model import (get_warp_matrix, medmodel_intrinsics, sbigmodel_intrinsics,
                                                    medmodel_frame_from_calib_frame, sbigmodel_frame_from_calib_frame)
from openpilot.selfdrive.modeld.camera_offset import (CAMERA_OFFSET_MAX_M, DEFAULT_CAMERA_HEIGHT_M, apply_camera_offset,
                                                      camera_height_or_default, clip_camera_offset)

HEIGHT = 1.22


def _model_px(frame_from_calib, z_forward, y_right):
  point = np.array([z_forward, y_right, HEIGHT, 1.0])[:frame_from_calib.shape[1]]
  p = frame_from_calib @ point
  return p / p[2]


def _camera_px(warp, model_px):
  p = warp @ model_px
  return p[:2] / p[2]


def test_shear_matches_lateral_camera_translation():
  cam = next(iter(DEVICE_CAMERAS.values()))
  euler = np.array([0.0, np.radians(-1.5), np.radians(0.5)], dtype=np.float32)
  offset = 0.10
  for big, intr, frame_from_calib in ((False, medmodel_intrinsics, medmodel_frame_from_calib_frame),
                                      (True, sbigmodel_intrinsics, sbigmodel_frame_from_calib_frame)):
    warp = get_warp_matrix(euler, cam.fcam.intrinsics, big).astype(np.float32)
    sheared = apply_camera_offset(warp, intr, offset, HEIGHT)
    for z in (8.0, 20.0, 50.0, 120.0):
      # Positive offset: the model finds the real straight-ahead ground content where it
      # expects a point `offset` to its right, so it believes the car sits further left.
      plain = _camera_px(warp, _model_px(frame_from_calib, z, 0.0))
      shifted = _camera_px(sheared, _model_px(frame_from_calib, z, offset))
      assert np.allclose(plain, shifted, atol=1e-2), (big, z, plain, shifted)
    # The horizon row itself is a fixed point of the shear.
    horizon = np.array([intr[0, 2], intr[1, 2], 1.0])
    assert np.allclose(_camera_px(warp, horizon), _camera_px(sheared, horizon), atol=1e-6)


def test_zero_offset_is_identity_and_range_is_clipped():
  cam = next(iter(DEVICE_CAMERAS.values()))
  warp = get_warp_matrix(np.zeros(3, dtype=np.float32), cam.fcam.intrinsics, False).astype(np.float32)
  assert apply_camera_offset(warp, medmodel_intrinsics, 0.0, HEIGHT) is warp
  assert clip_camera_offset(0.5) == CAMERA_OFFSET_MAX_M
  assert clip_camera_offset(-0.5) == -CAMERA_OFFSET_MAX_M
  assert clip_camera_offset(float('nan')) == 0.0
  big = apply_camera_offset(warp, medmodel_intrinsics, 0.5, HEIGHT)
  capped = apply_camera_offset(warp, medmodel_intrinsics, CAMERA_OFFSET_MAX_M, HEIGHT)
  assert np.allclose(big, capped)


def test_camera_height_fallback():
  assert camera_height_or_default([1.3]) == 1.3
  assert camera_height_or_default([]) == DEFAULT_CAMERA_HEIGHT_M
  assert camera_height_or_default([0.0]) == DEFAULT_CAMERA_HEIGHT_M
  assert camera_height_or_default([float('nan')]) == DEFAULT_CAMERA_HEIGHT_M
  assert camera_height_or_default(None) == DEFAULT_CAMERA_HEIGHT_M
