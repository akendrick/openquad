"""Phase 0 smoke tests: the package imports and the CLI runs."""

import re

import pytest

import openquad
from openquad import cli


def test_version_is_semver() -> None:
    assert re.fullmatch(r"\d+\.\d+\.\d+", openquad.__version__)


def test_cli_runs_with_no_arguments() -> None:
    assert cli.main([]) == 0


def test_cli_version_flag(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as exc:
        cli.main(["--version"])
    assert exc.value.code == 0
    assert openquad.__version__ in capsys.readouterr().out
