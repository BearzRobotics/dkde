#!/usr/bin/env python3
"""Builds icons/dkde-ui from a checkout of microsoft/fluentui-system-icons.

    scripts/vendor-fluentui-icons.py <checkout> [icons/dkde-ui]

Each freedesktop symbolic name dkde uses is mapped to a Microsoft asset. The SVGs
are recoloured to `currentColor`-style symbolic icons (fill #bebebe, the colour
GTK recolours) and written for 16/20/24 px, Regular; names ending in `-active`
use Filled. Re-run it after adding names to MAP.
"""
import os, re, shutil, sys

MAP = {
 "airplane-mode": "Airplane", "alarm": "Alert", "applications-graphics": "Paint Brush",
 "audio-volume-high": "Speaker 2", "audio-volume-medium": "Speaker 1", "audio-volume-low": "Speaker 0",
 "audio-volume-muted": "Speaker Mute", "avatar-default": "Person", "battery-level-0": "Battery 0",
 "battery-level-100": "Battery 10", "battery-level-80-charging": "Battery Charge", "battery": "Battery 5",
 "bluetooth": "Bluetooth", "computer": "Desktop", "dialog-password": "Key", "display-brightness": "Brightness High",
 "document-edit": "Edit", "document-open": "Folder Open", "document-properties": "Document Settings",
 "document-save": "Save", "drive-harddisk": "Hard Drive", "edit-copy": "Copy", "edit-cut": "Cut",
 "edit-delete": "Delete", "edit-paste": "Clipboard Paste", "edit-redo": "Arrow Redo", "edit-undo": "Arrow Undo",
 "edit-find": "Search", "folder-documents": "Document Folder", "folder-download": "Arrow Download",
 "folder-music": "Folder Open", "folder-new": "Folder Add", "folder-pictures": "Folder Open",
 "folder": "Folder", "folder-videos": "Folder Open", "go-down": "Arrow Down", "go-next": "Arrow Right",
 "go-previous": "Arrow Left", "go-up": "Arrow Up", "help-about": "Info", "input-keyboard": "Keyboard",
 "input-mouse": "Cursor", "list-add": "Add", "list-remove": "Subtract", "media-playback-start": "Play",
 "media-playback-pause": "Pause", "network-offline": "WiFi Off", "network-wired": "Plug Connected",
 "network-wireless": "WiFi 1", "preferences-desktop-keyboard-shortcuts": "Keyboard",
 "preferences-desktop-locale": "Globe", "preferences-other": "Options", "preferences-system": "Settings",
 "preferences-system-time": "Clock", "printer": "Print", "starred": "Star", "start-here": "Window",
 "system-shutdown": "Power", "tab-new": "Tab Add", "user-desktop": "Desktop", "user-home": "Home",
 "user-trash": "Delete", "utilities-terminal": "Window Console", "video-display": "Desktop",
 "view-app-grid": "Grid Dots", "view-grid": "Grid", "view-list": "Text Bullet List", "view-reveal": "Eye",
 "view-refresh": "Arrow Clockwise", "window-close": "Dismiss", "window-new": "Window New",
 "window-minimize": "Subtract", "window-maximize": "Maximize", "window-restore": "Square Multiple",
 "open-menu": "Navigation", "emblem-ok": "Checkmark", "process-stop": "Stop",
 "dialog-warning": "Warning", "dialog-error": "Error Circle", "dialog-information": "Info",
 "pan-down": "Chevron Down", "pan-up": "Chevron Up", "pan-start": "Chevron Left", "pan-end": "Chevron Right",
 "object-select": "Checkmark", "document-new": "Document Add", "zoom-in": "Zoom In", "zoom-out": "Zoom Out",
}
SIZES = (16, 20, 24)

def src_svg(root, asset, size, style):
    d = os.path.join(root, "assets", asset, "SVG")
    stem = "ic_fluent_" + re.sub(r"[^a-z0-9]+", "_", asset.lower()).strip("_")
    for s in (size, 24, 20, 16):
        p = os.path.join(d, f"{stem}_{s}_{style}.svg")
        if os.path.exists(p):
            return p, s
    return None, None

def main():
    root = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "icons/dkde-ui"
    shutil.rmtree(out, ignore_errors=True)
    missing, done = [], 0
    for name, asset in sorted(MAP.items()):
        for size in SIZES:
            p, real = src_svg(root, asset, size, "regular")
            if not p:
                missing.append(f"{name} ({asset})"); break
            svg = open(p).read()
            # GTK recolours a symbolic icon by the fill on each drawing element, not
            # one inherited from <svg>, so every shape carries fill="#bebebe".
            head, rest = svg.split(">", 1)
            head = re.sub(r'\s+fill="[^"]*"', "", head)
            def paint(m):
                tag = re.sub(r'\s+fill="[^"]*"', "", m.group(0))
                return tag[:-2].rstrip() + ' fill="#bebebe"/>' if tag.endswith("/>") else tag[:-1] + ' fill="#bebebe">'
            rest = re.sub(r'<(?:path|circle|rect|ellipse|polygon|polyline)\b[^>]*>', paint, rest)
            svg = head + ">" + rest
            d = f"{out}/{size}x{size}/actions"
            os.makedirs(d, exist_ok=True)
            open(f"{d}/{name}-symbolic.svg", "w").write(svg)
            done += 1
    dirs = [f"{s}x{s}/actions" for s in SIZES]
    with open(f"{out}/index.theme", "w") as f:
        f.write("[Icon Theme]\nName=dkde-ui\nComment=Microsoft Fluent UI System Icons for dkde's own controls\n"
                "Inherits=Fluent,Adwaita,hicolor\nDirectories=" + ",".join(dirs) + "\n")
        for s in SIZES:
            f.write(f"\n[{s}x{s}/actions]\nSize={s}\nContext=Actions\nType=Fixed\n")
    shutil.copy(os.path.join(root, "LICENSE"), f"{out}/LICENSE")
    print(f"{done} files; missing: {missing or 'none'}")

main()
