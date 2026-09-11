# Substance 3D Painter shader

`acescg_white_balance_view.glsl` is an unlit ACEScg reconstruction shader. It
decodes the existing reference-normalized Base Color, adds Emissive, adapts
the sum from ACES AP1/D60 to a painted CCT/Duv white with CAT16, and leaves the
Painter view/output transform in charge of display rendering.

Generate the maintained LUT with:

```sh
python3 substance_3d_painter/generate_whitepoint_lut.py
```

The command writes `whitepoint_cct_duv_lut.exr` and `lut-manifest.json`. The
LUT is a 257x257 RGB32F raw-data texture. R/G store `u - AP1_u` and
`v - AP1_v` in CIE 1960 UCS; B is reserved zero. Import it without gamma,
gamut conversion, or color management and assign it to the shader parameter
whose default resource name is `whitepoint_cct_duv_lut`.

The shader performs explicit level-0 bilinear `texelFetch` sampling, clamps
coordinates to `[0,1]`, and rejects missing or incorrectly sized LUTs. This
makes exact 0 and 1 endpoints safe even if the sampler's filtering, wrapping,
or mip state is unsuitable. Replacement LUTs must preserve the same 257x257
delta-UV contract.

## Channels

| Channel | Meaning | Missing default |
| --- | --- | --- |
| Base Color | Scene-linear ACEScg/AP1 reference-normalized color | `(Refl, Refl, Refl)` |
| Emissive | Scene-linear ACEScg/AP1 emission color | `(0, 0, 0)` |
| User0.R | Reflectance scale `r` | `0.5` |
| User1.R | Reflection exposure code, `20*clamp(R,0,1)-10` stops | `0.5` |
| User2.R | Emission exposure code, `20*clamp(R,0,1)-10` stops | `0.5` |
| User3.RG | CCT/Duv LUT coordinates | `(0.5, 0.5)` |
| User3.B | Present-channel validity marker | `0.5` when absent |

Use raw data channels with color management disabled for User0 through User3.
Use RGB16F or RGB32F for User3 and initialize it to `(0.5,0.5,0.5)`.
When User3 is present, every sampled component must be finite and B must equal
0.5 exactly; otherwise the shader outputs opaque black. User3 absence means
identity. Missing User0 is always 0.5 and does not depend on Refl.

The reconstruction is:

```text
reflected = BaseColor * (max(User0,0) / Refl) * 2^(20*clamp(User1,0,1)-10)
emitted   = Emissive * 2^(20*clamp(User2,0,1)-10)
combined  = reflected + emitted
scene     = CAT16(AP1/D60 -> LUT white, combined) * 2^clamp(Global,-10,10)
```

`Refl <= 0` disables only the reflected contribution. Finite signed RGB is
preserved; nonfinite inputs, intermediates, or final values fail closed to
opaque black. No final 0..1 clamp, tone map, or display transform is baked in.

The spectral generator integrates the bundled CIE 1931 2-degree observer from
360 to 830 nm at 1 nm with trapezoidal endpoint weights. It solves the AP1
anchor with SciPy `brentq`, and uses AP1-relative Duv +/-0.02 with a common
symmetric CIE 1960 arc-length span for every fixed-Duv row. The R axis is
intentionally reversed at LUT encoding time: higher red values move toward
lower-temperature/warmer whites, because that is the more intuitive UI
association for a channel called Red. G is unchanged: higher values move
toward green and lower values toward magenta. The exact center payload is
zero, so `(0.5,0.5)` is an identity adaptation.

Run the OpenGL arithmetic/resource validation with:

```sh
python3 substance_3d_painter/validate_shader.py
```

This uses a minimal Painter API adapter and Mesa standalone EGL; it is not a
Substance 3D Painter application integration test.
