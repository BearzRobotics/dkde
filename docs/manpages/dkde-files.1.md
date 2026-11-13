# NAME
dkde-files - file manager

# SYNOPSIS
dkde-files [-h | --help] [-V | --version]

dkde-files [DIRECTORY]

# DESCRIPTION
dkde-files is the DKDE file manager. It browses local directories, copies, moves, renames and deletes files, uses the trash, shows properties and mounts removable media. **F4** shows a terminal panel below the folder view (the same terminal as dkde-term), started in the current folder; the View menu can send it a **cd** to the folder being shown. The program starts in DIRECTORY, or in the home directory without an operand. The path bar shows the folder as crumbs (click one to go there, click the empty part or press **Ctrl+L** to type a path; **⋮** holds the folder's actions). The button beside the search box switches between list and icons, and its menu sets the view and the sort order. While files are being copied or moved, a round progress button appears in the header; it opens the list of operations, with the time left and a cancel button for each. With gvfs installed, **File > Connect to Server** (or **Ctrl+L**) opens **sftp://**, **ftp://** and **smb://** locations (typing **ftp:**, **smb:**, **samba:** or **ssh:** is enough), asking for a password when the server wants one; connected servers appear under Network in the sidebar. Without gvfs only local folders are available. Anything that needs administrator rights is run through the configured elevation helper after a confirmation.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
# DIRECTORY
: The directory to open first.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# ARCHIVES
Archives (zip, tar and its gz, xz, bz2 and zst forms, 7z, rar, iso, cpio, deb, rpm) are read and written with libarchive; no other program is needed. Open an archive (double-click, **Open**, or type its path in the path bar) and it shows as a folder: the first crumb is the archive's name, **Up** at its top returns to the folder it is in. **Open in New Tab** and **Open in New Window** work on an archive too, and so does starting the program with an archive as the operand. **Extract Here** unpacks into a new folder next to the archive, named after it; **Extract To…** asks for the folder. **Compress to .zip, .tar.gz, .7z** (and .tar.xz, .tar.zst, which can be added to the menus) pack the selection into the folder being shown; folders and symbolic links are kept.

An archive is opened by unpacking a copy into ~/.cache/dkde/archives/ (once; opening it again reuses the copy, and copies older than three days are removed), so what is shown is read-only in spirit: changes in that view are not written back to the archive; extract to keep files. Opening a large archive takes as long as unpacking it. Unpacking refuses file names with .. or absolute names and symbolic links that leave the folder, and stops at 16 GB or a million entries. Password-protected archives are reported and not opened. The work runs in a separate process (**dkde-files --archive-extract ARCHIVE FOLDER** and **--archive-pack FORMAT ARCHIVE FOLDER NAME...**, which are for dkde-files itself), so a damaged archive cannot stop the window.

# PHONES AND CAMERAS
When gvfs has the MTP, gphoto2 or afc backend (Debian and Ubuntu: **gvfs-backends**, with **libmtp-common** or **mtp-tools** for the udev rules), the sidebar has a Phones and cameras section. It lists a plugged-in device even before it is mounted; click it to mount it and show its folders. An Android phone must be unlocked and set to File transfer (MTP) in its USB notification, or the mount fails with a message saying so. Right-click a mounted device in the sidebar to disconnect it. The section follows plugging and unplugging while the window is open. The files are read and written by gvfs, and programs that open a file by path need **gvfs-fuse** (the device is then under /run/user/UID/gvfs). Nothing is shown when the backend is not installed.

# FILES
~/.config/dkde/files.toml
: File manager settings.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-settings(1), dkde-edit(1), dkde-help(1)
