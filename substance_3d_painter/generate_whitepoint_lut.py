"""Generate the User3 temperature/tint white-point LUT for Painter.

The LUT stores Y-normalized XYZ in RGB.  User3.R is position along a
constant-Duv CIE 1960 uv curve, parameterized by arc length.  User3.G is a
linear signed Duv offset around the curve that passes through the AP1 white.
Keeping this work offline makes the Painter shader small and deterministic.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

T_MIN = 2000.0
T_MAX = 20000.0
DUV_HALF_RANGE = 0.02
ARC_SAMPLES = 32769

AP1_WHITE_XY = np.array([0.32168, 0.33767], dtype=np.float64)


def cct_uv(temperature: np.ndarray | float) -> np.ndarray:
    """Return the Hernandez-Andres Planckian-locus approximation in uv."""

    t = np.asarray(temperature, dtype=np.float64)
    t = np.clip(t, T_MIN, T_MAX)
    x_low = -0.2661239e9 / t**3 - 0.2343580e6 / t**2 + 0.8776956e3 / t + 0.179910
    x_high = -3.0258469e9 / t**3 + 2.1070379e6 / t**2 + 0.2226347e3 / t + 0.240390
    # The published piecewise approximation has a small numerical jump at
    # 4000 K. Blend over 3900..4100 K so arc-length resampling does not turn
    # that discontinuity into a visible step in a painted gradient.
    blend = np.clip((t - 3900.0) / 200.0, 0.0, 1.0)
    blend = blend * blend * (3.0 - 2.0 * blend)
    x = x_low * (1.0 - blend) + x_high * blend
    y_low = -0.9549476 * x**3 - 1.37418593 * x**2 + 2.09137015 * x - 0.16748867
    y_high = 3.0817580 * x**3 - 5.87338670 * x**2 + 3.75112997 * x - 0.37001483
    y_mid = y_low * (1.0 - blend) + y_high * blend
    y_cold = -1.1063814 * x**3 - 1.34811020 * x**2 + 2.18555832 * x - 0.20219683
    y = np.where(t <= 2222.0, y_cold, y_mid)
    denominator = -2.0 * x + 12.0 * y + 3.0
    return np.stack((4.0 * x / denominator, 6.0 * y / denominator), axis=-1)


def xy_to_uv(xy: np.ndarray) -> np.ndarray:
    x, y = xy
    denominator = -2.0 * x + 12.0 * y + 3.0
    return np.array([4.0 * x / denominator, 6.0 * y / denominator])


def uv_to_xyz(uv: np.ndarray) -> np.ndarray:
    """Convert CIE 1960 uv to XYZ with Y normalized to one."""

    u, v = uv
    denominator = 2.0 * u - 8.0 * v + 4.0
    x = 3.0 * u / denominator
    y = 2.0 * v / denominator
    return np.array([x / y, 1.0, (1.0 - x - y) / y])


def tangent_normal(temperature: float) -> tuple[np.ndarray, np.ndarray]:
    step = min(1.0, (T_MAX - T_MIN) / 2.0)
    lower = cct_uv(temperature - step)
    upper = cct_uv(temperature + step)
    tangent = upper - lower
    tangent /= np.linalg.norm(tangent)
    # This orientation points toward the usual magenta side of the locus.
    normal = np.array([-tangent[1], tangent[0]])
    return tangent, normal


def reference_coordinates() -> tuple[float, float]:
    """Return the closest-locus temperature and signed AP1 Duv offset."""

    ap1_uv = xy_to_uv(AP1_WHITE_XY)
    # The squared distance is smooth and unimodal over the supported CCT range.
    lower, upper = T_MIN, T_MAX
    golden = (np.sqrt(5.0) - 1.0) / 2.0
    first = upper - golden * (upper - lower)
    second = lower + golden * (upper - lower)
    for _ in range(96):
        first_distance = np.sum((cct_uv(first) - ap1_uv) ** 2)
        second_distance = np.sum((cct_uv(second) - ap1_uv) ** 2)
        if first_distance < second_distance:
            upper, second = second, first
            first = upper - golden * (upper - lower)
        else:
            lower, first = first, second
            second = lower + golden * (upper - lower)
    temperature = 0.5 * (lower + upper)
    _, normal = tangent_normal(temperature)
    offset = float(np.dot(ap1_uv - cct_uv(temperature), normal))
    return temperature, offset


def row_curve(temperature: np.ndarray, duv: float) -> tuple[np.ndarray, np.ndarray]:
    locus = cct_uv(temperature)
    # Use a fixed finite-difference interval. A derivative estimated from the
    # output LUT samples would depend on the requested LUT size and distort the
    # arc-length parameterization near the ends of a row.
    lower = cct_uv(np.asarray(temperature) - 0.5)
    upper = cct_uv(np.asarray(temperature) + 0.5)
    tangent = upper - lower
    lengths = np.linalg.norm(tangent, axis=-1, keepdims=True)
    normal = np.stack((-tangent[..., 1], tangent[..., 0]), axis=-1) / lengths
    return locus + duv * normal, locus


def build_lut(size: int) -> tuple[np.ndarray, dict[str, float]]:
    if size < 3 or size % 2 == 0:
        raise ValueError("LUT size must be an odd integer >= 3 so 0.5 is a texel center.")

    reference_temperature, reference_duv = reference_coordinates()
    reference_uv = xy_to_uv(AP1_WHITE_XY)

    temperatures = np.linspace(T_MIN, T_MAX, ARC_SAMPLES)
    rows: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
    half_arc = float("inf")
    for g in np.linspace(0.0, 1.0, size):
        duv = reference_duv + DUV_HALF_RANGE * (2.0 * g - 1.0)
        curve, _ = row_curve(temperatures, duv)
        distances = np.linalg.norm(np.diff(curve, axis=0), axis=1)
        cumulative = np.concatenate(([0.0], np.cumsum(distances)))
        reference_distance = float(np.interp(reference_temperature, temperatures, cumulative))
        half_arc = min(half_arc, reference_distance, float(cumulative[-1] - reference_distance))
        rows.append((curve, cumulative, np.array(reference_distance)))

    r_values = np.linspace(0.0, 1.0, size)
    g_values = np.linspace(0.0, 1.0, size)
    lut = np.empty((size, size, 3), dtype=np.float64)
    for row, (curve, cumulative, reference_distance) in enumerate(rows):
        target_distance = reference_distance + half_arc * (2.0 * r_values - 1.0)
        temperatures_at_r = np.interp(target_distance, cumulative, temperatures)
        duv = reference_duv + DUV_HALF_RANGE * (2.0 * g_values[row] - 1.0)
        curve_at_r, _ = row_curve(temperatures_at_r, duv)
        lut[row] = np.array([uv_to_xyz(uv) for uv in curve_at_r])

    # Make the identity exact at the central texel instead of depending on the
    # numerical nearest-locus solve and the finite LUT resolution.
    center = size // 2
    lut[center, center] = np.array(
        [
            AP1_WHITE_XY[0] / AP1_WHITE_XY[1],
            1.0,
            (1.0 - AP1_WHITE_XY[0] - AP1_WHITE_XY[1]) / AP1_WHITE_XY[1],
        ]
    )
    metadata = {
        "temperature_min": T_MIN,
        "temperature_max": T_MAX,
        "reference_temperature": reference_temperature,
        "reference_duv": reference_duv,
        "duv_half_range": DUV_HALF_RANGE,
        "symmetric_arc": half_arc,
        "reference_u": reference_uv[0],
        "reference_v": reference_uv[1],
    }
    return lut.astype(np.float32), metadata


def write_exr(path: Path, lut: np.ndarray, metadata: dict[str, float]) -> None:
    try:
        import OpenEXR
    except ImportError as exc:  # pragma: no cover - depends on optional runtime package
        raise RuntimeError("OpenEXR is required to write the LUT.") from exc

    header = {
        "compression": OpenEXR.ZIP_COMPRESSION,
        "type": OpenEXR.scanlineimage,
        "comments": (
            "User3 RG CIE 1960 uv arc-length LUT; RGB stores Y-normalized XYZ; "
            f"CCT={metadata['temperature_min']:g}..{metadata['temperature_max']:g} K; "
            f"Duv offset=+/-{metadata['duv_half_range']:g}; AP1 identity at (0.5,0.5)."
        ),
        "whitePoint": "ACES AP1 D60 xy=0.32168,0.33767",
        "lutTemperatureMin": float(metadata["temperature_min"]),
        "lutTemperatureMax": float(metadata["temperature_max"]),
        "lutReferenceTemperature": float(metadata["reference_temperature"]),
        "lutReferenceDuv": float(metadata["reference_duv"]),
        "lutDuvHalfRange": float(metadata["duv_half_range"]),
        "lutSymmetricArc": float(metadata["symmetric_arc"]),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with OpenEXR.File(header, {"RGB": np.ascontiguousarray(lut)}) as output:
        output.write(str(path))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).with_name("whitepoint_cct_duv_lut.exr"),
    )
    parser.add_argument("--size", type=int, default=257)
    args = parser.parse_args()
    lut, metadata = build_lut(args.size)
    write_exr(args.output, lut, metadata)
    center = lut[args.size // 2, args.size // 2]
    print(f"wrote {args.output} ({args.size}x{args.size}, RGB float32)")
    print(f"identity XYZ = {center[0]:.9f}, {center[1]:.9f}, {center[2]:.9f}")
    print(f"reference CCT = {metadata['reference_temperature']:.6f} K")
    print(f"reference Duv = {metadata['reference_duv']:.9f}")
    print(f"symmetric uv arc = {metadata['symmetric_arc']:.9f}")


if __name__ == "__main__":
    main()
