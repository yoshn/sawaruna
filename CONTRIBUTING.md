# Contributing to Sawaruna

Thank you for helping. Sawaruna is a small project kept by one person, so replies may take a few days.

日本語でも大丈夫です。Issue やプルリクエストは日本語で書いてかまいません。

## Reporting a bug

Open an [issue](https://github.com/yoshn/sawaruna/issues/new/choose) and include:

- Mac or Windows, and the OS version
- The Sawaruna version
- What you did, what you expected, and what happened

## Reporting a security problem

Please do not open a public issue. Use [private vulnerability reporting](https://github.com/yoshn/sawaruna/security/advisories/new). See [SECURITY.md](SECURITY.md).

## Suggesting a change

Open an issue first for anything larger than a small fix, so we can agree on the approach before you write code.

## Pull requests

- Keep each pull request to one change.
- The Mac app is `Sawaruna.swift`. Build it with `zsh install.command`.
- The Windows app is `windows/sawaruna.c`. Build it with `sh windows/build.sh` (MinGW-w64). GitHub Actions also builds it on every pull request.
- Sawaruna must never connect to the network and must never read or record which keys are pressed. Changes that add either will not be merged.
- For translations, edit `Localizations.json` (Mac) or `windows/l10n/windows_translations.json` (Windows), then run `python3 l10n/gen_l10n.py` in `windows/`.

## License

By contributing, you agree that your contribution is licensed under the [GPL-3.0-or-later](LICENSE). The name and logo are covered by [TRADEMARKS.md](TRADEMARKS.md).
