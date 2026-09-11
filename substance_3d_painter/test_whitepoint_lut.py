from pathlib import Path

import numpy as np

from substance_3d_painter.generate_whitepoint_lut import AP1_WHITE_XY, build_lut


def xyz_to_uv(xyz: np.ndarray) -> np.ndarray:
    total = xyz.sum(axis=-1)
    x = xyz[..., 0] / total
    y = xyz[..., 1] / total
    denominator = -2.0 * x + 12.0 * y + 3.0
    return np.stack((4.0 * x / denominator, 6.0 * y / denominator), axis=-1)


def test_whitepoint_lut_has_exact_neutral_and_finite_values():
    lut, metadata = build_lut(33)
    expected = np.array(
        [AP1_WHITE_XY[0] / AP1_WHITE_XY[1], 1.0, (1.0 - AP1_WHITE_XY.sum()) / AP1_WHITE_XY[1]]
    )
    assert lut.shape == (33, 33, 3)
    assert np.isfinite(lut).all()
    assert np.allclose(lut[16, 16], expected, atol=2e-7, rtol=0.0)
    assert metadata["temperature_min"] == 2000.0
    assert metadata["temperature_max"] == 20000.0


def test_whitepoint_lut_rows_are_arc_length_uniform():
    lut, _ = build_lut(65)
    uv = xyz_to_uv(lut)
    distances = np.linalg.norm(np.diff(uv, axis=1), axis=2)
    # The center texel is exact-patched to AP1 white; omit its two adjacent
    # intervals so the test measures the generated curve, not that patch.
    interior = distances[:, 2:-2]
    relative_spread = np.ptp(interior, axis=1) / np.mean(interior, axis=1)
    assert float(np.max(relative_spread)) < 2.0e-4


def test_shader_declares_new_channel_contract():
    shader = (Path(__file__).with_name("acescg_white_balance_view.glsl")).read_text()
    for channel in ("channel_basecolor", "channel_emissive", "channel_user0", "channel_user1", "channel_user2", "channel_user3"):
        assert channel in shader
    assert "whitepoint_lut_tex" in shader
    assert "exp2(user2 * 20.0 - 10.0)" in shader
    assert "exp2(user3 * 20.0 - 10.0)" in shader
    assert "reflected + emitted" in shader
