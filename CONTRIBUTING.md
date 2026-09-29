# Contributing to USOS

Thank you for helping with Universal Service OS. Bug reports, hardware test
results, translations and code are all welcome.

## Before you start

- **Bugs and hardware results:** open an issue with the build ID from the
  menu header (for example `B260928-203656`), the machine (board, CPU,
  graphics card), the firmware mode (BIOS, UEFI with CSM, UEFI without CSM,
  Secure Boot on/off) and the logs listed in the user guide
  ([docs/USER-GUIDE.en.md](docs/USER-GUIDE.en.md), "Troubleshooting").
  Remove serial numbers, product keys and personal data from logs and
  photos first.
- **Code:** read [PROJECT_RULES.md](PROJECT_RULES.md) (small files, tests for
  every change, no stubs) and [docs/BUILDING.md](docs/BUILDING.md). Every
  change must pass `build.bat` and `tools\tests\run.ps1`.
- **Never** add Windows ISOs, product keys, activation workarounds, private
  keys or the USOS signing key (`%APPDATA%\USOS\signing`) to the repository.
- **Third-party code** goes under `tools/vendor/<name>/<version>/` with its
  licence, its source (or `SOURCES.txt` with an exact upstream revision) and
  an entry in `tools/release/third-party.json`. Its licence must allow
  redistribution with USOS.
- **Compatibility fixes** whose licence does not allow bundling get an own
  USOS implementation: clean-room, `GPL-3.0-or-later`, written from public
  documentation and observed behaviour, never from leaked source code.
  User-supplied files in `DATA\Drivers` / `DATA\Fixes` are only a temporary
  bridge until that exists (see [docs/ROADMAP.md](docs/ROADMAP.md), L6,
  "Zasada").

## Licence of contributions

USOS is licensed under the GNU General Public License, version 3 or (at your
option) any later version (`GPL-3.0-or-later`, see [LICENSE](LICENSE) and
[NOTICE](NOTICE)). You keep the copyright in your contributions. In addition
to the GPL, you grant the maintainer the licence below, so the project can
also offer USOS under other terms (for example a commercial licence) without
tracking down every contributor. Please state in your first pull request
that you agree to it ("I agree to the USOS Contributor Licence Grant").

### USOS Contributor Licence Grant (version 1.0)

Based on the Apache Individual Contributor License Agreement and the
Harmony Agreements, shortened.

1. **Definitions.** "You" is the person or entity submitting a
   Contribution. "Contribution" is any work of authorship (code,
   documentation, translations, artwork) that You submit to the USOS project
   for inclusion, for example as a pull request, patch or issue attachment,
   unless You mark it in writing as "Not a Contribution". "Maintainer" is
   Maksymilian, who runs the USOS project, and the Maintainer's successors as
   maintainer of the project.
2. **Copyright licence.** You grant the Maintainer and the recipients of
   software distributed by the Maintainer a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable licence to
   reproduce, prepare derivative works of, publicly display, publicly
   perform, sublicense and distribute Your Contributions and such
   derivative works, under the GPL-3.0-or-later **and under any other
   licence terms**, including proprietary ones, that the Maintainer
   chooses.
3. **Patent licence.** You grant the same parties a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable patent licence to
   make, use, sell, offer to sell, import and otherwise transfer Your
   Contribution, for the patent claims You can licence that are necessarily
   infringed by Your Contribution alone or together with USOS.
4. **You keep your rights.** You keep the copyright in Your Contributions
   and may use them in any other way You like.
5. **Your promises.** You are legally entitled to grant this licence. Each
   Contribution is Your original work, or You have the right to submit it
   and You say so, naming its origin and licence (for example third-party
   code under `tools/vendor`). If Your employer has rights in Your work, You
   have its permission or it has waived those rights.
6. **No warranty.** Contributions are provided "as is", without warranties
   or conditions of any kind, unless You agree otherwise in writing.
7. **Commitment.** Whatever other terms the Maintainer offers, every
   version of USOS that includes Your Contribution and is published by the
   Maintainer remains available under the GPL-3.0-or-later as well.

At publish time the maintainer can enable the
[CLA assistant](https://github.com/cla-assistant/cla-assistant) bot on
GitHub, so contributors can accept this grant with one click in the pull
request instead of writing it.

## Translations

The UI strings live in `installer/internal/i18n/locales/<locale>.json`
(English is the reference); `go run ./cmd/usos-i18n-gen` in `installer/`
regenerates the menu tables. Translated READMEs are in `docs/readme/`; the
English `README.md` is authoritative.
