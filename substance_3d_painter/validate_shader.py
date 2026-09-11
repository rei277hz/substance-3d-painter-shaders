"""Compile/render the maintained shader through a minimal Painter API adapter.

This is an OpenGL validation harness, not a Substance 3D Painter application
integration test.  It verifies the shader's arithmetic and resource contract
using Mesa's standalone EGL renderer when available.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import colour
import moderngl
import numpy as np
import OpenEXR

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent))
from substance_3d_painter import generate_whitepoint_lut as gen

ADAPTER = r"""#version 410 core
struct SamplerSparse { sampler2D tex; vec4 size; bool is_set; bool is_color; uvec3 lod_mask_select; };
struct SparseCoord { vec2 tex_coord; };
struct V2F { SparseCoord sparse_coord; };
vec4 textureSparse(SamplerSparse smp, SparseCoord coord) { return textureLod(smp.tex, coord.tex_coord, 0.0); }
vec3 test_albedo, test_diffuse, test_specular, test_emissive;
float test_alpha;
void albedoOutput(vec3 value) { test_albedo = value; }
void diffuseShadingOutput(vec3 value) { test_diffuse = value; }
void specularShadingOutput(vec3 value) { test_specular = value; }
void emissiveColorOutput(vec3 value) { test_emissive = value; }
void alphaOutput(float value) { test_alpha = value; }
uniform vec2 test_size;
out vec4 test_output;
"""
MAIN = r"""void main() {
    V2F inputs;
    inputs.sparse_coord.tex_coord = (gl_FragCoord.xy - vec2(0.5)) / test_size;
    shade(inputs);
    test_output = vec4(test_emissive + test_albedo * test_diffuse + test_specular, test_alpha);
}
"""
VERTEX = r"""#version 410 core
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""


def params(count: int) -> dict[str, np.ndarray]:
    return {
        "basecolor": np.full((count, 3), 0.18, dtype=np.float32),
        "emissive": np.zeros((count, 3), dtype=np.float32),
        "user0": np.full((count, 1), 0.5, dtype=np.float32),
        "user1": np.full((count, 1), 0.5, dtype=np.float32),
        "user2": np.full((count, 1), 0.5, dtype=np.float32),
        "user3": np.full((count, 3), 0.5, dtype=np.float32),
    }


def reference(values: dict[str, np.ndarray], lut: np.ndarray, refl: float = 0.5,
              global_ev: float = 0.0) -> np.ndarray:
    base = np.asarray(values["basecolor"], dtype=np.float64)
    emission = np.asarray(values["emissive"], dtype=np.float64)
    scale = np.maximum(values["user0"], 0.0) / refl if refl > 0.0 else np.zeros_like(values["user0"])
    combined = base * scale * np.exp2(20.0 * np.clip(values["user1"], 0.0, 1.0) - 10.0)
    combined += emission * np.exp2(20.0 * np.clip(values["user2"], 0.0, 1.0) - 10.0)
    delta = gen.sample_lut(lut, values["user3"][:, :2])
    target = gen.uv_to_xyz(gen.AP1_WHITE_UV + delta)
    out = []
    for color, white in zip(combined, target):
        cat = colour.adaptation.matrix_chromatic_adaptation_VonKries(
            gen.AP1_WHITE_XYZ, white, transform="CAT16"
        )
        out.append(np.linalg.solve(gen.AP1_TO_XYZ, cat @ (gen.AP1_TO_XYZ @ color)))
    return np.asarray(out) * np.exp2(np.clip(global_ev, -10.0, 10.0))


class Harness:
    def __init__(self, source: str):
        self.context = moderngl.create_standalone_context(backend="egl", require=410)
        source = re.sub(r"^import lib-sparse\.glsl\s*$", "", source, flags=re.MULTILINE)
        self.program = self.context.program(
            vertex_shader=VERTEX, fragment_shader=ADAPTER + source + MAIN
        )
        self.vao = self.context.vertex_array(self.program, [])

    def render(self, values: dict[str, np.ndarray], lut: np.ndarray, refl: float = 0.5,
               global_ev: float = 0.0, missing: tuple[str, ...] = (), half: bool = False) -> np.ndarray:
        count = len(values["user3"])
        self.program["test_size"].value = (count, 1)
        self.program["base_color_refl"].value = float(refl)
        self.program["global_exposure_stops"].value = float(global_ev)
        textures = []
        for unit, name in enumerate(("basecolor", "emissive", "user0", "user1", "user2", "user3")):
            data = np.asarray(values[name], dtype=np.float32).reshape(1, count, -1)
            if data.shape[-1] == 1:
                data = np.repeat(data, 3, axis=-1)
            texture = self.context.texture((count, 1), 3, data.tobytes(), dtype="f4")
            texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
            texture.use(location=unit)
            self.program[f"{name}_tex.tex"].value = unit
            self.program[f"{name}_tex.is_set"].value = name not in missing
            textures.append(texture)
        lut_data = np.ascontiguousarray(lut, dtype=np.float16 if half else np.float32)
        lut_texture = self.context.texture(
            (lut_data.shape[1], lut_data.shape[0]), 3, lut_data.tobytes(),
            dtype="f2" if half else "f4"
        )
        lut_texture.use(location=6)
        self.program["whitepoint_lut_tex"].value = 6
        target = self.context.texture((count, 1), 4, dtype="f4")
        framebuffer = self.context.framebuffer(color_attachments=[target])
        framebuffer.use()
        self.context.viewport = (0, 0, count, 1)
        self.vao.render(mode=moderngl.TRIANGLES, vertices=3)
        result = np.frombuffer(
            framebuffer.read(components=4, dtype="f4"), dtype=np.float32
        ).reshape(count, 4).copy()
        for texture in textures:
            texture.release()
        lut_texture.release()
        framebuffer.release()
        target.release()
        return result


def main() -> None:
    shader_path = ROOT / "acescg_white_balance_view.glsl"
    lut_path = ROOT / "whitepoint_cct_duv_lut.exr"
    with OpenEXR.File(str(lut_path)) as exr:
        lut = exr.channels()["RGB"].pixels.copy()
    if lut.shape != (257, 257, 3) or lut.dtype != np.float32:
        raise AssertionError("Maintained LUT is not 257x257 RGB32F.")
    if not np.all(lut[:, :, 2] == 0.0):
        raise AssertionError("Maintained LUT B payload is not reserved zero.")
    harness = Harness(shader_path.read_text())
    rng = np.random.default_rng(47821)
    values = params(128)
    values["basecolor"] = rng.uniform(-0.2, 8.0, (128, 3)).astype(np.float32)
    values["emissive"] = rng.uniform(0.0, 2.0, (128, 3)).astype(np.float32)
    values["user0"] = rng.uniform(0.0, 1.0, (128, 1)).astype(np.float32)
    values["user1"] = rng.uniform(0.0, 1.0, (128, 1)).astype(np.float32)
    values["user2"] = rng.uniform(0.0, 1.0, (128, 1)).astype(np.float32)
    values["user3"][:, :2] = rng.uniform(0.0, 1.0, (128, 2)).astype(np.float32)
    actual = harness.render(values, lut)
    expected = reference(values, lut)
    np.testing.assert_allclose(actual[:, :3], expected, atol=4e-5, rtol=4e-6)
    assert np.all(actual[:, 3] == 1.0)

    neutral = params(8)
    neutral["basecolor"] = np.array(
        [[.1, .3, .8], [0, 0, 0], [.5, .5, .5], [2, 4, 8],
         [-.1, .2, 1], [.001, .01, .1], [10, 0, 0], [.2, .4, .6]], dtype=np.float32
    )
    assert np.array_equal(harness.render(neutral, lut)[:, :3], neutral["basecolor"])

    bad = params(3)
    bad["user3"][:, 2] = np.array([0.0, np.nextafter(np.float32(.5), np.float32(1.0)), np.nan])
    assert np.all(harness.render(bad, lut)[:, :3] == 0.0)
    invalid_lut = lut.copy()
    invalid_lut[:, :, 2] = 1.0
    assert np.all(harness.render(params(2), invalid_lut)[:, :3] == 0.0)
    assert np.all(harness.render(params(3), lut, missing=("user3",))[:, :3] == .18)

    missing = params(3)
    missing["basecolor"][:] = 9.0
    fallback = harness.render(missing, lut, missing=("basecolor", "emissive", "user0", "user1", "user2"))
    assert np.allclose(fallback[:, :3], 0.5)

    edges = params(4)
    edges["user3"][:, :2] = [[0, 0.5], [1, 0.5], [0.5, 0], [0.5, 1]]
    clipped = {key: value.copy() for key, value in edges.items()}
    clipped["user3"][:, :2] = np.clip(clipped["user3"][:, :2], 0, 1)
    assert np.array_equal(harness.render(edges, lut), harness.render(clipped, lut))

    wrong = np.zeros((1, 1, 3), dtype=np.float32)
    assert np.all(harness.render(params(2), wrong)[:, :3] == 0.0)
    half_result = harness.render(values, lut, half=True)
    half_reference = reference(values, lut.astype(np.float16).astype(np.float32))
    np.testing.assert_allclose(half_result[:, :3], half_reference, atol=2e-3, rtol=2e-5)
    assert np.array_equal(harness.render(neutral, lut, half=True)[:, :3], neutral["basecolor"])

    emission = params(3)
    emission["basecolor"][:] = 0.0
    emission["emissive"][:] = [.3, .1, .8]
    before = harness.render(emission, lut)[:, :3]
    emission["user1"][:] = 1.0
    np.testing.assert_allclose(harness.render(emission, lut)[:, :3], before)
    emission["user2"][:] = .55
    np.testing.assert_allclose(harness.render(emission, lut)[:, :3], before * 2.0)

    gradient = params(1001)
    t = np.linspace(0.0, 1.0, len(gradient["user3"]))
    gradient["user3"][:, :2] = np.stack((.2 + .6 * t, .3 + .1 * t), axis=-1)
    gradient_result = harness.render(gradient, lut)[:, :3]
    assert np.isfinite(gradient_result).all()
    gradient_steps = np.linalg.norm(np.diff(gradient_result, axis=0), axis=1)
    assert float(np.max(gradient_steps)) < 0.001
    assert 0.95 < float(gradient_steps[500] / gradient_steps[499]) < 1.05

    report = {
        "scope": "OpenGL compile/link/render with a minimal Painter API adapter; Painter application integration not run.",
        "renderer": harness.context.info["GL_RENDERER"],
        "GL_version": harness.context.info["GL_VERSION"],
        "checks": 12,
        "passed": True,
    }
    (ROOT / "validation-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
