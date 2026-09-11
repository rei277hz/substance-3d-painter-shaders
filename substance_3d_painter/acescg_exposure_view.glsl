/*
UNLIT ACEScg: REFERENCE BASE COLOR + REFLECTANCE + EXPOSURE

Designed for use with:
    index.html     - Refl / Hue / Sat palette
    decompose.html - Reference-normalized base and exposure decomposition

The tools perform perceptual normalization. This shader only combines their
scene-linear color values with a reflectance scale and exposure, then leaves
the display transform to Painter.

CHANNELS
--------

Base Color:
    Reference-normalized color A, sampled as scene-linear ACEScg/AP1.

    Author or generate this color at a common reference Refl using the
    palette or decomposition tool. Its defining property is an equal
    modCAM16-HK J_HK match to the neutral (Refl, Refl, Refl), AFTER both
    colors pass through the selected ACES 2.0 view.

    This does not mean that its RGB average, luminance, or individual
    channels equal Refl. It also does not mean the color is already
    display-transformed.

    All colors in a base map should use the same reference Refl for this
    single-reference workflow.

User0 - Reflectance control:
    Raw scalar/data channel, read from R. Intended range: 0..1.
    This channel no longer contains exposure.

    Let r be the sampled value. The shader applies the linear scale:
        R = r / Refl

    Therefore:
        User0 = Refl -> unity scale; preserve the reference base color
        User0 = 0    -> black
        User0 > Refl -> increase the scene-linear RGB values

    R is a scale factor, not reflectance itself, and may exceed 1.

    The channel's reflectance interpretation is calibrated by the neutral
    case: if Base Color is (Refl, Refl, Refl), the result before either
    exposure control is exactly (r, r, r).

    A chromatic base stays chromatic. This multiplication does not solve
    a new palette color whose perceptual Refl is necessarily r, nor does
    it recover a measured physical diffuse reflectance.

User1 - Material exposure:
    Raw scalar/data channel, read from R. Intended range: 0..1.
    Stores exposure encoded linearly in stops:
        material_stops = User1 * 20 - 10

        User1 = 0.0 -> -10 stops
        User1 = 0.5 ->   0 stops
        User1 = 1.0 -> +10 stops

    This matches the decomposition tool's "Exposure EXR (norm EV)",
    NOT its direct-scalar "Exposure EXR".

    Existing projects that stored exposure in User0 must move that
    content to User1. Changing shader bindings does not migrate layers.

CUSTOM CONTROLS
---------------

Base Color Reference (Refl) / base_color_refl:
    UI range: 0..1. Default: 0.5.

    Set this to the same numeric Refl used to author or decompose the
    Base Color map. Refl is the scene-linear value of the reference
    neutral, not an encoded display-gray value.

    Valid normalization requires 0 < Refl <= 1 for this shader.
    At Refl = 0, the implementation uses a zero scale to avoid division
    by zero. That is a safe-black fallback, not a valid normalization.

    Changing this control rescales existing colors. It does not re-solve
    their perceptual normalization.

Global Exposure (stops) / global_exposure_stops:
    Range: -10..+10. Default: 0.

    Added to User1's decoded material exposure. Both exposures are
    applied in scene-linear space before the display transform.

EVALUATION
----------

    For Refl > 0:

        R = User0 / Refl
        material_stops = User1 * 20 - 10
        total_stops = material_stops + global_exposure_stops

        scene_linear_acescg =
            BaseColor * R * exp2(total_stops)

    The result is sent through the emissive output without environment
    lighting or a BRDF contribution. The shader does not clamp the result
    to display range.

    Reference-authoring / unmodified-base setup:
        User0 = Refl
        User1 = 0.5
        Global Exposure = 0

    For example, at Refl = 0.5, User0 = 0.5 is unity gain.
    User0 = 1.0 would instead double the base color.

PAINTER COLOR MANAGEMENT AND REQUIRED VIEW
-----------------------------------------

    Use an ACEScg working space. Ensure Base Color resources are
    interpreted correctly so their sampled values are the intended
    linear ACEScg/AP1 values.

    Treat User0 and User1 as raw numeric data: no display encoding,
    gamma decoding, or color-space conversion of their scalar values.

    Select an OCIO configuration and display/view matching the ACES 2.0
    profile used in the palette or decomposition tool:

        ACES 2.0 - SDR 100 nits (Rec.709)
        ACES 2.0 - SDR 100 nits (P3 D65)
        ACES 2.0 - HDR 1000 nits (P3 D65)
        ACES 2.0 - HDR 1000 nits (Rec.2020)

    The decomposition tool defaults to the P3 D65 HDR 1000-nit profile.
    That default does not automatically configure Painter.

    Match the actual profile, not merely a view with "ACES" in its name.
    An ACES 1.x view or an approximate ACES-style tone mapper is not the
    same normalization contract.

    The palette's Rec.2020 HDR mode is explicitly P3-D65-limited.
    Its source-gamut labels do not change this shader's ACEScg working
    space.

    Painter/OCIO applies the output transform and display encoding after
    this shader. Do not bake that transform into Base Color or apply it
    again inside the shader.

    During reference comparisons, reset any additional viewport exposure,
    grading, or post-processing. Use appropriate display and viewing
    conditions for the selected output.

USING THE PALETTE - index.html
-----------------------------

    1. Select an ACES profile matching the intended Painter view.

    2. Choose a common positive Refl within this shader's supported range.
       Use Hue and Sat to select available colors on that reference slice.

    3. Transfer the palette's linear ACEScg/AP1 readout into Base Color
       through a correctly interpreted color-entry or texture workflow.
       Do not treat encoded/hex numbers as linear AP1 values, or use a
       display screenshot as the reference base.

       An unavailable palette sample is not a valid clipped substitute.
       Choose an available color rather than copying its clipped preview.

    4. Set the shader's Refl to the same value. Initialize User0 to Refl,
       User1 to 0.5, and Global Exposure to 0.

    5. Paint User0 for the neutral-calibrated reflectance scale and User1
       for material exposure.

    Refl is profile-local:
        Switching ACES profiles preserves the pre-adaptation source color,
        but solves its Refl again. Refl can change while the ACEScg value
        remains unchanged.

        Colors sharing one Refl under one view need not share one Refl
        under another. Re-author or re-normalize for a new view when that
        common-reference property is required; changing the shader
        control alone does not perform this operation.

    Palette white balance is display-side:
        Temp/Tint apply CAT02 after the forward view, followed by a
        positive scale chosen to preserve J_HK. They do not bake white
        balance into the retained source color or its Refl/Hue/Sat state.

        For straightforward visual comparisons, use Temp = 6500 K and
        Tint = 0, which is the tool's exact identity setting.

        This shader does not reproduce the palette's optional display
        adaptation. Matching a non-identity preview requires the same
        display-side CAT02 and J_HK-preserving scale downstream; a
        scene-linear RGB multiplier is not an equivalent replacement.

    Direct sRGB is a separate workflow:
        The palette's "No view transform" mode uses linear Rec.709, not
        ACEScg. Use the palette's conversion to an ACES profile before
        transferring its ACEScg readout.

        That conversion uses the ACES 2.0 Rec.709 100-nit view and its
        inverse as the explicit bridge. Do not simply relabel direct
        linear Rec.709 numbers as ACEScg.

USING THE DECOMPOSITION TOOL - decompose.html
-------------------------------------------

    Interpret the source correctly, then select the intended ACES profile
    and a positive reference Refl matching this shader.

    The solver works in linear ACES2065-1/AP0. Its reconstruction target
    Q is the selected view's inverse of the un-tone-mapped display-
    reference value after source interpretation/conversion. Q must not
    be confused with the uploaded file's raw RGB samples.

    For each nonblack solution, it finds an AP0 base B and scalar s:

        Q = B * s
        e = log2(s)
        J_HK(f(B)) = J_HK(f((Refl, Refl, Refl)))

    Here f is the selected forward view using the appropriate AP0 input
    path. The exported base is B converted linearly from AP0 to AP1.

    Import and initialize:
        Base EXR:
            Load into Base Color as linear ACEScg/AP1 color.

        Exposure EXR (norm EV):
            Map its single "exposure" channel into User1 as raw data.
            Preserve its numeric values during any channel remapping.

        User0:
            Fill with the decomposition's Refl for unity scale.
            The tool does not export a separate User0 reflectance map.

        Base Color Reference:
            Set to the decomposition's Refl.

        Global Exposure:
            Set to 0 for reconstruction.

    For s > 0 with e within [-10, +10], decoding User1 recovers s:

        norm_EV = clamp(e, -10, 10) / 20 + 0.5
        s = exp2(norm_EV * 20 - 10)

    With User0 = Refl and Global Exposure = 0, the shader therefore
    reconstructs Q converted to ACEScg, subject to solver tolerance,
    fp16 storage, texture precision, and sampling/filtering.

    Important limitations:

    - Clipped exposure:
        If e is outside +/-10 stops, norm EV is clipped and counted.
        This shader cannot recover the lost exposure from User1.

        "Exposure EXR" instead stores the directly solved scalar s in
        three identical RGB channels. It avoids the norm-EV clamp,
        although it still has fp16 storage limits.

        Do not plug that direct scalar into User1: this shader would
        incorrectly interpret it as stop-encoded data. Direct-scalar
        reconstruction requires a different decode path or an external
        multiplication of Base EXR by the scalar exposure.

    - Exact black:
        For Q = 0, the tool explicitly stores a neutral base,
        norm EV = 0, and direct scalar s = 0.

        This shader decodes User1 = 0 as exp2(-10), not zero.
        With unity reflectance scale, it therefore produces a small
        nonzero value for that exported neutral base.

        To preserve exact black, use known black pixels to mask User0
        to zero, or use a direct-scalar reconstruction path.

        User1 == 0 is NOT a reliable black mask: it also represents
        valid -10-stop exposure and clipped darker nonblack values.

    - Processing and precision:
        Optional blur, gamut projection, and negative-AP0 clamping
        cannot be undone by this shader. Consult the decomposition
        report for clipping, lossy operations, non-finite values,
        residuals, and tolerance exceedances.

    - Preview images are not reconstruction textures:
        The decomposition source, base, and exposure previews use the
        fixed ACES 2.0 SDR 100-nit P3-D65 rendering path, regardless of
        the selected solve profile.

        The exposure preview renders the neutral Refl * s, using the
        direct scalar, not the norm-EV value.

        Consequently, an HDR solve should not be judged by expecting
        its JPEG previews to match Painter's HDR view. Use the EXRs
        and matching view for reconstruction.

modCAM16-HK AND THE REFERENCE DESIGN
----------------------------------

    For a palette ACES profile p, let:
        A      = linear ACEScg/AP1 color
        C(r)   = (r, r, r)
        f_p    = complete forward ACES view before display encoding

    The reference-color contract is:

        J_HK(f_p(A)) = J_HK(f_p(C(Refl)))

    J_HK is the tools' modCAM16-HK appearance correlate used for this
    perceptual match. The Helmholtz-Kohlrausch contribution accounts for
    chromatic colors appearing brighter than neutrals of equal luminance.

    The tools evaluate the viewed color through their colorimetric/model
    pipeline. This is not a comparison of scene-linear AP1 magnitudes,
    encoded display RGB, ordinary luminance Y, or unmodified CAM16 J.

    Use the tools' actual model implementation and viewing-condition
    parameters when reproducing the normalization.

    The equality is established at the reference level. In general:

        J_HK(f_p(A * r / Refl)) != J_HK(f_p(C(r)))

    Likewise, equal-J_HK reference colors need not remain equal-J_HK
    after a shared exposure change. The complete view and appearance
    evaluation are nonlinear.

    This is intentional separation of responsibilities:
        The tools establish the perceptual reference base.
        User0 supplies a neutral-calibrated linear reflectance scale.
        User1 and Global Exposure supply multiplicative exposure.
        Painter supplies the selected display transform.

    The shader itself does not evaluate modCAM16-HK, solve a new Refl,
    or enforce perceptual equality after editing those multipliers.
*/

import lib-sparse.glsl

//: param auto channel_basecolor
uniform SamplerSparse basecolor_tex;

//: param auto channel_user0
uniform SamplerSparse user0_tex;

//: param auto channel_user1
uniform SamplerSparse user1_tex;

//: param custom {
//:   "default": 0.5,
//:   "label": "Base Color Reference (Refl)",
//:   "min": 0.0,
//:   "max": 1.0,
//:   "step": 0.01,
//:   "group": "View Controls",
//:   "description": "Scene-linear neutral reference for the Base Color palette. Reflectance scale is User0 / Refl. Use a positive value; zero outputs black."
//: }
uniform float base_color_refl;

//: param custom {
//:   "default": 0.0,
//:   "label": "Global Exposure (stops)",
//:   "min": -10.0,
//:   "max": 10.0,
//:   "step": 0.1,
//:   "group": "View Controls",
//:   "description": "Scene-linear exposure added to User1 material exposure and applied before the ACES output transform."
//: }
uniform float global_exposure_stops;

void shade(V2F inputs)
{
    // Color-managed sample: scene-linear ACEScg.
    vec3 base_color = textureSparse(
        basecolor_tex,
        inputs.sparse_coord
    ).rgb;

    // User0: target effective reflectance.
    float user0 = textureSparse(
        user0_tex,
        inputs.sparse_coord
    ).r;

    // User1: material exposure encoded over 0..1.
    float user1 = textureSparse(
        user1_tex,
        inputs.sparse_coord
    ).r;

    // R is a ratio, so it may exceed 1 even when User0 is within 0..1.
    // A zero reference is invalid; explicitly produce black instead.
    float R = 0.0;
    if (base_color_refl > 0.0)
    {
        R = user0 / base_color_refl;
    }

    float material_stops = user1 * 20.0 - 10.0;
    float total_stops = material_stops + global_exposure_stops;

    // Keep the scene-linear result unclamped before the output transform.
    vec3 scene_linear_acescg = base_color * R * exp2(total_stops);

    // Unlit output: no environment or BRDF contribution.
    albedoOutput(vec3(0.0));
    diffuseShadingOutput(vec3(0.0));
    specularShadingOutput(vec3(0.0));
    emissiveColorOutput(scene_linear_acescg);
    alphaOutput(1.0);
}
