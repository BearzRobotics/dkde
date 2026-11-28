# Roadmap proposal: account management through a library

**Status: to be discussed. Nothing here is decided or scheduled** (written 2026-11-28).

## Today

Settings reads `/etc/passwd` and `/etc/group` itself (`src/common/userdb.zig`) and changes
accounts with the system's own tools (`useradd`, `usermod`, `userdel`, `groupadd`,
`gpasswd`, `chpasswd`), run as administrator through `sudo` (`src/common/elevate.zig`,
`src/settings/users.zig`). dkde does not depend on util-unix or util-core for now. The
standard tools are the thing to keep improving in the meantime.

## The idea

Use the library behind util-unix to carry out Settings' account changes, so that the
command-line tools and the desktop share one implementation.

Settings runs as the signed-in user and must not run as root, so it would not call the
library itself. A small program that runs as root would:

```
Settings (the user) → asks for the password → dkde-accounts (root) → util-unix
```

It would accept only a short list of operations and check every value again.

What it could give:

- Adding a user as one operation that checks first and undoes partial work.
- Specific errors instead of another program's messages.
- No need for `useradd` and the rest, for a distribution that replaces them.

## Is it worth it?

Writing accounts is security-critical: a mistake can leave nobody able to log in. For a
distribution that replaces the standard account tools, the code has to exist somewhere, and a
shared library is a good place. For better dkde settings alone, the standard tools already
handle most of what follows.

Whether Settings could drop the standard tools on other distributions is a separate question.
They could stay the default there until the library has had real use.

## What the library would have to handle

util-unix 0.4.0 had functions to read users and groups, and none seen to change them. Later
versions were not looked at for this.

- **Files:** `passwd`, `shadow`, `group`, `gshadow`, and `subuid`/`subgid` where used.
- **Safe writes:** the same locks as other account tools, replacing each file in one step,
  keeping permissions and security labels, and recovering when stopped between files.
- **Passwords:** hashed with the system's `libxcrypt`, not our own code, following the PAM
  password policy.
- **System rules:** `login.defs` (id ranges, home folder permissions).
- **Home folders:** copying and deleting them as root without following links elsewhere.
- **Network accounts:** reading the local files does not find LDAP and other remote users.

## Possible order of work

1. Write the library functions, tested only on copies of the account files in a temporary
   folder.
2. Test interrupted writes and bad input, then try it in a VM.
3. Add `dkde-accounts`.
4. Switch Settings to it.

## Questions to settle

- Does dkde's own distribution replace the standard account tools?
- Which util-unix release would be the base, and what does it offer by then?
- Does Settings keep the standard tools as a fallback, and for how long?
