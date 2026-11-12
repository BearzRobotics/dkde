# NAME
dkde-tasks - task manager

# SYNOPSIS
dkde-tasks [-h | --help] [-V | --version]

dkde-tasks [--page PAGE] [--resource NAME]

# DESCRIPTION
dkde-tasks is the task manager, laid out like the Windows 11 one: a rail of pages on the left (☰ shows or hides their names), Settings at the bottom. Everything it shows is read from /proc and /sys, or asked of the service manager; nothing is estimated.

Only one Task Manager runs at a time: starting it again (Ctrl+Shift+Esc) brings the open one forward, on the page asked for.

## Processes
What runs, grouped as in Windows: **Apps** (programs with a menu entry, each one row; the arrow opens its helper processes), **Background processes** (yours) and **System processes** (other users' and the kernel's). The column titles carry the totals: the whole machine's CPU and memory use, the disk throughput and the busiest GPU. View chooses the grouping: by type, as a tree of which process started which, or one flat list; and which columns show (right-clicking a column title does the same). The search in the title bar finds a process by name, command line, app, user, service or PID.

CPU is the share of the whole machine, so all processes add up to the total. Memory is the process's own (private) memory: anonymous and shared-memory pages, not the libraries it shares with others. GPU is the busiest engine's share, from the kernel's per-client figures (fdinfo); its memory is what the process holds on the GPU.

## Performance
CPU (with the average speed of all logical processors, the temperature, and one graph per logical processor), memory, each disk, network adapter and GPU. A GPU's utilization comes from the driver (amdgpu), from the programs using it (i915, xe, nouveau, panfrost and others), or from **nvidia-smi**; a driver that reports none of these shows a dash rather than a made-up line. Where the CPU tells no base speed (AMD), the highest speed is shown and named so. Double-clicking a graph shows the graphs alone; double-click again for the rest.

## Startup apps
What starts when you sign in: the freedesktop autostart entries (~/.config/autostart, /etc/xdg/autostart), which dkde-panel starts at the beginning of the session whatever the init system; your user services (systemd --user, or a dinit user instance); and the lines of the labwc autostart script (shown only: edit the script to change them). **Add** starts an app, or any command, at sign-in; **Remove** deletes one you added. Disabling a system entry writes a copy into ~/.config/autostart with Hidden=true, so the system's file is never changed. The last start-up times come from systemd-analyze where there is one.

## Users
Who is signed in (loginctl) and what each user's processes use together. **Sign out** ends the user's session; signing out another user needs the administrator password.

## Details
Every process in one list, with any of the columns: PID, status, user, CPU, memory, disk, GPU, GPU memory, threads, priority, CPU time, start time, swap, disk read and written, service, elevated, command line.

## Services
The system's services and your own, from systemd (systemctl) or dinit (dinitctl): state, how each starts, and the process running it. **Enable** makes one start at start-up, **Disable** not (it can still be started by hand); systemd services can also be masked, so nothing can start them. **Logs** shows what the service wrote: journalctl for systemd, the log buffer (dinitctl catlog) or the service's logfile for dinit. Changing a system service needs the administrator password; with dinit, so does reading the state of system services (**Show states…**).

## What can be done to a process
From the row's menu (right-click): End task (an app ends with its helpers), End process tree, Force quit, Suspend and Resume, Efficiency mode (the lowest CPU priority and idle disk priority), Set priority, Set disk priority, Set processors, Open file location, Go to details, Go to service, Properties (general facts, open files, environment, memory maps, limits) and Copy. Lowering your own programs' priority is always allowed; raising it, or changing another user's program, asks for the administrator password. **Run new task** opens a program, folder or file, optionally as administrator.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--page PAGE
: Show this page: **processes**, **performance**, **startup**, **users**, **details** or **services**. **--tab** is an older name for it.

--resource NAME
: Show this resource on the Performance page. NAME is **cpu**, **memory**, or a device name such as **sda**, **eth0** or **card0**.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# KEYS
F5
: Update the figures now.

Delete
: End the selected task.

Ctrl+F
: Search processes.

Ctrl+1 … Ctrl+7
: Show a page, in the rail's order (7 is Settings).

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# ENVIRONMENT
DKDE_TASKS_NEW
: Start a separate Task Manager even when one is open.

# FILES
~/.config/dkde/tasks.toml
: Settings: **update-speed** (high, normal, low or paused), **start-page**, **rail-collapsed**, and the remembered window size. The Settings page writes them.

~/.local/state/dkde/tasks.state
: The columns shown on Processes and Details, their widths, the sort order and the grouping.

~/.config/autostart/
: Your startup apps, and your copies of system entries that you turned off.

~/.config/dkde/panel.toml
: **[session] startup-apps** = false stops dkde-panel starting the startup apps.

$XDG_RUNTIME_DIR/dkde-tasks.sock
: How a second start reaches the open Task Manager.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

# SEE ALSO
dkde-panel(1), dkde-help(1), systemctl(1), journalctl(1), dinitctl(8)
