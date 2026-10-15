"""Deliberately failing test: proves CI blocks merging a red PR. Removed in the next commit."""


def test_gate_demo_must_fail() -> None:
    assert 1 == 2
