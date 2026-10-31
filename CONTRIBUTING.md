# Contributing to dkde

Thanks for looking. dkde is a small project with a written design, so the main
rule is: read [SPEC.md](SPEC.md) first, and change it in the same pull request
as the code when the code changes the design.

## The rules (SPEC.md section 10)

- **Spec first.** No new dependency, Wayland protocol or config key without
  updating `SPEC.md` in the same change. If the spec turns out to be wrong,
  fix the spec, then the code.
- **One topic per pull request.** Small and reviewable beats large.
- **Tests ship with the logic they test.** Parsing, config handling, labwc
  `rc.xml` editing and similar pure logic need unit tests.
- **Keep dependencies out.** dkde links GTK 4, GLib and little else. Optional
  features drive command-line tools (`nmcli`, `wlr-randr`, ...) and hide
  themselves when the tool is missing; please follow that pattern.
- **No init-system, libc or distribution assumptions.** It must work on musl
  and glibc, and under dinit, systemd and SysV init.

## Building and testing

```
zig build               # needs Zig 0.17.0, see the README for libraries (Debug build)
zig build --release=small   # what to install: far smaller and faster
zig build test          # unit tests
zig fmt src build.zig   # formatting is mandatory
```

The README's "Try it without logging out" section shows how to run the
desktop in a window under an existing Wayland session, which is the normal
development loop. `dkde-pointer` can move, click and scroll the pointer in
that nested session, for testing hover and click behaviour.

## Style

- `zig fmt`, and the official Zig naming style: `TitleCase` types,
  `camelCase` functions, `snake_case` variables and fields.
- Every allocation has an owner and a matching free; debug builds use the
  `DebugAllocator`, and leaks are bugs.
- Errors propagate as Zig error unions and are shown to the user only at the
  UI boundary.
- Strings shown to users go through `common.tr`.
- Match the code around you: comment density, naming, idiom.

## Logging and bug reports

Programs log through `common.log`. For a bug report, run the program with

```
DKDE_LOG=debug DKDE_LOG_FILE=auto dkde-<program>
```

and attach `~/.local/state/dkde/dkde-<program>.log`. Include your distribution,
libc, init system and labwc version. Screenshots help a lot.

## Licence

By contributing you agree that your work is released under the MIT License
(see [LICENSE](LICENSE)). Do not copy code from GPL or LGPL projects into the
tree; link such libraries dynamically instead.
