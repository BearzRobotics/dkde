# NAME
dkde-view - image viewer

# SYNOPSIS
dkde-view [-h | --help] [-V | --version]

dkde-view [FILE | FOLDER | URI]...

# DESCRIPTION
dkde-view shows pictures and moves through the others in the same folder. Pictures are decoded in Zig (PNG, JPEG, GIF, BMP, TGA, QOI, TIFF, PCX, netpbm); gdk-pixbuf reads the rest (WebP, SVG, ICO, HEIF, AVIF, JPEG XL), as far as the installed loaders go. Pictures are read in the background, and the next and previous ones are read ahead, so moving through a folder is immediate. Animated GIF and WebP pictures play, and SVG drawings stay sharp at every zoom.

**Zoom.** A picture opens fitted to the window; small pictures are not enlarged unless **Enlarge Small Pictures** is on. **+** and **-** (or **Ctrl+wheel**, or a pinch on a touchpad) zoom around the pointer; **0** fits the picture, **W** fits its width and **1** shows it at its actual size. A double click goes between fitting and 100%. A zoomed picture moves with the mouse, the arrow keys, the wheel or two fingers. From 200% on, pixels show as sharp squares.

**Moving through pictures.** **Right**, **Page Down** and **Space** show the next picture, **Left**, **Page Up** and **BackSpace** the previous one (with a zoomed picture the arrow keys move it; **Alt+arrows** still change picture); **Home** and **End** the first and last. The wheel also changes picture when the whole picture shows, and so do a mouse's back and forward buttons. The **Go** menu sorts by name (numbers in names in numeric order: img2 before img10), date or size, reversed, and with or without going round from the last picture to the first. The folder is watched: new, removed and renamed pictures appear and go at once, and a picture changed by another program is read again.

**Gallery and Properties.** **Ctrl+F9** shows a strip of thumbnails; they are shared with other programs through the desktop's thumbnail cache. **F9** (or **Alt+Return**) shows the file's details and, for photos, the camera, lens, exposure, aperture, ISO, focal length, flash, date taken and the place, with a link to see it on a map.

**Full screen and slideshow.** **F11** shows only the picture, on black; the pointer hides when still. **F5** starts a slideshow (**Space** pauses it, **Esc** ends it).

**Editing.** **Ctrl+R** and **Ctrl+Shift+R** (or **R** and **Shift+R**) turn the picture; the **Edit** menu also flips it, crops it (**Shift+C**, then drag over the part to keep and press **Enter**) and resizes it. **Ctrl+Z** and **Ctrl+Shift+Z** undo and redo. **Ctrl+S** saves in place, **Ctrl+Shift+S** as a new file (the type follows the name's extension). A JPEG that was only turned is saved by changing its orientation tag, so the picture is not compressed again; a JPEG that has to be written again keeps its camera data. Leaving a picture with unsaved changes asks first.

**Files.** **Ctrl+C** copies the picture, **Ctrl+Shift+C** its location. **F2** renames it. **Delete** moves it to the Trash, with an **Undo** button for a few seconds; **Shift+Delete** deletes it for good after asking. The **File** menu prints the picture, opens it with another program, shows it in its folder and sets it as the wallpaper. A right click shows the most used of these. Pictures dropped on the window open; **Open Recent** lists the pictures opened lately in any program.

Given several files, the viewer moves through just those; given a folder, through its pictures.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
# FILE
: A picture to show; the others in its folder follow. Several files: just those. A folder: its pictures. URIs (sftp://, smb:// ...) work when GVfs can reach them.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/view.toml
: The viewer's settings (defaults in $XDG_DATA_DIRS/dkde/view.toml): how pictures fit, enlarging small ones, the backdrop behind transparent pictures, the order, going round, which panes show, the slideshow's speed, the JPEG quality for re-saved pictures, the zoom from which pixels are sharp, and the window's size.

~/.cache/thumbnails/normal
: The thumbnail cache shared with file managers and other viewers.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-files(1), dkde-snip(1), dkde-help(1)
