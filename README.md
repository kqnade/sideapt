# sideapt

Non-root APT-based application manager for Debian/Ubuntu.

`sideapt` is a thin bash wrapper around `apt download` and `dpkg-deb -x` that
lets you install Debian/Ubuntu packages into your home directory
(`~/.sideapt/usr`) without `sudo`. Perfect for HPC clusters, shared servers,
restricted CI runners, and other environments where you can't get root.

## How it works

1. Maintains a private APT configuration under `~/.sideapt/apt/` so
   `apt-get update` works without writing to `/var/lib/apt/lists`.
2. Resolves dependencies via `apt-cache depends --recurse`, skipping anything
   already installed system-wide (so you only download what's actually missing).
3. Downloads `.deb` files with `apt-get download` and extracts them with
   `dpkg-deb -x` into `~/.sideapt/usr` — no root needed.
4. Regenerates `.so` symlinks via `ldconfig -n` (a non-root-safe replacement
   for the usual `postinst` step).
5. Sets `PATH`, `LD_LIBRARY_PATH`, `MANPATH`, `PKG_CONFIG_PATH`, etc.
   via `eval "$(sideapt env)"`.

## Limitations

`sideapt` is intentionally simple. It cannot do things that genuinely require
root:

- **Maintainer scripts** (`preinst`, `postinst`, `prerm`, `postrm`) are skipped
  entirely. Packages that depend on these for setup (services, users, kernel
  modules) won't work.
- **setuid binaries** lose their setuid bit when extracted as a non-root user.
- **System services** (systemd units, init.d scripts) won't be installed or
  registered.
- **update-alternatives** is ignored.
- Packages that hardcode paths like `/etc/...` may not find their config
  files. Workaround: symlink the relevant config from `~/.sideapt/etc/` into a
  location the binary expects (or set application-specific env vars).

Good fits: CLI tools, libraries, headers (`-dev` packages), data files.
Bad fits: anything that wants to be a daemon, mounter, or kernel hook.

## Install

```bash
git clone https://github.com/kqnade/sideapt
cd sideapt
make install               # → ~/.local/bin/sideapt
# Or override location:    make install PREFIX=$HOME/opt
```

Make sure `~/.local/bin` is on your `PATH`.

## Quickstart

```bash
sideapt init                        # one-time setup
sideapt update                      # fetch the private apt index

# Activate sideapt in your current shell
eval "$(sideapt env)"

# ...add the same line to ~/.bashrc to make it permanent:
#   command -v sideapt >/dev/null && eval "$(sideapt env)"

sideapt install jq tree
which jq                            # → ~/.sideapt/usr/bin/jq
echo '{"x":1}' | jq .
```

## Commands

| Command | Description |
| --- | --- |
| `sideapt init` | Initialize `~/.sideapt` and the private apt config |
| `sideapt update` | Refresh the private apt index (`apt-get update` equivalent) |
| `sideapt search <q>` | Search packages; marks `[installed]` for sideapt ones |
| `sideapt install <pkg>...` | Resolve deps, download, extract, regenerate symlinks |
| `sideapt remove <pkg>...` | Remove packages (refcount-aware: shared files survive) |
| `sideapt list` | List installed packages with version and install type |
| `sideapt info <pkg>...` | Show package details and the files it owns |
| `sideapt orphans [--remove]` | List or remove auto-installed packages no longer required |
| `sideapt upgrade` | Re-install all `requested` packages to pull current versions |
| `sideapt add-repo ppa:USER/NAME [suite]` | Add a Launchpad PPA (auto-fetches signing key) |
| `sideapt add-repo NAME 'deb [...] URL SUITE COMP...'` | Add an arbitrary apt repository |
| `sideapt add-key NAME <URL\|file>` | Import a signing key into `~/.sideapt/apt/etc/apt/keyrings/` |
| `sideapt list-repos` | List configured repositories |
| `sideapt remove-repo <name>...` | Remove a repo's `.list`/`.sources` and matching key |
| `sideapt env` | Print shell snippet for `eval "$(sideapt env)"` |
| `sideapt clean` | Remove cached `.deb` archives |
| `sideapt self-update` | Replace `sideapt` itself with the latest upstream version |
| `sideapt help` | Show usage |

## Adding repositories

`sideapt` writes repository files under `~/.sideapt/apt/etc/apt/sources.list.d/`
and stores signing keys (dearmored) under
`~/.sideapt/apt/etc/apt/keyrings/`. The generated source lines use
`signed-by=` so each key is trusted only for the repository that imported it.

```bash
# Launchpad PPA — fetches the signing key from Launchpad + keyserver.ubuntu.com,
# auto-detects the release codename (override by passing a suite argument).
sideapt add-repo ppa:neovim-ppa/unstable
sideapt update
sideapt install neovim

# Arbitrary repository — import the key first, then add the deb line.
# (If a key with the same NAME already exists, signed-by= is auto-attached.)
sideapt add-key docker https://download.docker.com/linux/ubuntu/gpg
sideapt add-repo docker 'deb https://download.docker.com/linux/ubuntu jammy stable'

# Inspect / remove
sideapt list-repos
sideapt remove-repo docker      # removes both .list and the matching key
```

`add-repo` (PPA form) and `add-key` require `curl` (or `wget`) and `gpg`.

## Directory layout

```
~/.sideapt/
├── usr/                              # package contents extract here
├── db/
│   ├── installed.tsv                 # name<TAB>version<TAB>date<TAB>kind
│   └── files/<pkg>.list              # per-package file lists for clean removal
├── var/cache/sideapt/archives/       # cached .debs (clear with `sideapt clean`)
└── apt/                              # private apt state (lists, conf, keys)
```

## Configuration

- Set `SIDEAPT_ROOT` to override the install location (default `~/.sideapt`).
- Set `PREFIX` when running `make install` to control where the wrapper itself
  is installed (default `~/.local`).

### Self-update

`sideapt` checks for upstream updates once per day (best-effort, time-limited)
and prints a one-line notice to stderr if a newer version of the script is
available. To upgrade, run:

```bash
sideapt self-update
```

The script atomically replaces itself with the version at
`https://raw.githubusercontent.com/kqnade/sideapt/main/bin/sideapt`. If the
script lives in a path you can't write to (e.g. installed system-wide), it
prints the downloaded path and the `sudo install` line to run instead.

Environment knobs:

- `SIDEAPT_SKIP_UPDATE_CHECK=1` — disable the daily background check.
- `SIDEAPT_SELF_UPDATE_URL=...` — override the upstream URL (e.g. a fork).
- `SIDEAPT_SELF_UPDATE_INTERVAL=86400` — seconds between background checks.
- `SIDEAPT_SELF_UPDATE_TIMEOUT=5` — `curl`/`wget` timeout, in seconds.

### Concurrency

Write operations (`install`, `remove`, `update`, `upgrade`, `clean`, `add-*`,
`remove-repo`, `self-update`, `orphans`) take an exclusive `flock(2)` advisory
lock on `~/.sideapt/db/.lock`. A second `sideapt` invocation will wait up to
`SIDEAPT_LOCK_WAIT` seconds (default `30`) before erroring out. Read-only
commands (`list`, `info`, `search`, `list-repos`, `env`, `help`) take no lock.

## Troubleshooting

**`E: Could not open lock file ...` on `sideapt update`** — your apt is too
old to honor `Dir::State::Lists` without writing system files. Workaround:
ask an admin to run `apt-get update` system-wide; `sideapt install` will
still work using the system index.

**`E: Unable to locate package <pkg>` on `sideapt install`** — run
`sideapt update` first, or check that `/etc/apt/sources.list` includes the
right components (`universe`, `multiverse` for Ubuntu).

**Binary installed but `command not found`** — `eval "$(sideapt env)"` was
not sourced in your current shell, or `~/.local/bin` isn't on `PATH`.

**Binary runs but `error while loading shared libraries`** — a dep is on
the system but its lib version differs. Try
`sideapt install <missing-lib>` directly.

## License

MIT — see [LICENSE](./LICENSE).
