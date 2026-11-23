# DKDE Display Server and Window Management Specification

**Path:** `ai/COMPOSITOR-SPEC.md`
**Status:** Architecture draft
**Branch:** `compositor` (experimental)

## 1. Purpose

DKDE will provide its own display-server and window-management infrastructure for both Wayland and X11.

The project will contain:

- A native Wayland compositor written in Zig.
- A native X11 window manager written in Zig.
- An optional X11 compositor, separate from basic window management.
- A shared desktop integration interface used by DKDE applications.
- Backend-specific implementations using the appropriate protocols, standards, and extensions.

Desktop effects (Compiz-style: overview, switchers, animations, wobbly windows, blur, cube, accessibility zoom
and colour filters) are optional, off by default, and switched one by one in Settings. They are written in pure
Zig, with no dependency on scenefx or another compositor library. They are **Wayland only**: the compositor owns
the final picture there. On X11, `dkde-wm` is only a window manager and nothing composites, so the visual
effects need a custom X11 compositing manager (XComposite redirection, damage tracking and our own GL pass,
which is the optional X11 compositor above). That is a separate piece of work. The effects code is written
independent of the backend so that it can sit under that compositor later. The behaviour that needs no
rendering (window rules, placement, put, sticky, always-on-top, shade, snapping) belongs to the window manager
core and is meant to work on both.

The existing GTK4 desktop shell and applications will remain independent of the compositor implementation.

The goal is to provide a consistent DKDE experience across Wayland, Xorg, and XLibre without requiring applications to implement display-server-specific behavior themselves.

## 2. Core architectural principles

1. DKDE owns its compositor and window manager.
2. labwc is a temporary development reference or fallback, not a permanent runtime dependency.
3. Wayland and X11 implementations must provide equivalent desktop functionality wherever the underlying display server permits it.
4. Shared application interfaces must not expose Wayland or X11 implementation details.
5. Low-level infrastructure should be reused where appropriate rather than unnecessarily reimplemented.
6. Vulkan must never be mandatory.
7. Software rendering must remain available.
8. The implementation must not require systemd or logind.
9. Both musl and glibc environments must be supported.
10. Desktop configuration must use TOML for DKDE-owned settings.

## 3. Architecture

```text
                     DKDE Desktop
                          |
             Shared Desktop Integration API
                          |
                 Display Backend API
                    /           \
               Wayland           X11
                  |                |
          DKDE Compositor    DKDE Window Manager
                  |                |
          Wayland Protocols   X11 / EWMH / ICCCM
                  |                |
          Wayland Clients     X11 Clients
```

GTK4 applications remain separate executables and communicate with the appropriate display backend through the shared integration interface.

### 3.1 Shared desktop integration API

The shared API must provide consistent access to:

- Window enumeration.
- Window activation and focus.
- Window minimization and restoration.
- Window closing requests.
- Window movement and resizing where supported.
- Window state information.
- Workspace enumeration and switching.
- Window-to-workspace assignment.
- Output enumeration and configuration.
- Desktop background and panel integration.
- Screenshot capture.
- Capability discovery.

The API must not expose Wayland protocol objects, X11 atoms, XIDs, or backend-specific structures as its public interface.

Backend-specific handles may exist internally.

### 3.2 Capability discovery

Not every display server or implementation supports every feature identically.

The API must expose capabilities so applications can determine what is available.

Examples:

- Workspace management.
- Window enumeration.
- Window activation.
- Window minimization.
- Per-output configuration.
- Screenshot capture.
- Per-window capture.
- Desktop surface integration.
- Compositing effects.

Applications must degrade gracefully when a capability is unavailable.

## 4. Wayland compositor

The Wayland compositor will be implemented in Zig and will own:

- Client and surface lifecycle.
- Window management.
- Focus and input routing.
- Window placement and stacking.
- Workspace management.
- Output management.
- Compositing.
- Rendering and buffer presentation.
- Protocol implementation.
- Session integration.

### 4.1 Protocol support

The compositor should implement the protocols necessary for a functional desktop environment.

Initial required integrations:

| Protocol | Purpose |
|---|---|
| `xdg-shell` | Standard desktop application windows |
| `wlr-layer-shell` | Panels, launchers, desktop surfaces |
| `wlr-foreign-toplevel-management` | Taskbar window tracking and management |
| `ext-workspace-v1` | Workspace integration |
| `wlr-screencopy` | Screenshot capture (X11: root-window capture; scrolling capture uses `wlr-virtual-pointer`, or XTEST on X11) |
| `ext-idle-notify-v1` | Idle detection |
| Virtual keyboard protocol | Software keyboard integration where appropriate |

Additional protocols should be evaluated as needed for clipboard integration, screen locking, output configuration, input methods, and other desktop functionality.

Protocol support must be version-aware and must not assume that every client or compositor supports every optional protocol.

### 4.2 Rendering

The rendering subsystem must support an abstraction that permits:

- Hardware-accelerated rendering.
- Software rendering.
- Multiple graphics backends where practical.
- Rendering on older hardware.

Vulkan may be supported, but it must not be a mandatory dependency.

The exact renderer and buffer-management implementation will be selected after dependency and hardware compatibility testing.

### 4.3 Backends

The compositor should support:

- Nested Wayland operation for development.
- Headless operation for automated testing.
- Direct DRM/KMS operation for normal desktop deployment.

The implementation should reuse established infrastructure for device management, input, rendering, and protocol handling where appropriate.

### 4.4 Xwayland

Xwayland support should allow legacy X11 applications to run inside the Wayland session.

Xwayland integration must not make X11 window-management implementation a dependency of the native Wayland compositor.

## 5. X11 window manager

DKDE will provide its own native X11 window manager.

It must support both Xorg and XLibre.

The window manager will own:

- Window placement.
- Focus management.
- Window stacking.
- Window decorations or decoration policy.
- Workspace management.
- Window state management.
- Keyboard shortcuts.
- Output-aware window behavior.
- EWMH and ICCCM integration.

The basic window manager must function without an X11 compositor.

### 5.1 X11 standards and extensions

The implementation should use XCB and appropriate X11 extensions.

| Standard or extension | Purpose |
|---|---|
| ICCCM | Core window-manager/client conventions |
| EWMH | Desktop, window, and workspace integration |
| XRandR | Output enumeration and configuration |
| XInput2 | Extended input handling |
| XComposite | Optional compositing and off-screen window capture |
| XDamage | Tracking changes to drawable contents |
| XFixes | Cursor and region-related functionality |
| MIT-SHM | Efficient shared-memory image transfers where available |

The implementation must detect extension availability and avoid assuming that optional extensions exist.

### 5.2 EWMH support

The window manager must expose the relevant EWMH properties and messages for desktop integration.

Initial requirements include:

- `_NET_SUPPORTED`
- `_NET_SUPPORTING_WM_CHECK`
- `_NET_CLIENT_LIST`
- `_NET_CLIENT_LIST_STACKING`
- `_NET_ACTIVE_WINDOW`
- `_NET_WM_NAME`
- `_NET_WM_STATE`
- `_NET_WM_WINDOW_TYPE`
- `_NET_NUMBER_OF_DESKTOPS`
- `_NET_CURRENT_DESKTOP`
- `_NET_DESKTOP_NAMES`
- `_NET_WM_DESKTOP`
- `_NET_WORKAREA`
- `_NET_WM_STRUT`
- `_NET_WM_STRUT_PARTIAL`

The implementation must correctly handle client requests and publish updated properties when window or workspace state changes.

### 5.3 X11 compositing

Compositing must be independent of basic window management.

The window manager must remain usable when compositing is disabled or unavailable.

A separate DKDE compositing component may use XComposite, XDamage, and related extensions to provide:

- Transparency.
- Shadows.
- Animations.
- Other optional visual effects.

Compositing must not be required for panels, launchers, taskbars, or ordinary window management.

## 6. Shared desktop application integration

This section is a core requirement.

DKDE applications must use the shared desktop integration API instead of directly depending on Wayland protocols or X11-specific interfaces.

Each backend must implement equivalent functionality using its native mechanisms.

### 6.1 Panels, launchers, and desktop surfaces

**Wayland implementation:**

- Use `wlr-layer-shell`.
- Support appropriate layer selection, anchoring, exclusive zones, and keyboard interaction.

**X11 implementation:**

- Use EWMH window types and properties.
- Use `_NET_WM_WINDOW_TYPE_DOCK` for panels.
- Use `_NET_WM_WINDOW_TYPE_DESKTOP` for desktop surfaces.
- Use `_NET_WM_STRUT` and `_NET_WM_STRUT_PARTIAL` for panel-reserved screen space.
- Use appropriate managed or override-redirect windows depending on the surface's purpose.

The X11 window manager must recognize and correctly position DKDE desktop surfaces.

The shared API must allow the shell to request panel placement, screen-edge anchoring, and work-area reservation without knowing which backend is active.

### 6.2 Taskbar window tracking

**Wayland implementation:**

- Use `wlr-foreign-toplevel-management`.

**X11 implementation:**

- Use EWMH window properties.
- Enumerate windows through `_NET_CLIENT_LIST`.
- Track stacking through `_NET_CLIENT_LIST_STACKING`.
- Determine the active window through `_NET_ACTIVE_WINDOW`.
- Read window state through `_NET_WM_STATE`.
- Determine workspace assignment through `_NET_WM_DESKTOP`.

The taskbar must support:

- Listing eligible application windows.
- Activating windows.
- Minimizing and restoring windows where supported.
- Closing windows through the appropriate client request.
- Displaying window titles and state.
- Associating windows with workspaces.

The shared taskbar implementation must not directly access Wayland or X11 window identifiers.

### 6.3 Workspace integration

**Wayland implementation:**

- Use `ext-workspace-v1` when supported.

**X11 implementation:**

- Use EWMH workspace properties and messages.
- Read `_NET_NUMBER_OF_DESKTOPS`.
- Read and update `_NET_CURRENT_DESKTOP`.
- Read `_NET_DESKTOP_NAMES`.
- Read and update `_NET_WM_DESKTOP`.

The workspace switcher must provide consistent behavior on both backends.

If a backend lacks workspace support, the application must disable or hide unsupported workspace controls rather than failing.

### 6.4 Screenshot functionality

**Wayland implementation:**

- Use `wlr-screencopy` for supported output capture.
- Respect compositor restrictions and supported capture capabilities.

**X11 implementation:**

- Use XCB or Xlib image capture facilities.
- Support root-window capture.
- Use MIT-SHM when available for more efficient transfers.
- Use XComposite when per-window or off-screen capture is required and supported.

The shared screenshot API must support output capture and expose per-window capture as a separate capability.

The implementation must account for multiple outputs, image formats, and capture failures.

### 6.5 Output management

**Wayland implementation:**

- Use the compositor's output-management implementation and supported protocols.

**X11 implementation:**

- Use XRandR where available.

The shared API must provide output enumeration, dimensions, refresh information where available, and configuration capabilities.

Applications must not assume that output identifiers are interchangeable between backends.

## 7. GTK4 integration

GTK4 remains the toolkit for the desktop shell and applications.

The shell must remain independent of the compositor implementation.

Wayland-specific integrations should be isolated from X11-specific integrations.

The desktop shell must support:

- Panel and launcher surfaces.
- Taskbar integration.
- Workspace switching.
- Desktop background integration.
- Screenshot functionality.
- Output-aware behavior.

The same shell applications should operate on both Wayland and X11 without maintaining separate application implementations.

Backend-specific behavior belongs in the shared integration layer.

## 8. Configuration

DKDE-owned configuration must use TOML.

Configuration should cover:

- Window placement policy.
- Focus behavior.
- Workspaces.
- Keyboard shortcuts.
- Output preferences.
- Panel behavior.
- Compositor behavior.
- Optional visual effects.

Backend-specific configuration should be isolated from shared desktop preferences where possible.

The absence of an optional configuration file must not prevent the desktop from starting.

## 9. Dependencies

The project should reuse established libraries for low-level infrastructure where appropriate.

Potential areas include:

- Wayland protocol server infrastructure.
- XCB and X11 extension bindings.
- DRM/KMS.
- libinput.
- xkbcommon.
- libseat.
- Rendering and buffer management.
- Xwayland integration.

Every dependency must be evaluated for:

- Zig compatibility.
- Maintenance status.
- Licensing.
- Portability.
- Resource usage.
- Build complexity.
- Availability on target distributions.

No particular compositor library or Zig binding is considered mandatory until a working prototype validates compatibility with the project's pinned Zig version.

## 10. Session and portability requirements

The desktop must not require systemd or logind.

It must support appropriate session and device-management arrangements, including libseat/seatd where applicable.

The project must remain compatible with:

- musl-based Linux distributions.
- glibc-based Linux distributions.
- Xorg.
- XLibre.
- Wayland.

X11 support must not depend on Xorg-specific behavior when an equivalent XLibre-compatible mechanism exists.

## 11. Development and testing

Development must proceed incrementally.

### Milestone 0: Dependency validation

- Validate the selected Zig Wayland infrastructure.
- Build a minimal nested Wayland compositor.
- Launch a GTK4 application inside it.
- Verify focus, movement, resizing, and closing.
- Validate the X11/XCB development dependencies separately.

### Milestone 1: Shared desktop integration API

- Define backend-neutral window, workspace, output, and capture interfaces.
- Implement capability discovery.
- Add tests for backend-independent behavior.

### Milestone 2: Wayland compositor

- Implement client lifecycle and surface management.
- Add xdg-shell support.
- Implement focus and window placement.
- Add workspace and output management.
- Integrate layer-shell and foreign-toplevel-management.
- Add screenshot support.

### Milestone 3: X11 window manager

- Implement core window management.
- Add ICCCM support.
- Implement EWMH properties and messages.
- Add workspace management.
- Add output handling.
- Integrate with the shared desktop API.

### Milestone 4: GTK4 shell integration

- Implement Wayland backend integration.
- Implement X11 backend integration.
- Verify panels, launchers, taskbar, workspace switcher, and screenshots on both backends.
- Test capability handling and graceful degradation.

### Milestone 5: Optional X11 compositor and polish

- Implement optional X11 compositing.
- Add visual effects where practical.
- Improve rendering and performance.
- Complete compatibility testing.

## 12. Acceptance criteria

The architecture is not considered complete until:

1. DKDE can start a Wayland session without labwc.
2. DKDE can start an X11 session under both Xorg and XLibre.
3. The GTK4 shell operates on both display-server backends.
4. Panels and launchers work on both backends.
5. Taskbar window tracking works on both backends.
6. Workspace integration works on both backends.
7. Screenshot capture works on both backends.
8. Missing optional capabilities are handled gracefully.
9. Basic X11 window management works without compositing.
10. Software rendering remains available.
11. The desktop does not require systemd or logind.
12. Existing DKDE applications do not need separate Wayland and X11 implementations.

## 13. Open architectural decisions

The following decisions remain open and must be resolved through prototyping:

- Exact Wayland compositor infrastructure and Zig bindings.
- Exact rendering and buffer-management implementation.
- Floating, tiling, or configurable window-management policy.
- Whether the X11 compositor is a separate executable or an optional component of the window manager.
- Exact public API and internal representation for desktop integration.
- Exact protocol versions and optional extensions supported.

These decisions must not be treated as settled merely because an implementation prototype uses one particular approach.

## 14. Decisions taken

- **Window-management policy (2026-11-15): configurable.** Floating is the default; tiling is a first-class alternative, not an afterthought. The policy is a setting (`[windows] layout = "floating" | "tiling"`, per workspace where practical), shared by the Wayland compositor and the X11 window manager, so the layout logic lives in one backend-neutral module that both call. Tiling must coexist with floating windows (dialogs, panels and any window the user marks as floating stay floating), and switching a workspace between the two must not lose windows or their floating geometry.
- Survey of the build environment and the Zig bindings: see `ai/COMPOSITOR-SURVEY.md`.
