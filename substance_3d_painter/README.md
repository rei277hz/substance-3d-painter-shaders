# Substance 3D Painter shader

`acescg_white_balance_view.glsl` is the new unlit shader. It keeps the
reference-normalized ACEScg Base Color workflow and adds CCT/Duv white balance,
separate reflection and emission exposure, and additive emission.

Generate the LUT with:

```sh
python3 substance_3d_painter/generate_whitepoint_lut.py
```

The generated `whitepoint_cct_duv_lut.exr` is a 257×257 RGB32F image whose
channels are Y-normalized CIE XYZ values. Import it as a linear data texture
and bind it to the shader's `whitepoint_lut_tex` sampler. Do not assign an
ACEScg or display color profile to this texture: its RGB values are XYZ data,
not display color. Use linear filtering and clamp addressing. If the Painter
version does not expose a custom `sampler2D` binding directly, create a texture
resource named `whitepoint_lut_tex` in the shader/resource panel and assign the
EXR there; the six channel samplers remain automatic.

Configure the channels as follows:

| Channel | Format and interpretation |
| --- | --- |
| Base Color | Scene-linear ACEScg/AP1 color, existing palette/decomposition contract |
| Emissive | Scene-linear ACEScg/AP1 color; black disables emission |
| User0 | Raw scalar reflectance scale, initialized to `Base Color Reference (Refl)` |
| User1 | Raw RGB16F data; R=CCT arc position, G=signed Duv position, B unused; initialize `(0.5,0.5,0)` |
| User2 | Raw scalar exposure data, `20·R−10` stops; initialize `0.5` |
| User3 | Raw scalar emission exposure data, `20·R−10` stops; initialize `0.5` |

Disable color management for User1–User3 and blend those channels as numeric
data. Base Color and Emissive retain the project's ACEScg interpretation.
Paint User1 before decoding it: ordinary layer blending produces the RG
coordinates, and the shader then looks up the target white point and applies a
CAT02 transform. Do not blend already decoded RGB white-point colors.

The LUT's center texel is the exact AP1/D60 white. Therefore User1 `(0.5,0.5)`
is an identity adaptation for every material. `User2=0.5` and `User3=0.5` are
unity exposure. Global exposure is applied after reflected and emitted terms
are added.
