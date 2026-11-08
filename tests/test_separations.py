"""Tonal separations: bands, overlap, coat images, numbered negatives and clear targets."""

from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.chart import (
    ProcessCurve,
    build_process_curve,
    chart_photo,
    read_chart,
    tone_errors,
)
from openquad.cli import main
from openquad.marks import target_mask
from openquad.negative import DIGIT_GLYPHS, NegativeSettings, label_left, make_negative
from openquad.quadfile import MAX_VALUE
from openquad.separations import (
    MAX_SEPARATIONS,
    SeparationPlan,
    coat_image,
    coat_lut,
    step_test,
    strength,
)
from openquad.session import PrintSession, SessionError
from tests.simulation import gum_print
from tests.test_blocking import scanned

TONES = np.linspace(0.0, 1.0, 3001)
PLANS = [
    SeparationPlan.from_steps([10, 20], 30),
    SeparationPlan.from_steps([10, 20], 30, overlap=2),
    SeparationPlan.from_steps([5, 12, 25], 30, overlap=5),
    SeparationPlan.even(2, overlap=0.5),
    SeparationPlan.even(6, overlap=0.1),
]


@pytest.mark.parametrize("plan", PLANS, ids=lambda p: p.describe())
def test_coats_add_up_to_the_photo(plan: SeparationPlan) -> None:
    total = sum(
        (upper - lower) * strength(plan, k, TONES) for k, (lower, upper) in enumerate(plan.bands)
    )
    assert np.max(np.abs(total - TONES)) < 1e-12


@pytest.mark.parametrize("plan", PLANS, ids=lambda p: p.describe())
def test_paper_white_and_full_black_are_untouched(plan: SeparationPlan) -> None:
    for k in range(plan.count):
        lut = coat_lut(plan, k)
        assert lut[MAX_VALUE] == MAX_VALUE  # paper white: no coat prints
        assert lut[0] == 0  # full black: every coat at full strength
        assert np.all(np.diff(lut.astype(int)) >= 0)  # never reversing


def test_hard_bands_without_overlap() -> None:
    plan = SeparationPlan.from_steps([10, 20], 30)
    at = np.array([0.0, 1 / 6, 1 / 3, 0.5, 2 / 3, 5 / 6, 1.0])
    assert strength(plan, 0, at) == pytest.approx([0, 0.5, 1, 1, 1, 1, 1])
    assert strength(plan, 1, at) == pytest.approx([0, 0, 0, 0.5, 1, 1, 1])
    assert strength(plan, 2, at) == pytest.approx([0, 0, 0, 0, 0, 0.5, 1])


def test_overlap_softens_only_the_seams() -> None:
    hard = SeparationPlan.from_steps([10, 20], 30)
    soft = SeparationPlan.from_steps([10, 20], 30, overlap=2)
    far = np.array([0.05, 0.5, 0.95])  # well inside each band
    for k in range(3):
        assert strength(soft, k, far) == pytest.approx(strength(hard, k, far))
    seam = np.array([1 / 3])
    assert 0 < strength(soft, 1, seam)[0] < 0.1  # the next coat starts before the seam
    assert 0.9 < strength(soft, 0, seam)[0] < 1  # and this one eases into full strength


def test_single_band_is_the_photo() -> None:
    plan = SeparationPlan.even(1)
    assert plan.count == 1 and plan.describe() == "1 negative (no separation)"
    assert np.array_equal(coat_lut(plan, 0), np.arange(MAX_VALUE + 1, dtype=np.uint16))


def test_describe() -> None:
    assert SeparationPlan.from_steps([10, 20], 30, 1).describe() == (
        "3 negatives, split at steps 10 and 20 of 30, overlap 1 step"
    )
    assert SeparationPlan.from_steps([5, 12, 25], 30, 3).describe() == (
        "4 negatives, split at steps 5, 12 and 25 of 30, overlap 3 steps"
    )
    assert SeparationPlan.from_steps([7], 21).describe() == "2 negatives, split at step 7 of 21"


@pytest.mark.parametrize(
    ("make", "message"),
    [
        (lambda: SeparationPlan((0.2, 0.2)), "in order"),
        (lambda: SeparationPlan((0.5, 0.3)), "in order"),
        (lambda: SeparationPlan((0.0,)), "between paper white"),
        (lambda: SeparationPlan((1.0,)), "between paper white"),
        (lambda: SeparationPlan((0.1, 0.2, 0.3, 0.4, 0.5, 0.6)), "at most 6"),
        (lambda: SeparationPlan((0.5,), steps=1), "at least 2 steps"),
        (lambda: SeparationPlan.from_steps([10], 1), "at least 2 steps"),
        (lambda: SeparationPlan.from_steps([10, 20], 30, overlap=11), "narrowest band"),
        (lambda: SeparationPlan((0.5,), overlap=-0.1), "narrowest band"),
        (lambda: SeparationPlan.even(0), "1-6"),
        (lambda: SeparationPlan.even(MAX_SEPARATIONS + 1), "1-6"),
        (lambda: strength(SeparationPlan.even(2), 2, TONES), "negative 3 of 2"),
    ],
)
def test_bad_plans(make: object, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        make()  # type: ignore[operator]


def test_coat_image_needs_16_bits() -> None:
    with pytest.raises(TypeError):
        coat_image(np.zeros((2, 2), np.uint8), SeparationPlan.even(2), 0)


# --- numbered negatives and clear targets ----------------------------------------------

RAMP = np.tile(np.linspace(0, 65535, 300).astype(np.uint16), (120, 1))


def test_numbers_are_cut_clear_one_place_apart() -> None:
    lefts = [label_left(1200, 100, 8, n) for n in range(1, 7)]
    assert lefts == [108, 164, 220, 276, 332, 388]
    assert label_left(600, 100, 8, 6) == 108  # no room further right: back to the first place
    assert label_left(260, 100, 8, 1) is None  # no room at all
    plain = make_negative(RAMP, NegativeSettings(colour="orange", safe_edge=0.5), 200)
    numbered = make_negative(RAMP, NegativeSettings(colour="orange", safe_edge=0.5, label=2), 200)
    changed = np.argwhere(np.any(plain != numbered, axis=2))
    cell = 100 * 6 // 10 // 7
    glyph = np.kron(DIGIT_GLYPHS[2], np.ones((cell, cell), dtype=bool))
    assert len(changed) == glyph.sum()
    assert np.all(numbered[changed[:, 0], changed[:, 1]] == MAX_VALUE)  # clear film
    assert changed[:, 1].min() >= label_left(500, 100, cell, 2)  # type: ignore[operator]


def test_clear_targets_need_registration_marks() -> None:
    settings = NegativeSettings(colour="green", safe_edge=0.5, registration=True)
    black = make_negative(RAMP, settings, 200)
    clear = make_negative(RAMP, replace(settings, clear_targets=True), 200)
    targets = target_mask(500, 320, 100, 200)
    assert np.all(black[targets] == 0)
    assert np.all(clear[targets] == MAX_VALUE)
    assert np.array_equal(black[~targets], clear[~targets])
    unmarked = NegativeSettings(colour="green", safe_edge=0.5, clear_targets=True)
    assert np.array_equal(
        make_negative(RAMP, unmarked, 200),
        make_negative(RAMP, NegativeSettings(colour="green", safe_edge=0.5), 200),
    )


def test_bad_label() -> None:
    with pytest.raises(ValueError, match="1-6"):
        NegativeSettings(label=7)


def test_target_mask_without_room() -> None:
    assert not target_mask(20, 20, 1, 300).any()


# --- the print session ---------------------------------------------------------------


def process_file(tmp_path: Path, name: str, colour: str, gamma: float) -> Path:
    levels = np.rint(np.linspace(0, 65535, 257)).astype(np.uint16)
    curve = np.rint(65535 * (levels / 65535.0) ** gamma).astype(np.uint16)
    path = tmp_path / name
    path.write_text(ProcessCurve(levels, curve, colour=colour).to_json())
    return path


def session(tmp_path: Path) -> PrintSession:
    path = tmp_path / "ramp.tif"
    tifffile.imwrite(path, RAMP, resolution=(100, 100), resolutionunit="INCH")
    s = PrintSession()
    s.open(path)
    s.set_mode("negative")
    s.fit, s.ppi, s.registration = False, 100.0, True
    return s


def test_session_renders_each_negative(tmp_path: Path) -> None:
    s = session(tmp_path)
    s.set_process(process_file(tmp_path, "shared.oqproc", "orange", 0.8))
    whole = s.render(s._photo().pixels)
    s.set_separation(SeparationPlan.from_steps([10, 20], 30, 1))
    s.set_layer_process(2, process_file(tmp_path, "deep.oqproc", "green", 1.2))
    renders = [s.render_layer(s._photo().pixels, k) for k in range(3)]
    assert all(r.shape == whole.shape for r in renders)  # every negative in register
    assert s._negative_settings(0).colour == "orange"
    assert s._negative_settings(2).colour == "green"
    s.set_layer(1)
    assert np.array_equal(s.render(s._photo().pixels), renders[1])
    lines = s.summary()
    assert "Separation: 3 negatives, split at steps 10 and 20 of 30, overlap 1 step" in lines
    assert "This negative: 2 of 3 (steps 10-20, then full strength)" in lines
    assert "Process curve: shared.oqproc" in lines
    s.set_layer(2)
    assert "Process curve: deep.oqproc" in s.summary() and "Colour: green" in s.summary()
    s.printer = "Canon"
    assert s.print_job(tmp_path / "x.tif").title == "OpenQuad: ramp.tif (negative 3 of 3)"
    s.set_layer_process(2, None)
    assert s.layer_process(2) is s.process


def test_session_writes_every_negative(tmp_path: Path) -> None:
    s = session(tmp_path)
    with pytest.raises(SessionError, match="separation"):
        s.write_separations(tmp_path)
    s.set_separation(SeparationPlan.even(3))
    paths = s.write_separations(tmp_path)
    assert [p.name for p in paths] == ["ramp-1of3.tif", "ramp-2of3.tif", "ramp-3of3.tif"]
    assert len({tifffile.imread(p).tobytes() for p in paths}) == 3


def test_session_fewer_negatives_drops_what_no_longer_exists(tmp_path: Path) -> None:
    s = session(tmp_path)
    s.set_separation(SeparationPlan.even(4))
    s.set_layer(3)
    s.set_layer_process(3, process_file(tmp_path, "c.oqproc", "green", 1.0))
    s.set_separation(SeparationPlan.even(2))
    assert s.layer == 1 and s.layer_processes == {} and s.layer_process_paths == {}
    s.set_separation(None)
    assert s.separation is None and s.layer == 0
    with pytest.raises(SessionError, match="no negative 2 of 1"):
        s.set_layer(1)
    with pytest.raises(SessionError, match="no negative 2 of 1"):
        s.set_layer_process(1, None)
    s.set_separation(SeparationPlan.even(1))  # one band is no separation
    assert s.separation is None


# --- the command line ----------------------------------------------------------------


def test_negative_command_separations(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    photo = tmp_path / "p.tif"
    tifffile.imwrite(photo, RAMP, resolution=(100, 100), resolutionunit="INCH")
    deep = process_file(tmp_path, "deep.oqproc", "green", 1.2)
    out = tmp_path / "neg.tif"
    argv = ["negative", str(photo), "-o", str(out), "--registration", "--splits", "10,20",
            "--overlap", "1", "--layer-process", f"3={deep}"]  # fmt: skip
    assert main(argv) == 0
    text = capsys.readouterr().out
    assert "3 negatives, split at steps 10 and 20 of 30, overlap 1 step" in text
    assert "(steps 20-30, green," in text
    assert [tifffile.imread(tmp_path / f"neg-{k}of3.tif").shape for k in (1, 2, 3)] == [
        (170, 350, 3)
    ] * 3
    assert main(["negative", str(photo), "-o", str(out), "--separations", "2"]) == 0
    assert (tmp_path / "neg-2of2.tif").exists()


@pytest.mark.parametrize(
    ("extra", "message"),
    [
        (["--splits", "10", "--separations", "3"], "make 2 negatives, not 3"),
        (["--layer-process", "1=x.oqproc"], "need --separations"),
        (["--coats-curve", "x.oqproc"], "need --separations"),
        (["--separations", "2", "--layer-process", "3=x.oqproc"], "K 1-2"),
        (["--splits", "ten"], "expected steps"),
    ],
)
def test_negative_command_separation_errors(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], extra: list[str], message: str
) -> None:
    photo = tmp_path / "p.tif"
    tifffile.imwrite(photo, RAMP)
    try:
        code = main(["negative", str(photo), "-o", str(tmp_path / "n.tif"), *extra])
    except SystemExit as stop:  # argparse rejects bad values itself
        code = int(stop.code or 0)
    assert code != 0
    assert message in capsys.readouterr().err


# --- the step test -------------------------------------------------------------------


def test_step_test_is_a_numbered_tablet_over_a_matching_gradient() -> None:
    test = step_test(30, 300.0)
    patch, frame, tall, low = round(7.0 * 300 / 31), 45, 300, 150
    assert test.shape == (3 * frame + tall + low, patch * 31 + 2 * frame)
    assert (test[:frame] == 0).all() and (test[:, :frame] == 0).all()  # the black frame
    assert (test[frame + tall : 2 * frame + tall] == 0).all()  # and between the scales
    steps = test[frame + tall - 5, frame + patch // 2 :: patch][:31]  # below the numbers
    assert steps.tolist() == np.rint((1 - np.arange(31) / 30) * MAX_VALUE).astype(int).tolist()
    gradient = test[2 * frame + tall + low // 2, frame : frame + patch * 31]
    centres = gradient[patch // 2 :: patch].astype(int)
    assert np.all(np.abs(centres - steps.astype(int)) <= MAX_VALUE // (patch * 30) + 1)
    assert gradient[0] == MAX_VALUE and gradient[-1] == 0
    assert np.all(np.diff(gradient.astype(int)) <= 0)
    for k in (0, 10, 29):  # numbered inside each step, contrasting with it
        column = test[frame : frame + tall, frame + k * patch : frame + (k + 1) * patch]
        ink = 0 if steps[k] >= MAX_VALUE // 2 else MAX_VALUE
        assert (column == ink).sum() > 0 and set(np.unique(column).tolist()) == {int(steps[k]), ink}


def test_step_test_without_room_for_numbers_and_bad_sizes() -> None:
    small = step_test(101, 20.0)
    frame = round(0.15 * 20)
    tablet = small[frame : frame + 20, frame:-frame]
    assert len(np.unique(tablet[:, 0])) == 1  # too small to number: plain steps
    with pytest.raises(ValueError, match="2-101"):
        step_test(1)
    with pytest.raises(ValueError, match="dpi"):
        step_test(30, 0)


def test_target_command_steps(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = tmp_path / "steps.tif"
    assert main(["target", "--kind", "steps", "--steps", "21", "--dpi", "100", "-o", str(out)]) == 0
    assert tifffile.imread(out).shape == (195, 22 * 32 + 30)
    assert "steps 0-21" in capsys.readouterr().out


# --- calibrating the coats together ------------------------------------------------------


def test_coats_curve_shapes_the_photo_before_it_is_split(tmp_path: Path) -> None:
    s = session(tmp_path)
    s.set_separation(SeparationPlan.from_steps([10, 20], 30, 1))
    plain = [s.render_layer(s._photo().pixels, k) for k in range(3)]
    coats = process_file(tmp_path, "coats.oqproc", "green", 1.3)
    s.set_coats_curve(coats)
    assert "Coats curve: coats.oqproc" in s.summary()
    curved = ProcessCurve.from_json(coats.read_text()).apply(s._photo().pixels)
    plan = s.separation
    assert plan is not None
    for k in range(3):
        expected = make_negative(coat_image(curved, plan, k), s._negative_settings(k), 100.0)
        assert np.array_equal(s.render_layer(s._photo().pixels, k), expected)
        assert not np.array_equal(expected, plain[k])
    s.set_coats_curve(None)
    assert "Coats curve: none" in s.summary()
    assert np.array_equal(s.render_layer(s._photo().pixels, 0), plain[0])
    s.set_separation(None)
    s.set_coats_curve(coats)  # only used with a separation
    assert np.array_equal(
        s.render(s._photo().pixels), make_negative(s._photo().pixels, s._negative_settings(), 100.0)
    )


def test_chart_photo_through_the_coats(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    chart = tmp_path / "chart.tif"
    assert main(["target", "--kind", "chart-photo", "--dpi", "50", "-o", str(chart)]) == 0
    assert np.array_equal(tifffile.imread(chart), chart_photo(dpi=50))
    coats = process_file(tmp_path, "coats.oqproc", "green", 1.3)
    out = tmp_path / "neg.tif"
    base = ["negative", str(chart), "-o", str(out), "--registration", "--separations", "2"]
    assert main(base) == 0
    plain = tifffile.imread(tmp_path / "neg-1of2.tif")
    assert main([*base, "--coats-curve", str(coats)]) == 0
    assert not np.array_equal(tifffile.imread(tmp_path / "neg-1of2.tif"), plain)
    assert "process chart as a photo" in capsys.readouterr().out


def test_one_round_puts_the_stacked_coats_on_target() -> None:
    plan = SeparationPlan.from_steps([10, 20], 30, 1)

    def stacked(coats: ProcessCurve | None) -> np.ndarray:
        photo = chart_photo(dpi=100)
        photo = coats.apply(photo) if coats else photo
        negatives = [
            make_negative(coat_image(photo, plan, k), NegativeSettings(
                colour="green", registration=True, label=k + 1, clear_targets=True), 100)
            for k in range(plan.count)
        ]  # fmt: skip
        return scanned(gum_print(negatives), "as scanned")

    before = read_chart(stacked(None))
    coats = build_process_curve(before)
    after = read_chart(stacked(coats))
    assert np.abs(tone_errors(before)).max() > 5  # uneven coats: well off target
    assert np.abs(tone_errors(after)).max() < 1  # within a lightness unit everywhere
    assert np.abs(tone_errors(after)).mean() < np.abs(tone_errors(before)).mean() / 10
