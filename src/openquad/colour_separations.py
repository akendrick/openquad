"""Colour separations: a colour photo split into negatives by colour, one per coat of a
coloured pigment (tricolour gum, cyanotype under gum, ...).

Each coat is described by the colour it prints at full strength on white paper. Coats stack
like filters: their optical densities add, so coats printed at strengths s_k (0 nothing to 1
full) give, in each of red, green and blue, the density sum_k s_k * D_k, where D_k is
-log10 of coat k's colour in linear light. For each colour of the photo the strengths are
the ones whose stack comes closest to it in density, each kept within 0-1 (a bounded least
squares, with a slight pull toward weaker coats so the split is unique when several coats
could make the same colour).

The saturation setting scales the photo's chroma (in OKLab) before the split. Above 1 the
coats separate more strongly, for processes (cyanotype, gum) whose prints come out duller
than the photo; 0 makes every coat print the photo's tones alone.

The split is worked out once on a grid of sRGB colours (33 x 33 x 33) and interpolated
trilinearly for every pixel; the photo's colour is read as sRGB. Each negative is made from
a greyscale "coat image" whose darkness is that coat's strength, put through that coat's
process curve like any photo (as for tonal separations).

Plain float64 arithmetic in a fixed order, so Swift (ColourSeparations.swift) matches.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from itertools import product

import numpy as np
from numpy.typing import NDArray

from openquad.colour import linear_to_srgb, srgb_to_linear
from openquad.quadfile import MAX_VALUE

MIN_COATS, MAX_COATS = 2, 4
MAX_SATURATION = 2.0
GRID = 33  # sRGB levels per channel the split is worked out at
DARKEST = 1e-3  # linear light: the deepest the photo is taken to go (density 3)
PALEST = 0.02  # the least density a coat needs in some channel to be printed at all
PULL = 0.01  # how strongly the split favours weaker coats
SLACK = 1e-9  # how far past 0-1 a solved strength may land and still be taken (then clipped)

# Pigments to start from: the colour each prints at full strength on white paper, sRGB.
PIGMENTS: dict[str, tuple[int, int, int]] = {
    "Cyanotype blue": (34, 74, 140),
    "Hansa yellow": (242, 194, 48),
    "Quinacridone magenta": (176, 48, 106),
    "Phthalo blue": (31, 95, 168),
    "Phthalo green": (29, 107, 87),
    "Burnt sienna": (154, 74, 38),
    "Van Dyke brown": (90, 58, 34),
    "Lamp black": (42, 42, 42),
}
DEFAULT_COATS = ("Cyanotype blue", "Quinacridone magenta", "Hansa yellow")

Colour = tuple[int, int, int]


@dataclass(frozen=True)
class ColourSeparation:
    """The coats, in the order they are printed, each the colour it prints at full strength
    (sRGB 0-255), and how much the photo's chroma is scaled before the split."""

    coats: tuple[Colour, ...]
    saturation: float = 1.0

    def __post_init__(self) -> None:
        if not MIN_COATS <= len(self.coats) <= MAX_COATS:
            raise ValueError(f"{MIN_COATS}-{MAX_COATS} coats, got {len(self.coats)}")
        for k, coat in enumerate(self.coats):
            if len(coat) != 3 or any(not 0 <= c <= 255 for c in coat):
                raise ValueError(f"coat {k + 1}'s colour must be three values 0-255, got {coat}")
            if max(coat_density(coat)) < PALEST:
                raise ValueError(f"coat {k + 1} is too pale to print: pick a stronger colour")
        if not 0.0 <= self.saturation <= MAX_SATURATION:
            raise ValueError(f"saturation must be 0-{MAX_SATURATION:g}, got {self.saturation:g}")

    @property
    def count(self) -> int:
        return len(self.coats)

    @classmethod
    def default(cls) -> ColourSeparation:
        return cls(tuple(PIGMENTS[name] for name in DEFAULT_COATS))

    def describe(self) -> str:
        """e.g. "3 coats (#224A8C, #B0306A, #F2C230), saturation 1.5"."""
        colours = ", ".join(hex_colour(c) for c in self.coats)
        return f"{self.count} coats ({colours}), saturation {self.saturation:g}"


def hex_colour(colour: Colour) -> str:
    return "#" + "".join(f"{c:02X}" for c in colour)


def parse_hex(text: str) -> Colour:
    """A colour written "#B0306A" (or without the #) -> (176, 48, 106)."""
    digits = text.strip().removeprefix("#")
    if len(digits) != 6 or any(c not in "0123456789abcdefABCDEF" for c in digits):
        raise ValueError(f"not a colour like #B0306A: {text!r}")
    return (int(digits[0:2], 16), int(digits[2:4], 16), int(digits[4:6], 16))


def coat_density(colour: Colour) -> list[float]:
    """A coat's density in red, green and blue at full strength."""
    linear = srgb_to_linear(np.array(colour, dtype=np.float64) / 255.0)
    return [float(-np.log10(max(v, DARKEST))) for v in linear]


# --- OKLab, for the saturation ---------------------------------------------------------


def _saturate(r: NDArray[np.float64], g: NDArray[np.float64], b: NDArray[np.float64],
              saturation: float) -> tuple[NDArray[np.float64], ...]:  # fmt: skip
    """Linear sRGB with its OKLab chroma scaled by `saturation`."""
    lc = np.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    mc = np.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    sc = np.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    lightness = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
    a = (1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc) * saturation
    bb = (0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc) * saturation
    lc = lightness + 0.3963377774 * a + 0.2158037573 * bb
    mc = lightness - 0.1055613458 * a - 0.0638541728 * bb
    sc = lightness - 0.0894841775 * a - 1.2914855480 * bb
    lc, mc, sc = lc * lc * lc, mc * mc * mc, sc * sc * sc
    return (
        4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
        -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
        -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
    )


# --- the split ----------------------------------------------------------------------------


def _inverse(m: list[list[float]]) -> list[list[float]]:
    """Gauss-Jordan inverse of a small symmetric positive definite matrix (no pivoting)."""
    n = len(m)
    a = [row[:] + [1.0 if i == j else 0.0 for j in range(n)] for i, row in enumerate(m)]
    for i in range(n):
        pivot = a[i][i]
        a[i] = [v / pivot for v in a[i]]
        for r in range(n):
            if r != i:
                factor = a[r][i]
                a[r] = [v - factor * w for v, w in zip(a[r], a[i], strict=True)]
    return [row[n:] for row in a]


Pattern = tuple[list[float], list[int], list[list[float]], list[float]]


def _patterns(density: list[list[float]]) -> list[Pattern]:
    """For each way the coats can sit (each free, at 0 or at full strength; the last coat
    changing fastest): the strengths, the free coats, and the free coats' strengths as
    P @ d + q for a target density d. Free strengths minimise |sum s_k D_k - d|^2 +
    PULL * |s|^2 with the rest held where they are."""
    n = len(density)
    gram = [[sum(density[j][c] * density[k][c] for c in range(3)) + (PULL if j == k else 0.0)
             for k in range(n)] for j in range(n)]  # fmt: skip
    patterns = []
    for states in product(range(3), repeat=n):  # 0 free, 1 at zero, 2 at full strength
        free = [k for k in range(n) if states[k] == 0]
        fixed = [1.0 if states[k] == 2 else 0.0 for k in range(n)]
        p: list[list[float]] = []
        q: list[float] = []
        if free:
            inverse = _inverse([[gram[j][k] for k in free] for j in free])
            full = [k for k in range(n) if states[k] == 2]
            pushed = [sum(gram[j][k] for k in full) for j in free]  # what the full coats give
            for row in inverse:
                p.append([sum(row[i] * density[free[i]][c] for i in range(len(free)))
                          for c in range(3)])  # fmt: skip
                q.append(-sum(row[i] * pushed[i] for i in range(len(free))))
        patterns.append((fixed, free, p, q))
    return patterns


def solve(separation: ColourSeparation, rgb: NDArray[np.float64]) -> NDArray[np.float64]:
    """Each coat's strength (..., count), 0-1, for sRGB-encoded colours (..., 3), 0-1."""
    density = [coat_density(c) for c in separation.coats]
    n = separation.count
    flat = np.asarray(rgb, dtype=np.float64).reshape(-1, 3)
    size = flat.shape[0]
    r, g, b = (srgb_to_linear(flat[:, c]) for c in range(3))
    if separation.saturation != 1.0:
        r, g, b = _saturate(r, g, b, separation.saturation)
    d = [-np.log10(np.clip(v, DARKEST, 1.0)) for v in (r, g, b)]
    best = np.full(size, np.inf)
    strengths = np.zeros((size, n))
    for fixed, free, p, q in _patterns(density):
        s = [np.full(size, fixed[k]) for k in range(n)]
        feasible = np.ones(size, dtype=bool)
        for i, k in enumerate(free):
            value = p[i][0] * d[0] + p[i][1] * d[1] + p[i][2] * d[2] + q[i]
            feasible &= (value >= -SLACK) & (value <= 1.0 + SLACK)
            s[k] = np.clip(value, 0.0, 1.0)
        cost = np.zeros(size)
        for c in range(3):
            residual = s[0] * density[0][c]
            for k in range(1, n):
                residual = residual + s[k] * density[k][c]
            residual = residual - d[c]
            cost = cost + residual * residual
        for k in range(n):
            cost = cost + PULL * (s[k] * s[k])
        better = feasible & (cost < best)
        best = np.where(better, cost, best)
        strengths = np.where(better[:, np.newaxis], np.stack(s, axis=-1), strengths)
    result: NDArray[np.float64] = strengths.reshape(*np.shape(rgb)[:-1], n)
    return result


@lru_cache(maxsize=4)
def strength_lut(separation: ColourSeparation, grid: int = GRID) -> NDArray[np.float64]:
    """Each coat's strength at every colour of a grid x grid x grid sRGB lattice
    (red slowest, blue fastest): shape (grid, grid, grid, count)."""
    if grid < 2:
        raise ValueError(f"the grid needs at least 2 levels, got {grid}")
    levels = np.arange(grid, dtype=np.float64) / (grid - 1)
    lattice = np.stack(np.meshgrid(levels, levels, levels, indexing="ij"), axis=-1)
    return solve(separation, lattice)


def _interpolate(lut: NDArray[np.float64], rgb: NDArray[np.uint16]) -> NDArray[np.float64]:
    """Trilinear lookup of `lut` (grid, grid, grid, ...) at 16-bit colours (..., 3)."""
    grid = lut.shape[0]
    x = rgb.astype(np.float64) / MAX_VALUE * (grid - 1)
    low = np.minimum(np.floor(x).astype(np.intp), grid - 2)
    t = x - low
    i, j, k = low[..., 0], low[..., 1], low[..., 2]
    tr, tg, tb = (t[..., c][..., np.newaxis] for c in range(3))
    if lut.ndim == 3:
        tr, tg, tb = tr[..., 0], tg[..., 0], tb[..., 0]

    def edge(a: NDArray[np.intp], b: NDArray[np.intp]) -> NDArray[np.float64]:
        result: NDArray[np.float64] = lut[a, b, k] * (1.0 - tb) + lut[a, b, k + 1] * tb
        return result

    near = edge(i, j) * (1.0 - tg) + edge(i, j + 1) * tg
    far = edge(i + 1, j) * (1.0 - tg) + edge(i + 1, j + 1) * tg
    result: NDArray[np.float64] = near * (1.0 - tr) + far * tr
    return result


def coat_image(
    rgb: NDArray[np.uint16], separation: ColourSeparation, coat: int, chunk_rows: int = 256
) -> NDArray[np.uint16]:
    """The greyscale image coat `coat`'s negative is made from (its strength as darkness),
    from a 16-bit colour photo (height, width, 3) or a greyscale one (read as neutral)."""
    if rgb.dtype != np.uint16:
        raise TypeError(f"photo must be uint16, got {rgb.dtype}")
    if not 0 <= coat < separation.count:
        raise ValueError(f"coat {coat + 1} of {separation.count} doesn't exist")
    if rgb.ndim == 2:
        rgb = np.repeat(rgb[..., np.newaxis], 3, axis=-1)
    lut = np.ascontiguousarray(strength_lut(separation)[..., coat])
    out = np.empty(rgb.shape[:2], dtype=np.uint16)
    for top in range(0, rgb.shape[0], chunk_rows):
        strength = _interpolate(lut, rgb[top : top + chunk_rows])
        out[top : top + chunk_rows] = np.rint((1.0 - strength) * MAX_VALUE).astype(np.uint16)
    return out


def proof(rgb: NDArray[np.uint16], separation: ColourSeparation) -> NDArray[np.uint16]:
    """What the stacked coats print, as 16-bit sRGB: each pixel's coat strengths with their
    densities added up. Before any process curve (which is there to make the coat print the
    strength it is given)."""
    if rgb.ndim == 2:
        rgb = np.repeat(rgb[..., np.newaxis], 3, axis=-1)
    strengths = _interpolate(strength_lut(separation), rgb)
    density = [coat_density(c) for c in separation.coats]
    out = np.empty(rgb.shape, dtype=np.uint16)
    for c in range(3):
        total = strengths[..., 0] * density[0][c]
        for k in range(1, separation.count):
            total = total + strengths[..., k] * density[k][c]
        out[..., c] = np.rint(linear_to_srgb(np.power(10.0, -total)) * MAX_VALUE).astype(np.uint16)
    return out
