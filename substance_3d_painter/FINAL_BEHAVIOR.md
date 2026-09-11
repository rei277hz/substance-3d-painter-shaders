# Final Behavior: ACEScg Painter White Balance Shader

## Scope

`acescg_white_balance_view.glsl` is an unlit Substance 3D Painter surface
shader. It reconstructs a reference-normalized ACEScg image, applies a sampled
white-point adaptation, adds emission, and leaves display/output transforms to
Painter.

## Channel Contract

| Channel | Meaning | Missing-channel default |
| --- | --- | --- |
| Base Color | Scene-linear ACEScg/AP1 reference-normalized color | `(base_color_refl, base_color_refl, base_color_refl)` |
| Emissive | Scene-linear ACEScg/AP1 emission color | `(0, 0, 0)` |
| User0.R | Reflectance scale `r` | `0.5` |
| User1.R | Reflection exposure code, `20 * clamp(R, 0, 1) - 10` EV | `0.5` |
| User2.R | Emission exposure code, `20 * clamp(R, 0, 1) - 10` EV | `0.5` |
| User3.RG | White-balance CCT/Duv edit coordinates | `(0.5, 0.5)` |
| User3.B | Present-channel validity marker; must equal `0.5` exactly | `0.5` when User3 is absent |

User channels are raw data channels with color management disabled. User3 uses
RGB16F or RGB32F and is initialized to `(0.5, 0.5, 0.5)`. Missing User3 is
identity; a present User3 with nonfinite RGB or `B != 0.5` produces opaque
black. This gate is intentionally applied after Painter's texture/layer
sampling.

## Reconstruction

Let `A` be Base Color, `E` Emissive, `r` User0, `Refl` the shader reference,
and `W` the LUT white point:

```text
base_part = A * (max(r, 0) / Refl) * 2^(20 * clamp(User1.R, 0, 1) - 10)
emit_part = E * 2^(20 * clamp(User2.R, 0, 1) - 10)
combined  = base_part + emit_part
scene     = CAT16(AP1_white -> W, combined) * 2^clamp(global_exposure, -10, 10)
```

`Refl <= 0` disables only the base contribution. Finite signed RGB is
preserved; nonfinite inputs or final values produce opaque black. No display
transform, tone mapping, or final 0..1 clamp is performed by this shader.

## LUT Contract

The maintained LUT is a 257x257 RGB32F raw/data texture:

- R: `u - AP1_u`
- G: `v - AP1_v`
- B: reserved zero

The LUT uses the current implementation's CCT/Duv coordinate orientation and
relative Duv range of `AP1_Duv +/- 0.02`. Each fixed-Duv row is parameterized by
CIE 1960 `uv` arc length with a common symmetric span around the exact AP1
white. Consequently, row endpoints can have different effective CCT values;
strict row arc-speed is preferred over forcing every row to reach the nominal
2000..20000 K bounds.

LUT coordinates are clamped to `[0, 1]` and sampled with explicit level-0
bilinear `texelFetch`, independent of sampler filtering, mipmaps, and wrapping.
The center texel is exactly `(0, 0, 0)`, and `(0.5, 0.5)` is an exact identity
adaptation path.

## Resource and Failure Behavior

The custom sampler parameter defaults to `whitepoint_cct_duv_lut`. The LUT must
be imported as raw linear data with no gamma, gamut conversion, or display
transform. A missing or incorrectly sized LUT fails closed to opaque black.
The shader does not perform per-fragment corner fingerprints or orientation
autodetection; replacement assets must follow the documented contract.

## Non-Goals

- CAT16 adaptation is not the palette's display-side CAT02 plus J_HK scaling.
- The coordinate interpolation is not physical energy mixing and does not
  guarantee perceptual uniformity for arbitrary 2D paths, materials, or views.
- `another-implementation/` is reference-only and must never be modified or
  included in a commit.
