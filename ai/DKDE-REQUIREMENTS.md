# DKDE — Requirements

**Status:** Consolidated requirements 1.0 (2026-11-04). These are intended outcomes, not assertions of current implementation.

**Normative language:** MUST = acceptance gate for the applicable milestone; SHOULD = strongly preferred and may be deferred with written rationale; PLANNED = future scope, not a v1 gate. `DKDE-SPEC.md` defines architecture; `DKDE-LEGACY-REQUIREMENTS.md` preserves the detailed historical feature inventory. Requirements must be mapped to tests and implementation issues before release.

## 1. Product and portability

- **DKDE-001 (MUST):** Provide a cohesive Wayland desktop shell and core utility suite with a Windows 7-inspired taskbar and Open-Shell-style Start menu, without copying proprietary assets.
- **DKDE-002 (MUST):** Run under the reference labwc session on FenrirOS without requiring systemd or logind; support a documented glibc Linux target.
- **DKDE-003 (MUST):** Use shared application appearance and conventions through the DKDE UI module, stylesheet and TOML configuration where DKDE owns the format.
- **DKDE-004 (MUST):** Integrate with freedesktop desktop entries, icons, MIME associations and XDG user/config/state/cache directories where applicable.

## 2. Build independence — mandatory

- **DKDE-010 (MUST):** Each bundled application has its own executable and a root build selector to build, test and install it independently.
- **DKDE-011 (MUST):** Selecting one utility does not compile or link unrelated DKDE application executables. Shared libraries and assets may be built as dependencies.
- **DKDE-012 (MUST):** Per-app installation stages only that app and its required assets/registrations; full-suite installation remains available.
- **DKDE-013 (MUST):** The root build is authoritative; separate nested `build.zig` files are optional and are not required for independence.
- **DKDE-014 (MUST):** Build and install isolation is verified from clean caches and clean staging prefixes for at least two dissimilar utilities and eventually every shipped app.
- **DKDE-015 (MUST):** DKConsole and DKTermCore are never imported as DKDE application source trees; DKTerm remains a separate project integrated by explicit dependency/package mechanisms.

## 3. Runtime independence — mandatory

- **DKDE-020 (MUST):** Every utility launches and performs its core function with `dkde-panel` stopped and other DKDE app processes absent.
- **DKDE-021 (MUST):** Killing or restarting the panel does not terminate or corrupt running utilities.
- **DKDE-022 (MUST):** Optional session D-Bus, notification services, tray services and unsupported compositor protocols do not cause unrelated applications to crash; unavailable functionality is explained or disabled.
- **DKDE-023 (MUST):** Shared UI functionality is linked/loaded as a library, not accessed through a mandatory panel process.
- **DKDE-024 (MUST):** Each executable supports `--help` and `--version`, reports startup errors, and has documented desktop integration where appropriate.

## 4. Desktop shell

- **DKDE-030 (MUST):** Panel provides Start button, taskbar/window list, clock and per-output layout with usable keyboard and pointer operation.
- **DKDE-031 (MUST):** Start menu provides installed applications, launch actions, pinned entries and search as defined by its milestone.
- **DKDE-032 (MUST):** Shell components survive compositor-protocol or D-Bus feature unavailability without a crash; degrade according to documented behavior.
- **DKDE-033 (SHOULD):** Panel supports taskbar grouping, tray, auto-hide, widgets and configurable placement according to prioritized legacy requirements.

## 5. Core applications and smoke tests

- **DKDE-040 (MUST):** File manager opens directories and safely copies, moves, renames and deletes test files, with clear error reporting.
- **DKDE-041 (MUST):** Settings UI reads, validates and saves DKDE-owned configuration without requiring the panel.
- **DKDE-042 (MUST):** Text editor opens, edits, saves and reopens UTF-8 files without data loss.
- **DKDE-043 (MUST):** Hex editor opens binary fixtures, navigates offsets and saves modifications or a safe copy with byte-level verification.
- **DKDE-044 (MUST):** Image viewer opens supported fixtures and provides zoom and navigation.
- **DKDE-045 (MUST):** PDF viewer opens and renders a test PDF; editing features are milestone-specific and must not be claimed before implemented.
- **DKDE-046 (MUST):** Partition manager inspects a disposable disk image without root and defaults to non-destructive behavior.
- **DKDE-047 (MUST):** Calculator evaluates documented deterministic expressions.
- **DKDE-048 (MUST):** Clock and calendar provide their milestone-defined local functionality without depending on a notification daemon.
- **DKDE-049 (MUST):** Screenshot utility uses a supported Wayland capture mechanism and reports a useful error when capture is unsupported or denied.
- **DKDE-050 (MUST):** Help viewer opens bundled local documentation without network access.
- **DKDE-051 (PLANNED):** Additional historical utilities (task manager, character map, color tools, PDF checker, setup/greeter and optional policy integration) remain in the feature inventory until individually triaged.

## 6. Configuration, security and data integrity

- **DKDE-060 (MUST):** DKDE-owned persistent settings use TOML in XDG configuration paths; application state and caches use their corresponding XDG paths.
- **DKDE-061 (MUST):** Malformed configuration is diagnosed and does not silently overwrite user settings; writes are atomic and concurrency conflicts are handled.
- **DKDE-062 (MUST):** Migration from any supported legacy INI files is documented, backed up and tested. Standard external formats are not replaced by TOML.
- **DKDE-063 (MUST):** File and disk operations avoid shell interpolation, require confirmation for destructive actions and provide testable recovery/error behavior.
- **DKDE-064 (MUST):** Privileged operations use explicit narrowly scoped authorization, never assume a password dialog alone grants authority.
- **DKDE-066 (MUST):** Use the system Polkit authority for authorization of privileged desktop operations; DKDE must not implement password checking, shadow access, PAM authentication, or its own authorization authority.
- **DKDE-067 (MUST):** Provide or integrate a graphical Polkit authentication agent; handle absent agent, denied authentication, canceled prompts and unavailable system bus without unintended elevation.
- **DKDE-068 (MUST):** Each privileged service/helper independently authorizes the requesting subject for a narrowly defined action and validates its inputs; UI-side authorization or a password prompt alone is insufficient.
- **DKDE-069 (MUST):** Ship explicit action policies and test least-privilege defaults, authorization denial, cancellation, subject identity, auditability and destructive-action confirmation.
- **DKDE-076 (MUST):** Verify the selected Polkit authority, session/subject tracking and authentication backend on the reference musl/dinit/seatd system without systemd/logind. Until validated, document privileged features as unavailable rather than replacing Polkit with custom elevation.
- **DKDE-077 (MUST):** Panel and ordinary unprivileged applications remain usable when Polkit or the system bus is unavailable; privileged operations fail closed with clear diagnostics.
- **DKDE-065 (SHOULD):** UI library eventually exposes a tested, documented C interface; this is not a stable ABI until ownership, versioning and threading are defined.

## 7. Integration, test gates and documentation

- **DKDE-070 (MUST):** Test each utility with the panel stopped, other app executables absent from PATH, and optional session bus unavailable where meaningful.
- **DKDE-071 (MUST):** Test clean build/install selection, application crash isolation, config errors, permission denial and representative file fixtures.
- **DKDE-072 (MUST):** Test the reference musl/dinit/labwc/seatd environment and at least one supported glibc environment; record versions and limitations.
- **DKDE-073 (MUST):** DKDE does not implement DKConsole login, VT, DRM/KMS or fallback functionality. Graphical launch from a DKConsole PTY remains an integration experiment, not a guaranteed feature.
- **DKDE-074 (SHOULD):** Measure panel idle CPU/RSS, application startup and interactive responsiveness; set numeric thresholds only after repeatable baseline measurements.
- **DKDE-075 (MUST):** Each inherited legacy feature is classified required/planned/deferred/rejected with an owner, milestone and reason before claiming the feature migration complete.

## 8. Release staging

The requirements above are acceptance gates **for each application's declared delivery milestone**, not a promise that every listed utility is finished in the first shell release. Publish a release manifest naming shipped applications, their maturity, tests and unsupported operations. No implementation status is inferred from these documents.
