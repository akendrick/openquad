import pytest

from openquad.units import box, from_unit, length, size, to_unit


def test_lengths_in_either_unit() -> None:
    assert length(0.25, "in") == "0.25 in"
    assert length(0.25, "mm") == "6.35 mm"
    assert length(from_unit(5.0, "mm"), "mm") == "5 mm"
    assert box(8.0, 10.0, "in") == "8 x 10 in"
    assert box(8.0, 10.0, "mm") == "203.2 x 254 mm"
    assert size(7.5, 5.0, "in") == "7.50 x 5.00 in"
    assert size(7.5, 5.0, "mm") == "190.5 x 127.0 mm"


def test_conversion_round_trips() -> None:
    assert to_unit(1.0, "mm") == pytest.approx(25.4)
    assert from_unit(to_unit(0.37, "mm"), "mm") == pytest.approx(0.37)
    assert to_unit(0.37, "in") == 0.37
    with pytest.raises(ValueError, match="units"):
        length(1.0, "cm")
