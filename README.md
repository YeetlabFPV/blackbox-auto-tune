# Blackbox Auto-Tune

Public test build for FPV pilots using Betaflight. The macOS app reads Blackbox flight logs locally, highlights tracking and filter issues, and suggests small, reversible tuning changes when the measurements support them.

## Get started on macOS

Requirements are macOS 14 or later, Apple Command Line Tools with a recent Swift compiler, Git and Python 3.9–3.12. If needed, install the Apple tools with `xcode-select --install`.

```sh
git clone https://github.com/YeetlabFPV/blackbox-auto-tune.git
cd blackbox-auto-tune
bash setup.sh
open "outputs/Blackbox Auto-Tune.app"
```

Keep the built app inside the checkout. The setup script creates a local Python environment and builds the official Betaflight Blackbox decoder at a pinned revision. Use `PYTHON_BIN=/path/to/python3.12 bash setup.sh` if your interpreter has a different path.

## Test a flight

1. In Acro (Air), fly a few steady passes at different throttle levels, then several isolated rolls and flips in both directions.
2. Load one or more `.bbl` files recorded with the same settings. A Betaflight CLI dump is optional.
3. Read the dashboard. If it offers a change, record the original setting and make only the proposed change. Repeat similar passes and manoeuvres for the comparison.
4. Open a GitHub issue with your firmware version, quad size, what you observed and what the app reported. Include flight files only if you are comfortable sharing them publicly.

The CLI mappings cover Betaflight 4.5.x, 2025.12.x and 2026.6.x, including the verified 2025.12.0-beta build `9d3558c3f`. CLI proposals also depend on the recorded signals and manoeuvre coverage. See the [German flight and tuning guide](outputs/Anleitung.md).

Flight logs and reports are processed on your Mac. The app writes reports to `work/Flugberichte`. [Betaflight Blackbox Tools](https://github.com/betaflight/blackbox-tools) is built separately from its upstream source.
