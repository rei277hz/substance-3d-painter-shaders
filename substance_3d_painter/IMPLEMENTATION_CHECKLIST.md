# Implementation Checklist

## Before Editing

- [x] Confirm the active feature branch and clean tracked baseline.
- [x] Keep `substance_3d_painter/another-implementation/` read-only.
- [x] Keep this checklist and `FINAL_BEHAVIOR.md` in the maintained folder.

## Generator and Data

- [x] Add the bundled CIE 1931 2-degree observer CSV, metadata, and attribution.
- [x] Verify the published source checksum before spectral integration.
- [x] Generate the 257x257 RGB32F delta-UV LUT with B reserved as zero.
- [x] Confirm finite samples, positive reconstructed target XYZ, exact zero center,
      current R/G orientation, and strict fixed-row arc-length spacing.
- [x] Record generation metadata and checksums in a maintained manifest.

## Shader

- [x] Preserve User0/User1/User2/User3 order and missing-channel defaults.
- [x] Implement present-versus-missing User3.B validity behavior exactly.
- [x] Use CAT16 on the summed reflected and emitted contributions.
- [x] Use explicit level-0 bilinear `texelFetch` with endpoint clamping.
- [x] Reject missing or wrong-sized LUT resources with opaque black.
- [x] Preserve finite signed RGB and reject nonfinite inputs/results.
- [x] Keep the custom LUT parameter default name `whitepoint_cct_duv_lut`.

## Tests and Validation

- [x] Update Python tests for the spectral generator and delta-UV payload.
- [x] Add full OpenGL compile/link/render validation through a minimal Painter API
      adapter, clearly labeling it as non-Painter integration testing.
- [x] Test neutral identity, CAT16 reference agreement, HDR/signed colors,
      exposure independence, missing-channel defaults, and User3.B gating.
- [x] Test missing/wrong-sized LUTs, exact 0/1 coordinates, no opposite-edge
      wrapping, half-float precision, and representative gradient continuity.
- [x] Run Ruff, focused tests, full pytest, and `git diff --check`.

## Final Review and Git

- [x] Review docs against the shader and generator behavior.
- [x] Confirm no file under `another-implementation/` changed.
- [ ] Stage maintained files explicitly; never stage the reference directory.
- [ ] Verify the worktree, branch, signed commit, and `Signed-off-by` trailer.
