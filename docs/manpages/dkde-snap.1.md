% DKDE-SNAP(1)
% dkde
% 2026

# NAME
dkde-snap - snap layouts: choose where the active window goes

# SYNOPSIS
**dkde-snap**

# DESCRIPTION
Shows the usual window arrangements over the screen (halves, two-thirds and a third, thirds, quarters, a half beside two quarters, top and bottom) and puts the active window in the zone you click. It is bound to **Super+Z**; pressing that again, **Esc**, or clicking outside the card closes it.

labwc has no way for a program to move another program's window, so each zone is a region written into **rc.xml** (a **\<regions\>** block, added by dkde-setup and by Settings > Keyboard shortcuts > take over), and clicking a zone presses that region's own shortcut (**Super+Ctrl+Alt+Shift+A**, **B**, …, listed in Settings > Keyboard shortcuts) through **dkde-pointer**'s virtual keyboard. If you rebind a region's shortcut, dkde-snap follows it.

Dragging a window to the top edge and hovering the maximize button do not show the layouts: labwc offers no way to do that.

# FILES
**~/.config/labwc/rc.xml** holds the regions and their shortcuts.

# SEE ALSO
dkde-pointer(1), dkde-settings(1)
