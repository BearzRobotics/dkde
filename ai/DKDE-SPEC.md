# DKDE — Specification

**Status:** Consolidated design specification 1.0 (2026-11-04); design baseline, not an implementation-complete claim

**Engineering foundation:** `ai/AGENTS.md`. This document supplements, rather than replaces, its engineering rules.

## 1. Purpose

Become a dependable daily-driver desktop environment.

## 2. Vision

DKDE is a small, cohesive Wayland desktop shell and application suite with a classic Windows layout: bottom taskbar, Open-Shell-style Windows 7 Start menu, and matching core applications. It should feel like one product rather than unrelated tools.

Cohesion is enforced by (1) one shared UI toolkit and stylesheet, (2) one configuration convention, and (3) Freedesktop standards for desktop entries, icons, MIME types and user directories.

The reference distribution is **FenrirOS** (musl, LLVM/Clang, dinit, no systemd). DKDE must also work on ordinary glibc Linux distributions.

## 3. Goals

- Windows 7-style taskbar: Start button, running applications, clock, StatusNotifierItem tray, configurable widgets, position and auto-hide.
- Windows 7-style Start menu: pinned/recent apps, All Programs, search and right-hand places.
- Cohesive, independently executable applications: file manager, settings, editor, image viewer, hex editor, PDF viewer/editor, partition manager, calculator, clock, calendar, screenshot tool and help viewer.
- Integration with the separately maintained **DKTerm** terminal, using **DKTermCore** for terminal emulation. DKTerm targets a Windows Terminal-like experience with tabs, profiles and split panes.
- Operation under labwc without requiring systemd or logind. A session D-Bus is optional; dependent features degrade gracefully when absent.
- Support building and installing individual applications without requiring the complete desktop suite.

## 4. Non-goals

- Writing a compositor: labwc is the compositor.
- Depending on libadwaita or a GNOME desktop stack beyond the explicitly selected GTK4/GLib/GIO libraries.
- An Xorg desktop backend. Xwayland compatibility for legacy applications is a separate integration concern, not an X11 backend for DKDE itself.
- Owning or building **DKConsole**. It is a separate, standalone project and is not part of the DKDE desktop or its build graph.
- Owning **DKTermCore**, which is an independent library.

## 5. Design philosophy

### 5.1 Simplicity
Keep the architecture small, explicit and maintainable. Avoid unnecessary services and runtime dependencies.

### 5.2 Efficiency
Minimize idle memory, background CPU activity, wake-ups and startup latency. Measure regressions.

### 5.3 Consistency
Use shared components, stylesheet, interaction patterns, icons and configuration conventions across the suite.

### 5.4 Compatibility
Respect Freedesktop specifications and musl/glibc portability. Do not rely on systemd or logind.

## 6. Project and application independence

**DKDE is one repository and one coherent package bundle.** Applications are not required to be separate repositories. Two forms of independence are mandatory:

### 6.1 Build independence

- Every application has its own executable target and can be selected, compiled, tested and installed without building unrelated applications.
- The root `build.zig` is the authoritative orchestrator for the complete bundle and individual application targets.
- A future per-application `build.zig` is permitted but not required. Begin with shared root build helpers; nested build files must not duplicate dependency definitions or version pins.
- Proposed user-facing commands (to be implemented and tested): `zig build`, `zig build -Dapp=files`, `zig build -Dapp=hex`, `zig build test`, `zig build -Dapp=files install`.
- Building an individual application must not compile or link unrelated GUI applications, nor start a compositor.
- Shared dependencies may still be compiled when genuinely required by the selected application.
- Root build options and the actual target names must be documented and covered by CI.

### 6.2 Runtime independence

- Every DKDE utility can launch and perform its primary function without `dkde-panel` running.
- No utility may rely on another DKDE executable being resident merely to start, open files, edit data or exit cleanly.
- Optional desktop integrations (notifications, tray, wallpaper, launchers, panel IPC) must fail gracefully if their service is unavailable.
- A graphical application still requires its documented display/toolkit environment; runtime independence does **not** mean running a GTK application on a bare Linux VT.
- An application may call another executable for a clearly documented optional feature, but its core function must remain usable without that executable.
- External system tools or services (e.g., mounting, printing, audio, Bluetooth) may be required for their respective features; absence must be diagnosed rather than crashing the application.

### 6.3 Source and dependency boundaries

- Applications share the DKDE UI Zig module, CSS/theme assets and common integration modules, not each other's private implementation modules.
- The shared UI module is consumable directly from Zig and has a planned C wrapper for non-Zig consumers.
- Shared UI does not imply that the panel owns or hosts application widgets.
- DKTerm is a separate repository/application, and may consume the DKDE UI library through a documented dependency; DKDE must not depend on DKTerm internals.
- DKTermCore is an external terminal library, not `src/termcore` in DKDE.
- DKConsole is an external system console, not `dkde-console` or a DKDE build target. DKDE Settings may optionally configure it through DKConsole's documented CLI without importing its implementation.

## 7. System requirements

### 7.1 Hardware
Define and benchmark minimum CPU, RAM, display and input requirements before stable release.

### 7.2 Software
Linux with Wayland, labwc, GTK4/GLib/GIO and selected layer-shell/Wayland protocol support. No systemd or logind requirement. Optional features may use a session D-Bus and external system services.

### 7.3 Supported environments
FenrirOS musl is the reference; glibc-based Linux distributions are supported. Xwayland applications may run under labwc without making DKDE itself an X11 application.

## 8. Desktop shell

### 8.1 Panel
Taskbar, clock, Start button, tray, widgets, task buttons, grouping, pinning, edge placement and auto-hide.

### 8.2 Menus
Windows 7/Open-Shell-inspired Start menu with pinned/recent programs, search, All Programs and places. Launch applications using Freedesktop desktop entries.

### 8.3 Notifications
Implement the desktop notifications specification over the optional session D-Bus. Lack of a bus must not prevent the shell from starting.

### 8.4 Wallpaper
Per-output wallpaper handling with configurable fit and color.

### 8.5 Workspaces
Integrate with labwc and available Wayland workspace protocols; do not invent compositor-private APIs.

## 9. Desktop applications

### 9.1 File manager
Nautilus-level local-file operations, drag/drop, copy/cut/paste, rename, trash, properties, views and removable media integration. Windows 11-style compact icon/emoji action row is a UI target.

### 9.2 Terminal integration
DKTerm is independently maintained. DKDE integrates its launcher, default-terminal selection and theme where available; its terminal emulation implementation belongs to DKTermCore.

### 9.3 Editor
Notepad-style text editing with open/save, find/replace and configurable font/wrapping.

### 9.4 Utilities
Hex editor, image viewer, PDF viewer/editor, partition manager, clock, calculator, screenshots and calendar. Each remains independently buildable and executable under §6.

### 9.5 Help viewer
Provide a coherent application help interface; define supported document formats and search in its component design.

## 10. User interface and theming

### 10.1 Shared UI library
A shared Zig module supplies consistent widgets and appearance. Provide a documented C wrapper for third-party, non-Zig applications. The wrapper is a distinct ABI commitment and must not expose unstable Zig types directly.

### 10.2 Layout
Consistent spacing, navigation, menus, dialogs and keyboard behavior.

### 10.3 Theming
One stylesheet and shared theme variables; CSS-based customization remains supported.

### 10.4 Accessibility
Keyboard navigation, readable scaling and contrast are design requirements; specify supported accessibility APIs before declaring conformance.

## 11. Configuration and settings

### 11.1 Persistence
Use TOML as the common DKDE-owned configuration format, with XDG paths for per-user files. Do not replace standard formats such as `.desktop`, `mimeapps.list`, labwc XML or other protocol-defined files with TOML. Treat migration from the old INI files as a separately tested change.

### 11.2 Preferences
Each app owns its settings schema; common appearance settings are shared. Config writes are atomic, validated and monitored where live reload is supported.

### 11.3 System integration
Settings may manage system tools via documented interfaces and explicit privilege boundaries. DKConsole configuration is an optional external integration, not a DKDE dependency.

## 12. Desktop integration

### 12.1 Wayland
Use supported Wayland protocols for surfaces and window-management integration.

### 12.2 Labwc
Labwc owns compositing, focus and window placement; DKDE supplies panel, launcher and user-facing integration.

### 12.3 Xwayland
Allow Xwayland applications to coexist when the compositor supports them; DKDE itself remains Wayland-native.

### 12.4 Freedesktop standards
Use desktop entries, XDG Base Directory, MIME associations, icon themes, user directories and relevant D-Bus specifications.

## 13. Performance and resources

Measure and publish idle RSS, CPU usage, cold/warm startup, input latency and file-operation throughput. Benchmarks must distinguish individual-app startup from full-session startup; avoid setting arbitrary numeric acceptance thresholds without baseline measurements.

## 14. Reliability and security

- Individual application crashes must not bring down the panel or other applications.
- A missing panel, bus or optional system service must not break core utility functions.
- Validate file inputs and configuration, use atomic writes, and preserve user data on failure.
- Disk/partition editing and privileged actions require explicit confirmation and constrained elevation.
- Test recovery from interrupted writes and missing dependencies.

## 15. Compatibility and portability

Use interfaces shared by musl and glibc. Avoid unguarded glibc-only APIs (`mallopt`, `malloc_trim`, `malloc_usable_size`, `mallinfo*`, `backtrace` from `execinfo.h`, `gnu_get_libc_version`, GNU `error` helpers, GNU `strerror_r`), assumptions about `__GLIBC__`, and hardcoded dynamic-linker paths. Optional glibc-specific functionality must be compile-time gated and never referenced in musl builds. Verify both `x86_64-linux-musl` and glibc builds.

## 16. Testing and acceptance

- **Functional:** each application's primary tasks work independently.
- **Build:** each application can be selected and built without unrelated application targets; full suite still builds from the root.
- **Integration:** shared theming, file associations, launcher, labwc and optional D-Bus features work together.
- **Regression:** configuration migration, crash isolation, no-panel startup and missing-service behavior.
- **Performance:** compare measured baselines for startup, RSS, CPU and latency.

## 17. Development and releases

Pin Zig and dependencies explicitly. Define versioning, maturity labels and compatibility policy before stable release. A bundle release may ship independently executable utilities without requiring independent release cycles.

## 18. Future directions and explicitly deferred work

- Per-application build scripts, if the root build becomes difficult to maintain.
- Stable C ABI for the shared UI library.
- Additional UI features and richer application capabilities as defined in per-app specifications.
- No compositor rewrite and no re-merging of DKConsole or DKTermCore into DKDE without an explicit architectural decision.

## 19. Migration notes from the old specification

1. Remove the old `dkde-console` component, service templates, source directory and console build/test targets from DKDE; move their requirements to DKConsole's own spec.
2. Remove in-tree `termcore` ownership; use the external DKTermCore library where relevant.
3. Treat DKTerm as a separately maintained graphical terminal, with DKDE integration rather than ownership.
4. Preserve detailed per-app requirements from the original DKDE spec in component specs or appendices; this architectural revision is **not** a claim that every legacy feature has been fully migrated.
5. Convert DKDE-owned INI configuration to TOML through a deliberate migration; do not silently reinterpret old files.

## 20. Detailed contracts and feature traceability (proposed)

The historical component-level design is retained in `DKDE-LEGACY-REQUIREMENTS.md`. This is a **requirements inventory**, not proof that any feature is implemented. No detailed app requirement is silently dropped. Before declaring a stable release, maintain a traceability table for each feature with: legacy section, owning application, priority (`required`, `planned`, `deferred`, `rejected`), implementation issue, test, and rationale for any change. The new architecture takes precedence where historical language still says `dkde-console`, in-tree `termcore`, or INI.

### 20.1 Executable ownership and standalone operation

| Component | Owns | Minimum independent smoke test |
|---|---|---|
| `dkde-panel` | panel, Start menu, wallpaper, tray and shell integrations | starts under labwc; quits/restarts without affecting other applications |
| `dkde-files` | file browsing and operations | open a directory, copy/rename a file, exit with panel absent |
| `dkde-settings` | desktop configuration UI | open appearance settings with panel absent; save valid config |
| `dkde-edit` | text editing | open, modify, save and reopen a UTF-8 text file |
| `dkde-hex` | binary editing and inspection | open a sample binary; read offsets; save a copy without panel |
| `dkde-view` | image viewing | open image, zoom, close |
| `dkde-pdf` | PDF viewing/editing as supported by milestone | open a fixture and render page; unsupported editing is identified |
| `dkde-parted` | partition and image operations | inspect a disposable image without root; never alter a real disk in tests |
| `dkde-calc` | calculator | evaluate a deterministic expression |
| `dkde-clock` | time utilities | run stopwatch and timer without notification service |
| `dkde-calendar` | calendar and events | open calendar and persist a test event without panel |
| `dkde-snip` | screenshots | capture via available Wayland protocol; explain unsupported compositor |
| `dkde-help` | documentation/help | open local help document without network access |

Additional utilities enumerated in the historical specification (`dkde-tasks`, `dkde-charmap`, `dkde-color`, PDF checker, greeter, setup, optional policy agent) remain in the feature inventory; they are not deleted by omission from this table. DKTerm and DKConsole are **not** DKDE executable targets.

### 20.2 Application lifecycle contract

Every GUI utility shall support `--help` and `--version`, return nonzero on invalid command-line arguments, report fatal startup errors to stderr, and use a documented application ID and `.desktop` entry where appropriate. File-taking apps accept file arguments or file URIs as documented; never interpret paths as shell commands. Optional panel integration must be detected at runtime. An app must not assume a session bus merely because a Wayland display exists.

## 21. Build graph and packaging contract (proposed)

The root build provides named build, test, and install targets for each app. `-Dapp=<name>` is the proposed selector; exact syntax is finalized only when implemented. `zig build -Dapp=hex` must exclude unrelated executable compilation and linkage. A per-app install installs the selected executable and **only** its needed assets, desktop entry, icons and MIME registrations. Full install installs the entire selected suite. Build and install steps must be independently testable in a clean staging prefix (`DESTDIR` or documented equivalent).

Dependency pins live in one authoritative root manifest. Optional features are explicit build flags; disabling PDF support must not disable unrelated utilities. Shared code is built as a reusable module, never by importing another app's `main.zig`. Tests must include a clean build of at least two dissimilar standalone apps and a full bundle build for both musl and glibc targets when toolchain dependencies permit.

The project should document install layout (`bin`, `share/applications`, `share/icons`, `share/mime`, `share/dkde`) and uninstallation ownership. No application should overwrite user configuration during upgrades. Packaging may split the bundle into packages while retaining one source repository and one release train.

## 22. Shared UI library contract (proposed)

The UI library is a Zig module providing theme tokens, common dialogs, action rows, navigation, error reporting, keyboard conventions and reusable widgets. It may wrap GTK4/GLib/GIO, but application-private widgets stay with their application until demonstrably reusable. A shared CSS entrypoint and versioned semantic style classes are mandatory; applications may add scoped CSS without overriding another app's styles. The planned C wrapper is **not** a stable ABI until versioned symbols, ownership rules, threading rules and an ABI test suite are specified.

The UI module must not depend on `dkde-panel` or assume the panel is present. External DKTerm may consume the UI module through an explicit package dependency; its build and runtime must remain independent of the DKDE shell.

## 23. TOML configuration contract (proposed)

- User configuration root: `${XDG_CONFIG_HOME:-$HOME/.config}/dkde/`; shared appearance in `config.toml`, application-specific settings in `<app>.toml` (exact filenames to be frozen before migration).
- State such as recent files and transient window history belongs under `XDG_STATE_HOME`, not configuration; caches belong under `XDG_CACHE_HOME`.
- Every key has a type, default, validation rule and ownership. Unknown keys are preserved on edits where practical; malformed files produce diagnostics and safe defaults without silent destruction.
- Writes use a temporary file in the same directory, flush, atomic rename and suitable permissions. Concurrent writers must not silently lose updates; define locking or conflict detection before multi-writer settings support.
- Changes are watched with event-driven reload and a debounce. Invalid reloads retain the last known good state where safe.
- Existing INI files require a one-time, documented, backed-up migration. Standard XDG and compositor-owned formats stay in their native formats.

Example (illustrative, not a finalized schema):

```toml
[appearance]
theme = "dark"
accent = "#3a6ea5"

[panel]
position = "bottom"
auto_hide = false
```

## 24. External services and privilege boundary (proposed)

The desktop must not require systemd, logind or a session bus to launch. D-Bus-dependent features (StatusNotifierItem, notifications, selected device integrations) report their unavailable status without terminating the panel. Filesystem mounting, printer administration, power actions, process control and disk editing use narrowly scoped privileged helpers or documented system tools. Do **not** accept arbitrary shell fragments from untrusted file names, labels, desktop entries or settings; pass arguments as arrays. Authentication and authorization are separate concerns: a password prompt alone does not make a privileged operation safe.

### Polkit authorization architecture (required)

DKDE uses **Polkit** as its standard authorization framework for privileged desktop operations. DKDE must not implement password verification, PAM authentication, shadow-file access, a custom authorization database, or a generic `sudo`/`su` password prompt. The normal panel and utilities run unprivileged.

- Provide or integrate a **Polkit authentication agent** for the graphical session. The agent handles authentication conversations using the system Polkit authority; it is not itself the authority. Only one agent should register for a given session, and agent absence must produce a clear denial/unavailable result rather than silent elevation.
- Privileged operations run in **separate, narrowly scoped system services/helpers** with well-defined D-Bus interfaces or other audited, constrained interfaces. The privileged service checks Polkit authorization for the *specific action and requesting subject* and independently validates all parameters. Authorization in a GUI alone is insufficient.
- Define namespaced action IDs (for example `org.dkde.disks.modify`) and ship policy XML with localized descriptions and least-privilege defaults. Do not grant broad root execution or accept arbitrary commands, paths, devices, or shell fragments as an elevation interface.
- Use the system's Polkit authority and its configured authentication stack; no DKDE-specific credential storage. Authorization is checked at operation time, not inferred from a previous prompt. Audit denied, granted and failed privileged actions without recording secrets.
- Disk changes, mounting protected resources, user administration, time changes and other system modifications each require separately scoped authorization. Read-only operations remain unprivileged wherever possible; destructive actions also require explicit UI confirmation even after authorization.
- **Deployment boundary:** Polkit typically communicates over the system D-Bus and may rely on platform-specific session identification and authentication services. DKDE must validate an actual Polkit build/configuration on FenrirOS (musl, dinit, seatd, without systemd/logind). Do not assume seatd replaces a Polkit session tracker or that every Polkit build supports this environment. Document the chosen authority, subject/session identification, agent registration and authentication backend before claiming production support.
- The desktop and ordinary utilities must still launch if the system bus, Polkit authority or authentication agent is unavailable. Privileged features fail closed with actionable diagnostics; they must not silently fall back to an in-house elevation mechanism.
- DKConsole remains outside this architecture and continues delegating login to the system `login` implementation.

Disk-editing utilities default to read-only inspection. Writes require a clear target identifier, an explicit confirmation and protection against mounted or in-use targets. Any recovery or clone operation must document error handling, partial output and resumption limits; never claim data was recovered if a read failed.

## 25. Verification matrix and release gates (proposed)

- **Build isolation:** each utility builds and installs with unrelated application targets disabled; dependency graph inspected for unintended links.
- **Runtime isolation:** start each utility in a Wayland session without panel, with session D-Bus unset, and with unrelated DKDE executables absent from PATH.
- **Configuration:** test missing, malformed, unknown and concurrent edits; verify migration preserves original files and values.
- **Compatibility:** test musl and glibc; verify the reference FenrirOS environment does not require systemd/logind.
- **Failure:** kill panel while a utility is open; restart panel; unplug removable storage during a file operation; simulate denied permissions and unsupported Wayland protocols.
- **Data safety:** test file overwrite conflicts, interrupted saves and disposable-disk operations, with no destructive tests against host drives.
- **Performance:** record reproducible baselines for idle panel RSS/CPU, cold launch, warm launch and interactive latency. Numerical release thresholds remain OPEN until measured.

A feature is not "done" solely because its UI exists; it needs a reproducible acceptance test and documented failure behavior.

## 26. Open decisions (explicit)

1. Freeze executable names and per-app install step syntax.
2. Decide whether DKTerm ships in the DKDE distribution bundle as an external dependency, without bringing its source into this repository.
3. Define the initial stable shared-UI API and postpone the C ABI until tested.
4. Choose a TOML parser dependency and finalize the migration mapping from legacy INI keys.
5. Prioritize the very large legacy application feature set into milestones rather than treating all of it as v1.
6. Define the help viewer's source formats and search scope.
7. Validate Polkit authority, authentication-agent and subject/session support on the reference seatd/dinit system without logind.
8. Validate protocol availability in the minimum supported labwc version, including task management and screenshots.


## 27. Build independence and runtime independence (adopted)

These are the **two required forms of independence** for DKDE's bundled applications. Repository independence is not a goal: the desktop and its utilities remain one coherent source repository and may share a single release train, UI toolkit, CSS and root build graph. Each utility nevertheless has an independent executable, install selection, configuration ownership and tests.

- **Build independence:** a root-level selection builds a single named application and only its transitive library and asset dependencies. Building `dkde-hex` must not compile or link `dkde-panel`, `dkde-files` or `dkde-pdf`. Individual nested `build.zig` files are an optional organization choice; a single root `build.zig` with shared build functions is acceptable and preferred until needed otherwise. The build contract must be verified from a clean cache.
- **Runtime independence:** every utility can start and perform its primary functions in a supported Wayland session when the panel, other DKDE applications and optional desktop services are absent. Required underlying libraries, the Wayland compositor and a working display are not prohibited dependencies. Optional D-Bus and compositor-protocol integrations must degrade gracefully, with user-visible diagnostics where appropriate.
- **Shared UI:** the UI module is not a panel process or service. External DKTerm may consume the shared UI library through an explicit dependency without importing DKDE applications or requiring a DKDE runtime. DKTermCore and DKConsole remain independent repositories.
- **Packaging:** one bundle can ship all DKDE applications, but packaging may split executable and data packages without splitting the source repository. A per-app install must not silently install unrelated utilities.

## 28. Console and graphical session integration (adopted)

DKDE runs on labwc, with seatd/libseat used by the compositor on the FenrirOS reference platform. DKDE does not own DKConsole's login, DRM/KMS, VT or recovery implementation. DKConsole is an external console project using DKTermCore. A graphical session launched from a DKConsole PTY is an integration test and not an assumed capability. Do not create a DKDE session launcher merely to satisfy an untested assumption. A failed desktop session must leave the independently configured console and rescue getty available.

## 29. Requirements and source traceability

`DKDE-REQUIREMENTS.md` defines testable acceptance criteria; this specification defines architecture and design. `DKDE-LEGACY-REQUIREMENTS.md` is a historical feature inventory, not an automatic v1 feature commitment. Application-by-application migration must preserve provenance, assign milestone and status, and avoid silently dropping any legacy feature. `ai/AGENTS.md` governs engineering conventions.
