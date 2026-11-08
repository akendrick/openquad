"""Tonal separations: one photo split into several negatives, each printing a band of tones.

Some processes (gum bichromate, multi-coat cyanotype, gum over platinum) can't reach a full
tonal range in one coat. The print is built up from several coats, each exposed under its own
negative. A separation divides the photo's tones into bands at chosen split points, from the
lightest band to the darkest:

- negative k prints nothing in tones lighter than its band, ramps up across the band, and
  prints at its coat's full strength in every darker tone. So the coats add up: the deepest
  shadows get every coat, the highlights only the first.
- with an overlap, each band's corners are softened over that width of tone (its ramp averaged
  over a window that wide), so the seam between two bands doesn't show as a line. The coats
  still add up to the photo exactly, and paper white and full black are untouched.

Tone positions run 0 (paper white) to 1 (full black): position = 1 - pixel / 65535. Each
negative is made from a greyscale "coat image" whose darkness is that coat's strength, put
through that coat's process curve like any photo.

Everything is plain float64 arithmetic in a fixed order, so Swift (Separations.swift) matches
bit for bit.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import pairwise

import numpy as np
from numpy.typing import NDArray

from openquad.quadfile import MAX_VALUE

MAX_SEPARATIONS = 6
# The step scale split points are shown on (a 30-step scale: splits at 10 and 20 for three).
DEFAULT_STEPS = 30
# The step test: inches across its steps, its black frame, and the heights of the steps and
# the gradient under them.
TEST_WIDTH = 7.0
TEST_FRAME, TEST_STEPS, TEST_GRADIENT = 0.15, 1.0, 0.5


@dataclass(frozen=True)
class SeparationPlan:
    """Where the bands meet (tone positions, ascending, within 0-1) and how much they blend.

    `steps` is only how the plan is shown: the scale its split points are counted on.
    """

    splits: tuple[float, ...]
    overlap: float = 0.0  # width of tone over which neighbouring bands blend
    steps: int = DEFAULT_STEPS

    def __post_init__(self) -> None:
        if len(self.splits) + 1 > MAX_SEPARATIONS:
            raise ValueError(f"at most {MAX_SEPARATIONS} negatives, got {len(self.splits) + 1}")
        if any(not 0.0 < s < 1.0 for s in self.splits):
            raise ValueError("split points must lie between paper white and full black")
        if any(b <= a for a, b in pairwise(self.splits)):
            raise ValueError("split points must be in order, lightest first, none the same")
        if self.steps < 2:
            raise ValueError(f"the step scale needs at least 2 steps, got {self.steps}")
        narrowest = min(upper - lower for lower, upper in self.bands)
        if not 0.0 <= self.overlap <= narrowest + 1e-9:  # allow for rounding in s / steps
            raise ValueError(
                f"the overlap can be up to the narrowest band ({narrowest * self.steps:g} steps), "
                f"got {self.overlap * self.steps:g}"
            )

    @property
    def count(self) -> int:
        return len(self.splits) + 1

    @property
    def bands(self) -> list[tuple[float, float]]:
        """Each negative's band of tone, (lighter edge, darker edge), lightest first."""
        edges = (0.0, *self.splits, 1.0)
        return list(pairwise(edges))

    @classmethod
    def even(cls, count: int, overlap: float = 0.0, steps: int = DEFAULT_STEPS) -> SeparationPlan:
        """`count` bands of equal width."""
        if not 1 <= count <= MAX_SEPARATIONS:
            raise ValueError(f"1-{MAX_SEPARATIONS} negatives, got {count}")
        return cls(tuple(k / count for k in range(1, count)), overlap, steps)

    @classmethod
    def from_steps(
        cls, splits: list[int] | tuple[int, ...], steps: int, overlap: float = 0.0
    ) -> SeparationPlan:
        """Split points and overlap counted in steps of a `steps`-step scale."""
        if steps < 2:
            raise ValueError(f"the step scale needs at least 2 steps, got {steps}")
        return cls(tuple(s / steps for s in splits), overlap / steps, steps)

    def describe(self) -> str:
        """e.g. "3 negatives, split at steps 10 and 20 of 30, overlap 1 step"."""
        if self.count == 1:
            return "1 negative (no separation)"
        points = [f"{s * self.steps:g}" for s in self.splits]
        joined = points[0] if len(points) == 1 else ", ".join(points[:-1]) + " and " + points[-1]
        word = "step" if len(points) == 1 else "steps"
        overlap = f"{self.overlap * self.steps:g}"
        blend = f", overlap {overlap} step{'' if overlap == '1' else 's'}" if self.overlap else ""
        return f"{self.count} negatives, split at {word} {joined} of {self.steps}{blend}"


def _antiderivative(v: NDArray[np.float64], first: bool, last: bool) -> NDArray[np.float64]:
    """The integral of a band's ramp (in band units): 0 below the band, rising to 1 across
    it, 1 beyond. The lightest band keeps rising below its start (never reached: paper white
    is its start) and the darkest keeps rising past its end, so softening never moves paper
    white or full black."""
    result = v * v / 2.0
    if not last:
        result = np.where(v > 1.0, v - 0.5, result)
    if not first:
        result = np.where(v < 0.0, 0.0, result)
    return result


def strength(
    plan: SeparationPlan, layer: int, positions: NDArray[np.float64]
) -> NDArray[np.float64]:
    """How strongly negative `layer` (0 = the lightest band) prints at each tone position,
    0 (nothing) to 1 (its coat's full strength)."""
    if not 0 <= layer < plan.count:
        raise ValueError(f"negative {layer + 1} of {plan.count} doesn't exist")
    lower, upper = plan.bands[layer]
    width = upper - lower
    first, last = layer == 0, layer == plan.count - 1
    u = (positions - lower) / width
    if plan.overlap == 0.0:
        ramp = u if last else np.minimum(u, 1.0)
        ramp = ramp if first else np.maximum(ramp, 0.0)
    else:
        h = plan.overlap / (2.0 * width)
        ramp = (_antiderivative(u + h, first, last) - _antiderivative(u - h, first, last)) / (
            2.0 * h
        )
    result: NDArray[np.float64] = np.clip(ramp, 0.0, 1.0)
    return result


def coat_lut(plan: SeparationPlan, layer: int) -> NDArray[np.uint16]:
    """Photo pixel (0 black .. 65535 white) -> that coat's image pixel."""
    positions = 1.0 - np.arange(MAX_VALUE + 1, dtype=np.float64) / MAX_VALUE
    coat = 1.0 - strength(plan, layer, positions)
    result: NDArray[np.uint16] = np.rint(coat * MAX_VALUE).astype(np.uint16)
    return result


def coat_image(photo: NDArray[np.uint16], plan: SeparationPlan, layer: int) -> NDArray[np.uint16]:
    """The greyscale image negative `layer` is made from: its coat's strength as darkness."""
    if photo.dtype != np.uint16:
        raise TypeError(f"photo must be uint16, got {photo.dtype}")
    result: NDArray[np.uint16] = coat_lut(plan, layer)[photo]
    return result


def step_test(steps: int = DEFAULT_STEPS, dpi: float = 300.0) -> NDArray[np.uint16]:
    """A greyscale test to print through a separation, laid out like a contact-printed step
    tablet: the step scale's steps 0 (paper white) to `steps` (full black) as tall patches,
    each numbered sideways inside it (black on light steps, white on dark), and under them a
    continuous gradient lined up with them (each patch's tone under its centre), all in a
    black frame. The coats' bands, their seams and any banding between steps all show."""
    if not 2 <= steps <= 101:
        raise ValueError(f"the step scale needs 2-101 steps, got {steps}")
    if dpi <= 0:
        raise ValueError(f"dpi must be positive, got {dpi}")
    from openquad.negative import DIGIT_GLYPHS

    count = steps + 1
    patch = max(1, round(TEST_WIDTH * dpi / count))
    frame, tall, low = (max(1, round(h * dpi)) for h in (TEST_FRAME, TEST_STEPS, TEST_GRADIENT))
    width = patch * count
    image = np.zeros((3 * frame + tall + low, width + 2 * frame), dtype=np.uint16)  # black
    levels = np.rint((1.0 - np.arange(count) / steps) * MAX_VALUE).astype(np.uint16)
    image[frame : frame + tall, frame : frame + width] = np.repeat(levels, patch)[np.newaxis, :]
    x = np.arange(width, dtype=np.float64)
    tone = np.clip((x + 0.5 - patch / 2.0) / (patch * steps), 0.0, 1.0)
    gradient = np.rint((1.0 - tone) * MAX_VALUE).astype(np.uint16)
    image[2 * frame + tall : 2 * frame + tall + low, frame : frame + width] = gradient
    digits = len(str(steps))
    cell = min(patch * 6 // 10 // 7, tall // 2 // (6 * digits))
    if cell >= 1:
        top = frame + 2 * cell
        for k in range(count):
            ink = 0 if levels[k] >= MAX_VALUE // 2 else MAX_VALUE  # contrasting with the step
            left = frame + k * patch + (patch - 7 * cell) // 2
            for d, char in enumerate(str(k)):  # read top to bottom, turned a quarter right
                turned = np.rot90(DIGIT_GLYPHS[int(char)], -1)
                glyph = np.kron(turned, np.ones((cell, cell), dtype=bool))
                y = top + d * 6 * cell
                image[y : y + 5 * cell, left : left + 7 * cell][glyph] = ink
    return image
