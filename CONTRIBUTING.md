# Contributing

- Branch from `main` per task (`feat/...`, `fix/...`); open a PR; CI must pass before merge.
- Commit messages use Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`).
- Every change ships with tests. Every bug fix starts with a failing test that reproduces it.
- Core coverage must stay at or above 90%.
- Update `CHANGELOG.md` under "Unreleased" in the same PR.
- Spelling: use **colour** (not "color") in code, comments, docs and UI text. Keep "color" only
  where an external API requires it (e.g. Qt's `QColor`).
