/*
UNLIT ACEScg: REFERENCE BASE COLOR + CCT/DUV WHITE BALANCE + EMISSION

The companion whitepoint_cct_duv_lut.exr stores Y-normalized XYZ in RGB. The
LUT is sampled with User3.RG and maps raw paint parameters to a target white
point. User3=(0.5,0.5) is the exact ACEScg/AP1 D60 white and therefore an
identity chromatic adaptation.

CHANNELS
--------

Base Color:
    Existing reference-normalized scene-linear ACEScg/AP1 color. Keep the
    Base Color Reference (Refl) used by the palette or decomposition tool.

Emissive:
    Scene-linear ACEScg/AP1 emission color. Black means no emission.

User0:
    Reflectance scale r. The shader applies r / base_color_refl.

User1:
    Raw scalar data in R. Reflection exposure in stops is User1.R * 20 - 10.
    0.5 is unity.

User2:
    Raw scalar data in R. Emission exposure in stops is User2.R * 20 - 10.
    0.5 is unity. Use black Emissive or a separate mask for exact zero;
    -10 stops is a small nonzero value.

User3:
    Raw RGB16F data; R and G are the CCT/Duv coordinates for the LUT.
    (0.5,0.5) is neutral. Store and blend these values as data, before LUT
    decoding. B is reserved and ignored.

The shader is intentionally unlit. It outputs the sum of adapted reflected
and emitted scene-linear contributions and leaves the Painter display/output
transform in charge of view rendering.
*/

import lib-sparse.glsl

//: param auto channel_basecolor
uniform SamplerSparse basecolor_tex;

//: param auto channel_emissive
uniform SamplerSparse emissive_tex;

//: param auto channel_user0
uniform SamplerSparse user0_tex;

//: param auto channel_user1
uniform SamplerSparse user1_tex;

//: param auto channel_user2
uniform SamplerSparse user2_tex;

//: param auto channel_user3
uniform SamplerSparse user3_tex;

//: param custom {
//:   "default": "whitepoint_cct_duv_lut",
//:   "label": "Whitepoint CCT/Duv LUT",
//:   "usage": "texture",
//:   "group": "View Controls",
//:   "description": "Linear, non-color-managed 257x257 RGB32F/EXR; RGB stores Y-normalized XYZ data."
//: }
uniform sampler2D whitepoint_lut_tex;

//: param custom {
//:   "default": 0.5,
//:   "label": "Base Color Reference (Refl)",
//:   "min": 0.0001,
//:   "max": 1.2,
//:   "step": 0.01,
//:   "group": "View Controls",
//:   "description": "Reference neutral used to decode User0 reflectance scale."
//: }
uniform float base_color_refl;

//: param custom {
//:   "default": 0.0,
//:   "label": "Global Exposure (stops)",
//:   "min": -10.0,
//:   "max": 10.0,
//:   "step": 0.1,
//:   "group": "View Controls",
//:   "description": "Exposure applied after reflected and emitted contributions are added."
//: }
uniform float global_exposure_stops;

const vec3 AP1_TO_XYZ_0 = vec3(0.662454181109, 0.134004206456, 0.156187687005);
const vec3 AP1_TO_XYZ_1 = vec3(0.272228716781, 0.674081765811, 0.053689517408);
const vec3 AP1_TO_XYZ_2 = vec3(-0.005574649490, 0.004060733529, 1.010339100313);
const vec3 XYZ_TO_AP1_0 = vec3(1.641023379694, -0.324803294185, -0.236424695238);
const vec3 XYZ_TO_AP1_1 = vec3(-0.663662858723, 1.615331591657, 0.016756347686);
const vec3 XYZ_TO_AP1_2 = vec3(0.011721894328, -0.008284441996, 0.988394858539);

const vec3 CAT02_0 = vec3(0.7328, 0.4296, -0.1624);
const vec3 CAT02_1 = vec3(-0.7036, 1.6975, 0.0061);
const vec3 CAT02_2 = vec3(0.0030, 0.0136, 0.9834);
const vec3 CAT02_INV_0 = vec3(1.096123820836, -0.278869000218, 0.182745179383);
const vec3 CAT02_INV_1 = vec3(0.454369041975, 0.473533154307, 0.072097803717);
const vec3 CAT02_INV_2 = vec3(-0.009627608738, -0.005698031216, 1.015325639955);
const float WHITEPOINT_LUT_SIZE = 257.0;

vec3 rows(vec3 row0, vec3 row1, vec3 row2, vec3 value)
{
    return vec3(dot(row0, value), dot(row1, value), dot(row2, value));
}

vec3 adapt_ap1(vec3 color, vec3 target_xyz)
{
    // AP1 white is AP1=(1,1,1), transformed through the same matrices used
    // for Base Color. Target and source are both normalized to Y=1.
    vec3 source_white_xyz = rows(AP1_TO_XYZ_0, AP1_TO_XYZ_1, AP1_TO_XYZ_2, vec3(1.0));
    vec3 source_cone = rows(CAT02_0, CAT02_1, CAT02_2, source_white_xyz);
    vec3 target_cone = rows(CAT02_0, CAT02_1, CAT02_2, target_xyz);
    vec3 cone_scale = target_cone / max(source_cone, vec3(1.0e-6));
    vec3 xyz = rows(AP1_TO_XYZ_0, AP1_TO_XYZ_1, AP1_TO_XYZ_2, color);
    vec3 adapted_cone = rows(CAT02_0, CAT02_1, CAT02_2, xyz) * cone_scale;
    vec3 adapted_xyz = rows(CAT02_INV_0, CAT02_INV_1, CAT02_INV_2, adapted_cone);
    return rows(XYZ_TO_AP1_0, XYZ_TO_AP1_1, XYZ_TO_AP1_2, adapted_xyz);
}

vec2 whitepoint_lut_coordinate(vec2 coordinate)
{
    // The LUT stores parameters at texel centers for coordinates 0..1.
    // Mapping to centers prevents linear+repeat sampling at an exact edge
    // from blending the first texel with the opposite edge of the LUT.
    vec2 clamped = clamp(coordinate, vec2(0.0), vec2(1.0));
    return (clamped * (WHITEPOINT_LUT_SIZE - 1.0) + 0.5) / WHITEPOINT_LUT_SIZE;
}

void shade(V2F inputs)
{
    vec3 base_color = textureSparse(basecolor_tex, inputs.sparse_coord).rgb;
    vec3 emission_color = textureSparse(emissive_tex, inputs.sparse_coord).rgb;
    float user0 = textureSparse(user0_tex, inputs.sparse_coord).r;
    float user1 = textureSparse(user1_tex, inputs.sparse_coord).r;
    float user2 = textureSparse(user2_tex, inputs.sparse_coord).r;
    vec2 user3 = textureSparse(user3_tex, inputs.sparse_coord).rg;

    // Clamp only the lookup coordinate. The raw channels remain blendable data.
    vec3 target_xyz = texture(whitepoint_lut_tex, whitepoint_lut_coordinate(user3)).rgb;
    vec3 adapted_base = adapt_ap1(base_color, target_xyz);
    vec3 adapted_emission = adapt_ap1(emission_color, target_xyz);

    float reflectance_scale = base_color_refl > 0.0 ? user0 / base_color_refl : 0.0;
    float reflection_exposure = exp2(user1 * 20.0 - 10.0);
    float emission_exposure = exp2(user2 * 20.0 - 10.0);
    vec3 reflected = adapted_base * reflectance_scale * reflection_exposure;
    vec3 emitted = adapted_emission * emission_exposure;
    vec3 scene_linear_acescg = (reflected + emitted) * exp2(global_exposure_stops);

    albedoOutput(vec3(0.0));
    diffuseShadingOutput(vec3(0.0));
    specularShadingOutput(vec3(0.0));
    emissiveColorOutput(scene_linear_acescg);
    alphaOutput(1.0);
}
