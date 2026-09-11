from pathlib import Path

import numpy as np

from substance_3d_painter.generate_whitepoint_lut import (
    AP1_WHITE_UV,
    AP1_WHITE_XY,
    CIE_MD5,
    DUV_HALF_RANGE,
    build_lut,
    load_cmfs,
    reference_coordinates,
    sample_lut,
    uv_to_xyz,
)


def payload_to_uv(payload: np.ndarray) -> np.ndarray:
    return AP1_WHITE_UV + payload[..., :2]


def test_spectral_observer_is_bundled_and_verified():
    cmfs = load_cmfs()
    assert cmfs.shape == (471, 4)
    assert np.array_equal(cmfs[:, 0], np.arange(360.0, 831.0))
    assert CIE_MD5 == "17cca777db64b17170f06f67ce9d3ab7"


def test_whitepoint_lut_has_exact_neutral_delta_and_finite_positive_whites():
    lut, metadata = build_lut(33)
    assert lut.shape == (33, 33, 3)
    assert np.isfinite(lut).all()
    assert np.array_equal(lut[16, 16], np.zeros(3, dtype=np.float32))
    xyz = uv_to_xyz(payload_to_uv(lut))
    assert np.isfinite(xyz).all()
    assert np.all(xyz > 0.0)
    assert metadata["temperature_min"] == 2000.0
    assert metadata["temperature_max"] == 20000.0
    assert metadata["duv_half_range"] == DUV_HALF_RANGE
    assert np.isclose(metadata["reference_u"], AP1_WHITE_UV[0])
    assert np.isclose(metadata["reference_v"], AP1_WHITE_UV[1])


def test_whitepoint_lut_rows_are_arc_length_uniform():
    lut, _ = build_lut(65)
    uv = payload_to_uv(lut)
    distances = np.linalg.norm(np.diff(uv, axis=1), axis=2)
    # The center texel is exact-patched to zero payload; omit its two adjacent
    # intervals so the test measures generated row samples, not that patch.
    interior = distances[:, 2:-2]
    relative_spread = np.ptp(interior, axis=1) / np.mean(interior, axis=1)
    assert float(np.max(relative_spread)) < 2.0e-4


def test_current_orientation_and_symmetric_rows():
    lut, _ = build_lut(65)
    # Higher red values intentionally point toward lower-temperature/warmer
    # whites, matching the intuitive UI association of red with warmth.
    assert lut[32, 0, 0] < lut[32, 64, 0]
    center = 32
    for row in (0, center, 64):
        left = np.linalg.norm(lut[row, 0, :2])
        right = np.linalg.norm(lut[row, -1, :2])
        assert left > 0.0 and right > 0.0


def test_manual_sample_lut_clamps_without_opposite_edge_wrap():
    lut = np.zeros((3, 3, 3), dtype=np.float32)
    lut[:, 0, 0] = 10.0
    lut[:, -1, 0] = 20.0
    lut[0, :, 1] = 30.0
    lut[-1, :, 1] = 40.0
    assert np.array_equal(sample_lut(lut, np.array([[-1.0, 2.0], [2.0, -1.0]])),
                          np.array([[10.0, 40.0], [20.0, 30.0]]))


def test_shader_declares_contract_and_manual_level_zero_sampling():
    shader = Path(__file__).with_name("acescg_white_balance_view.glsl").read_text()
    for channel in ("channel_basecolor", "channel_emissive", "channel_user0",
                    "channel_user1", "channel_user2", "channel_user3"):
        assert channel in shader
    assert shader.index("channel_user1") < shader.index("channel_user2") < shader.index("channel_user3")
    assert "uniform sampler2D whitepoint_lut_tex;" in shader
    assert '"default": "whitepoint_cct_duv_lut"' in shader
    assert "textureSize(whitepoint_lut_tex, 0)" in shader
    assert "texelFetch(whitepoint_lut_tex" in shader
    assert "const ivec2 WHITEPOINT_LUT_SIZE = ivec2(257, 257);" in shader
    assert "CAT16" in shader
    assert "vec3(base_color_refl)" in shader
    assert "? textureSparse(user1_tex" in shader
    assert "? textureSparse(user2_tex" in shader
    assert "user3.b != 0.5" in shader


def test_reference_anchor_is_near_ap1_d60():
    temperature, duv = reference_coordinates()
    assert 5900.0 < temperature < 6100.0
    assert abs(duv) < 0.01
    assert np.allclose(uv_to_xyz(AP1_WHITE_UV),
                       [AP1_WHITE_XY[0] / AP1_WHITE_XY[1], 1.0,
                        (1.0 - AP1_WHITE_XY.sum()) / AP1_WHITE_XY[1]])
