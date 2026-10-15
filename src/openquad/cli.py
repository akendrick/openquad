"""Command-line entry point."""

import argparse

from openquad import __version__


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="openquad", description=__doc__)
    parser.add_argument("--version", action="version", version=f"openquad {__version__}")
    return parser


def main(argv: list[str] | None = None) -> int:
    build_parser().parse_args(argv)
    return 0
