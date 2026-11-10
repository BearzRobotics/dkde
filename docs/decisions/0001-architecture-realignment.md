# 0001 — Architecture realignment: gap analysis and migration order

**Status:** APPROVED 2026-11-04 (decisions in §4); steps 1–6 implemented and uncommitted, step 7 stopped for a decision, step 8 started. See §8.
**Date:** 2026-11-04
**Inputs:** `ai/DKDE-SPEC.md`, `ai/DKDE-REQUIREMENTS.md`, `ai/AGENTS.md`; legacy inventory `ai/DKDE-LEGACY-REQUIREMENTS.md` (reference only).
**Method:** read `build.zig`, `build.zig.zon`, directory layout, line counts and targeted greps. Nothing was built or run. Items marked *(unverified)* need a check before work starts.

## 1. Problem

The new spec changes DKDE from "panel + apps + console + terminal in one tree" to "a Wayland shell and utility suite whose apps are build- and runtime-independent". The tree still reflects the old shape. This document lists the gaps and proposes an order that keeps `master` building at every step.

## 2. Gap analysis

| # | Area | Spec / Req | Current state | Gap |
|---|------|-----------|---------------|-----|
| G1 | Console | SPEC §4, §19.1; DKDE-015, 073 | `src/console` (4.5k lines), `addConsole()` in `build.zig`, `test-console` step, `-Dgui=false`, `data/console.conf`, `scripts/qemu-console-test`, dinit/sysvinit/systemd templates *(unverified which are console-specific)* | Remove from DKDE; carry requirements to DKConsole's own spec. |
| G2 | termcore | §4, §19.2 | `src/termcore` (0.7k lines), built in-tree | Remove; consume external DKTermCore. |
| G3 | Terminal | §9.2, §26.2 | `src/term` (2.1k lines) is a DKDE component using ghostty-vt + termcore | Becomes external DKTerm. DKDE keeps launcher / default-terminal / theme integration only. |
| G4 | Settings ↔ console coupling | §6.3, §11.3 | `src/settings` imports `termcore` and `consolefont` (a module from `src/console`); `consolepage.zig`, `termpreview.zig` | Replace with the documented DKConsole CLI (optional integration). Biggest coupling to untangle. |
| G5 | Build independence | DKDE-010..014, §21 | One `inline for` over a `components` list builds every app on a bare `zig build`. No `-Dapp=` selector. `run-<name>` steps exist; no per-app install step. Desktop-entry install loop and `b.installDirectory(data → share/dkde)` install **everything** | Add `-Dapp=`; per-app install staging only its binary, `.desktop`, assets; clean-prefix test. Note `test` step depends on all apps' tests. |
| G6 | Shared module shape | §6.3, §22; DKDE-023 | Single `common` module (4.7k lines, 25 files) imported by 56 files; mixes pure logic (`civil`, `ics`, `paths`) with GTK (`dialogs`, `menubar`, `style`) and system code (`power`, `audio`, `elevate`, `labwc`) | An app that wants only `civil` still links GTK/gio. Probably needs splitting into core (no GTK) and UI modules. The spec's "UI module" is today's `common` plus things that aren't UI. Needs a decision. |
| G7 | Runtime independence | DKDE-020..022 | Unknown. Panel-coupled paths to audit: `common/labwc.zig`, `notify`, `perf`, `view/main.zig` reads `panel.conf`, `idle` reads `panel.conf` *(unverified whether any app needs the panel running)* | Audit + test harness (no panel, no session bus, other binaries off PATH). |
| G8 | CLI contract | DKDE-024, §20.2 | Only 2 files mention `--help`/`--version` | Add to every app; nonzero exit on bad args; stderr on fatal startup error. |
| G9 | Config format | §11.1, §23; DKDE-060..062 | `common/config.zig` wraps `GKeyFile` (INI). Files: `dkde.conf`, `panel.conf`, `term.conf`, `files.conf`, `hex.conf`, `edit.conf`, `calendar.conf`. `setup/main.zig` writes them. `scripts/check-config-defaults.py` checks defaults | Replace with TOML via `~/de/toml-zig`, plus migration tool with backup. See §4 on toml-zig status. |
| G10 | State vs config | §23 | Recent files / pins may live in config (`taskbar_pins.zig` writes `panel.conf`) *(unverified)*; `common/state.zig` exists | Move state to `XDG_STATE_HOME`. |
| G11 | Privilege model | §24; DKDE-064..069, 076, 077 | `src/polkit` is a **Polkit agent** (D-Bus, registers with polkitd; 0.7k lines) and `src/polkit-ui` its dialog — that matches spec. `common/elevate.zig` and `src/disks` / `src/parted` / `power.zig` need review: do they elevate via `pkexec`/`sudo`, or via narrow helpers? | Spec requires per-action policies + separately authorizing helper services; none exist *(unverified)*. Validation on musl/dinit/seatd without logind is unproven (open decision 7). |
| G12 | Session / greeter / setup | §28; DKDE-073 | `src/greeter`, `src/setup`, `scripts/dkde-session`, `dkde-greeter-*`, `dkde-seatd`, X11 session scripts, `-Dx11` option | Spec says DKDE is Wayland-native with no X11 backend and "do not create a session launcher merely to satisfy an untested assumption". Triage: greeter / setup are `PLANNED` in DKDE-051; X11 backend and `dkde-xsession`/`startx` conflict with §4 non-goal. Decide keep/reject. |
| G13 | Hex Kaitai/YAML, PDF | §9.4 | `third_party/zig-yaml` (hex), `zpdf`, `stb`, poppler optional via `-Dpdf` | Fine for independence if gated per app. PDF needs the "unsupported editing is identified" smoke test. |
| G14 | Docs | AGENTS §4 | `docs/architecture.md` absent; `docs/decisions/` empty; manpages only a template; README and `src/**` (127 refs) cite old `SPEC.md` section numbers | Write architecture doc and per-app manpages; update `SPEC.md N.N` code comments as files are touched, not in one churn commit. |
| G15 | Traceability | DKDE-075, §20 | None | Table of every legacy feature → app, priority, issue, test. Large (legacy file is 74 KB). |
| G16 | Test gates | DKDE-070..072, §25 | Unit tests only; no isolation, musl+glibc matrix, or crash-isolation tests | Add `tests/` scripts; start with two dissimilar apps (suggest `calc` + `hex`). |

## 3. Proposed order

Each step leaves `master` buildable and is independently reviewable.

0. **Docs (this step).** Fix cross-references (done: `DKDE-SPEC.md`/`DKDE-REQUIREMENTS.md` now say `ai/AGENTS.md`). Resolve open decisions in §4 below.
1. **Build selector, no behavior change (G5).** Introduce `-Dapp=<name>` and per-app install while keeping default `zig build` = everything. Prove isolation for `calc` and `hex` from clean cache and clean `DESTDIR`. This is the safest first code change and de-risks everything after it.
2. **Detach console / termcore / term (G1–G4).** In order: (a) make settings stop importing `termcore`/`consolefont`; (b) delete `src/console`, `src/termcore`, `termcoreModule/consoleFontModule/addConsole`, `-Dgui`, `ghostty` dep from settings; (c) move console assets/tests/templates and their requirements into the DKConsole repo first so nothing is lost; (d) decide whether `src/term` is moved to the DKTerm repo or kept until DKTerm is releasable. Do (d) last; deleting it before DKTerm exists removes the only terminal.
3. **CLI contract (G8).** Mechanical, one shared helper, per-app tests.
4. **Runtime-independence audit + harness (G7, G16).** Findings may change step 5.
5. **Split `common` (G6).** Only after 1 and 4 show what each app really needs. Smallest split that works: `dkde-core` (no GTK) and `dkde-ui` (GTK).
6. **TOML config (G9, G10).** Depends on toml-zig being usable (§4) and on step 5. Migration tool with backup, then switch each app.
7. **Privilege model (G11).** Review first; helper services and policy XML per action; Polkit validation on FenrirOS.
8. **Triage legacy features (G12, G15) and write docs (G14)** continuously, finishing before a release.

## 4. Open decisions that block steps

1. **toml-zig is not yet usable.** `~/de/toml-zig` holds only `ai/AGENTS.md`, an **empty** `ai/SPEC.md`, empty `docs/` subfolders and an empty `test/`. There is no `build.zig`, `build.zig.zon` or source. Step 6 is blocked until it has a parser (TOML 1.0 decode, encode with comment/unknown-key preservation as §23 wants, error positions). Options: (a) write toml-zig first, (b) adopt an existing Zig TOML library, (c) temporarily keep GKeyFile. Recommendation: (a), since you chose it, but its SPEC needs writing; step 6 is the last-but-two, so there is time.
2. **Common split (G6):** accept `dkde-core` / `dkde-ui`, or keep one module and rely on the linker discarding unused code? Measure binary size and link inputs for `calc` before deciding.
3. **X11 backend, X session scripts, greeter, setup (G12):** keep, defer, or reject.
4. **`src/term`:** keep in tree until DKTerm ships, or move now?
5. **App names and `-Dapp` syntax (spec §26.1):** current names are `dkde-files`, `-term`, `-disks`, etc. Spec lists `dkde-help` (no code exists) and does not list `disks`, `idle`, `pointer`, `notify`, `tasks`, `charmap`, `color`, `setup`, `greeter`. Confirm which are in the v1 table.
6. **Other §26 items** (initial stable UI API, help viewer formats, Polkit/labwc validation) are not blocking until steps 5–7.

## 5. Alternatives considered

- **Big-bang rewrite on a branch.** Rejected: no working desktop for weeks, and AGENTS §14 prefers small reviewable changes.
- **Do TOML first.** Rejected: toml-zig does not exist yet, and the config layer sits in `common`, which step 5 will reshape; doing TOML first means doing it twice.
- **Delete console first.** Rejected: it is the most visible change but not what blocks independence, and G4 shows settings depends on it, so the order must be settings first.

## 6. Risks

- Deleting console/term code before DKConsole/DKTerm contain it loses history of working code. Tag the last commit that has them (e.g. `pre-split`) and verify the other repos build.
- `inline for` over `components` is comptime-heavy; a `-Dapp` selector can hit limits with `lazyDependency` (gobject, wayland are lazy and `return` early). Prototype in step 1 before committing to the design.
- Everything marked *(unverified)* above.

## 7. Consequences if approved

Step 1 is the first code change. No documentation claims here about current behavior beyond what was read in `build.zig` and the directory listing.

## 8. Progress (2026-11-04)

Decisions taken: write toml-zig first; accept the `dkde-core` / `dkde-ui` split; drop X11 (re-adding is welcome as a contribution); keep `src/term` and `src/termcore` until DKTerm/DKTermCore ship as packages; every program is in the v1 table.

| Step | State | Verification actually run |
|---|---|---|
| toml-zig | Done in `~/de/toml-zig` (own repo, one local commit; 39 tests). The official `toml-test` suite has **not** been run. | `zig build test` |
| 1 `-Dapp=` | Done. `zig build -Dapp=X [install]`, `test-X` steps; per-app install carries only that program, its `.desktop`, `style.css`, `dkde.toml` and its own defaults. The full install's file list matched the old build's when this step was done (before the later INI→TOML renames). | `tests/build-isolation.sh calc hex files` |
| 2 Detach | Console removed (`src/console`, its build code, data, service templates, QEMU harness, Terminus fonts, Settings "Console" page). X11 removed (`-Dx11`, panel/snip backends, X session scripts, setup check). `termcore`, `term` and the ghostty dependency stay. Code is in git history; tag `pre-split-2026-11-04` marks the last commit with it. **Nothing was copied into `~/de/dkconsole` or a DKTermCore repo; those need the code extracted from the tag.** | full build |
| 3 CLI contract | Done. `src/cli.zig` (own module, no GTK): `--help`/`--version` exit 0, unknown option exits 2, `--` ends options. All programs and the four shell scripts follow it (`dkde-seatd` forwards other options to seatd). | `tests/cli-contract.sh` |
| 4 Runtime independence | Harness written; 15 graphical programs stayed up 4 s with no panel, no session bus and only their own binary on `PATH`. Panel not covered (it is the thing being removed); "kill the panel while an app runs" **not tested**. Audit findings below. | `tests/runtime-independence.sh` (needs `WAYLAND_DISPLAY`; ran against WSLg) |
| 5 Split | Done as `core` (GLib/GIO, no GTK) and `common` (re-exports core + GTK widgets), so existing `common.x` code is unchanged. `notify`, `setup`, `idle` now import only `core` and do not link GTK. | `ldd` shows no GTK; full build |
| 6 TOML | Done. `Config` keeps its API but reads TOML (`*.toml`; group = top-level table); malformed user file → defaults and refuses to save; saves under an advisory lock and atomic rename; unknown keys survive; comments survive too (saving edits the file as text, and toml-zig 0.2.0 keeps comments on the fallback rewrite). `dkde-setup --migrate-config` converts old INI (original kept as `.conf.migrated`, existing `.toml` never overwritten). Apps only warn when a legacy file is found. | 24 new unit tests (config, migrate); migration run by hand on a sample |
| 7 Privilege | **Stopped; needs your decision (§9).** | — |
| 8 Triage / docs | `docs/architecture.md` written. Legacy-feature traceability table and manpages **not** done. | — |

### Audit findings (step 4)

- No program talks to the panel at start-up. `dkde-panel msg …` appears only in labwc key bindings (`common/labwc.zig`), so with no panel those keys do nothing.
- Programs launch each other only for optional actions (Terminal → Settings, Files → Terminal, Tasks → Files).
- The session bus is used only by `common/notify.zig` (skips with a log line if no bus) and the Polkit agent.
- `desktop.toml` (desktop icon positions) and `taskbar-pinned`/`pinned` lists are written into the config directory although they are state (spec §23). Not moved yet.
- `common/state.zig` still stores recent items as an INI keyfile (`recent.conf` under `XDG_STATE_HOME`). The spec only requires TOML for settings, so it was left.

### Not done / known gaps

- `data/*.toml` file names (`dkde.toml` for shared settings, not `config.toml`) are my choice; spec §23 says "to be frozen".
- `[context]` menu lists in `files.toml` are still `;`-separated strings, not arrays.
- Two pre-existing test failures in `pdfrender` (`render.test.inline images…`, `type1.test…`) fail identically on the commit before this work; not investigated.
- `toml` is a path dependency on `../toml-zig`, so this repository does not build without that sibling checkout until toml-zig is published and pinned by hash.
- About 71 tests went with the console code; the suite is at 360 passing (5 skipped, 2 failing as above) because tests were added for toml-zig use, config, migration and the CLI contract.

## 9. Step 7: privilege model — decision needed

`common/elevate.zig` shows its own password dialog and runs `sudo -S` with the typed password. DKDE-066 and spec §24 forbid exactly this (no DKDE password prompt, no generic sudo). It is used by:

| Caller | What it elevates |
|---|---|
| `parted` | applying partition changes, running partition tools |
| `hex` | opening a raw disk |
| `files` | open folder / run program as administrator |
| `settings` | time zone, system clock, add/remove printers, other system pages |
| `panel/startmenu` | run program as administrator |

The agent `src/polkit` (and its dialog `src/polkit-ui`) already matches the spec's *agent* requirement. What does not exist: privileged helper services with their own Polkit checks, policy XML, and any validation on musl/dinit/seatd without logind.

DKDE-076 says: until that is validated, document privileged features as **unavailable** instead of using custom elevation. Following it literally disables the features above. Options:
1. Disable them now (honest, matches the spec, regresses working features).
2. Keep `elevate.zig` behind a build flag `-Dlegacy-sudo=true`, off by default, removed once helpers exist.
3. Build the helpers first, one per action family (disks, time, printers), then remove `elevate.zig`.

Recommendation: 2 now, 3 next, starting with `parted`/disks because that is the destructive one.
