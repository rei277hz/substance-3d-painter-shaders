/*
UNLIT ACEScg: REFERENCE BASE COLOR + CAT16 WHITE BALANCE + EMISSION

Base Color and Emissive are scene-linear ACEScg/AP1 values. User channels are
raw data channels. User3.RG indexes whitepoint_cct_duv_lut, whose RGB payload is
delta CIE 1960 uv in R/G and reserved zero in B.

Missing channels use the documented defaults. A present User3 channel is valid
only when all sampled components are finite and B is exactly 0.5; invalid data
and missing or incorrectly sized LUT resources render opaque black.
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
//:   "description": "Raw linear 257x257 RGB32F/EXR; R/G are delta CIE 1960 uv and B is reserved zero."
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

const ivec2 WHITEPOINT_LUT_SIZE = ivec2(257, 257);
const vec2 AP1_WHITE_UV = vec2(0.200777695251, 0.316136864378);
const vec3 AP1_WHITE_XYZ = vec3(0.952646077, 1.0, 1.008825183);

// CAT16 and ACES AP1 -> XYZ, stored as GLSL columns.
const mat3 XYZ_TO_CAT16 = mat3(
    vec3(0.401288, -0.250268, -0.002079),
    vec3(0.650173, 1.204414, 0.048952),
    vec3(-0.051461, 0.045854, 0.953127)
);
const mat3 AP1_TO_XYZ = mat3(
    vec3(0.662454181109, 0.272228716781, -0.005574649490),
    vec3(0.134004206456, 0.674081765811, 0.004060733529),
    vec3(0.156187687005, 0.053689517408, 1.010339100313)
);
const mat3 AP1_TO_CAT16 = mat3(
    vec3(0.443117551942, 0.161829374718, 0.006635548957),
    vec3(0.491835074515, 0.778522752021, 0.036589450621),
    vec3(0.045590658703, 0.071903715474, 0.965284970474)
);
const mat3 CAT16_TO_AP1 = mat3(
    vec3(2.93357230849, -0.610066853611, 0.002958865446),
    vec3(-1.85327316260, 1.67440404869, -0.050729101710),
    vec3(-0.000503755609, -0.095912114458, 1.03960254714)
);
const vec3 CAT16_AP1_WHITE = vec3(0.980543285160, 1.012255842210, 1.008509970300);

bool finiteFloat(float value)
{
    return !isnan(value) && !isinf(value);
}

bool finiteVec2(vec2 value)
{
    return all(not(isnan(value))) && all(not(isinf(value)));
}

bool finiteVec3(vec3 value)
{
    return all(not(isnan(value))) && all(not(isinf(value)));
}

void outputBlack()
{
    albedoOutput(vec3(0.0));
    diffuseShadingOutput(vec3(0.0));
    specularShadingOutput(vec3(0.0));
    emissiveColorOutput(vec3(0.0));
    alphaOutput(1.0);
}

void outputUnlit(vec3 value)
{
    albedoOutput(vec3(0.0));
    diffuseShadingOutput(vec3(0.0));
    specularShadingOutput(vec3(0.0));
    emissiveColorOutput(value);
    alphaOutput(1.0);
}

vec3 sampleWhitepointLut(vec2 coordinate)
{
    vec2 clamped = clamp(coordinate, vec2(0.0), vec2(1.0));
    vec2 position = clamped * vec2(WHITEPOINT_LUT_SIZE - ivec2(1));
    ivec2 lower = ivec2(floor(position));
    ivec2 upper = min(lower + ivec2(1), WHITEPOINT_LUT_SIZE - ivec2(1));
    vec2 weight = position - vec2(lower);
    vec3 c00 = texelFetch(whitepoint_lut_tex, lower, 0).rgb;
    vec3 c10 = texelFetch(whitepoint_lut_tex, ivec2(upper.x, lower.y), 0).rgb;
    vec3 c01 = texelFetch(whitepoint_lut_tex, ivec2(lower.x, upper.y), 0).rgb;
    vec3 c11 = texelFetch(whitepoint_lut_tex, upper, 0).rgb;
    return mix(mix(c00, c10, weight.x), mix(c01, c11, weight.x), weight.y);
}

vec3 targetWhiteXyz(vec2 delta_uv)
{
    float u = AP1_WHITE_UV.x + delta_uv.x;
    float v = AP1_WHITE_UV.y + delta_uv.y;
    float denominator = 2.0 * u - 8.0 * v + 4.0;
    // Y is normalized to one; this is the inverse CIE 1960 uv conversion.
    float x = 3.0 * u / denominator;
    float y = 2.0 * v / denominator;
    return vec3(x / y, 1.0, (1.0 - x - y) / y);
}

vec3 adaptCat16(vec3 color, vec3 target_xyz)
{
    vec3 target_cone = XYZ_TO_CAT16 * target_xyz;
    vec3 source_cone = CAT16_AP1_WHITE;
    vec3 cone_scale = target_cone / source_cone;
    return CAT16_TO_AP1 * (cone_scale * (AP1_TO_CAT16 * color));
}

void shade(V2F inputs)
{
    if (any(notEqual(textureSize(whitepoint_lut_tex, 0), WHITEPOINT_LUT_SIZE)))
    {
        outputBlack();
        return;
    }

    vec3 user3 = user3_tex.is_set
        ? textureSparse(user3_tex, inputs.sparse_coord).rgb
        : vec3(0.5);
    if (!finiteVec3(user3) || (user3_tex.is_set && user3.b != 0.5))
    {
        outputBlack();
        return;
    }

    vec3 base_color = basecolor_tex.is_set
        ? textureSparse(basecolor_tex, inputs.sparse_coord).rgb
        : vec3(base_color_refl);
    vec3 emission_color = emissive_tex.is_set
        ? textureSparse(emissive_tex, inputs.sparse_coord).rgb
        : vec3(0.0);
    float user0 = user0_tex.is_set
        ? textureSparse(user0_tex, inputs.sparse_coord).r
        : 0.5;
    float user1 = user1_tex.is_set
        ? textureSparse(user1_tex, inputs.sparse_coord).r
        : 0.5;
    float user2 = user2_tex.is_set
        ? textureSparse(user2_tex, inputs.sparse_coord).r
        : 0.5;

    if (!finiteVec3(base_color) || !finiteVec3(emission_color)
        || !finiteFloat(user0) || !finiteFloat(user1) || !finiteFloat(user2)
        || !finiteFloat(base_color_refl) || !finiteFloat(global_exposure_stops))
    {
        outputBlack();
        return;
    }

    vec3 lut_payload = sampleWhitepointLut(user3.rg);
    if (!finiteVec3(lut_payload) || lut_payload.b != 0.0)
    {
        outputBlack();
        return;
    }
    vec2 delta_uv = lut_payload.rg;
    if (!finiteVec2(delta_uv))
    {
        outputBlack();
        return;
    }

    float reflectance_scale = base_color_refl > 0.0
        ? max(user0, 0.0) / base_color_refl
        : 0.0;
    float reflection_ev = 20.0 * clamp(user1, 0.0, 1.0) - 10.0;
    float emission_ev = 20.0 * clamp(user2, 0.0, 1.0) - 10.0;
    vec3 reflected = base_color * reflectance_scale * exp2(reflection_ev);
    vec3 emitted = emission_color * exp2(emission_ev);
    vec3 combined = reflected + emitted;

    vec3 scene_linear_acescg;
    if (all(equal(user3.rg, vec2(0.5))))
    {
        scene_linear_acescg = combined;
    }
    else
    {
        vec3 target_xyz = targetWhiteXyz(delta_uv);
        if (!finiteVec3(target_xyz) || any(lessThanEqual(target_xyz, vec3(0.0))))
        {
            outputBlack();
            return;
        }
        scene_linear_acescg = adaptCat16(combined, target_xyz);
    }
    scene_linear_acescg *= exp2(clamp(global_exposure_stops, -10.0, 10.0));
    outputUnlit(finiteVec3(scene_linear_acescg) ? scene_linear_acescg : vec3(0.0));
}
