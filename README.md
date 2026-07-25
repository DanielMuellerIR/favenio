**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

# Favenio

**"facile invenio" — Latin for "I find with ease".**

Favenio is an index-free file search for macOS in the spirit of EasyFind: it
scans the file system directly (no index, no Spotlight) for file names or file
contents. What sets it apart: **Favenio also looks inside archives.** Supported
are the zip family (zip, jar, whl, epub, docx, xlsx, pptx, odt, ods, odp) and
the tar family (tar, tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz) — optionally even
archives nested inside archives.

The search core is pure Python 3 (standard library only), a single file, no
installation. Two native macOS apps are built on top of it: a full search
window and a small quick-search panel for the Finder toolbar.

## Requirements

- **CLI (`favenio.py`)**: Python 3.9 or newer, no third-party packages.
- **Apps (`Favenio.app`, `FavenioQuick.app`)**: macOS 12 (Monterey) or newer,
  Apple Silicon. The apps run the search core with the system
  `/usr/bin/python3` from Apple's Command Line Tools; macOS offers to install
  those automatically if they are missing.

## Installation

Download `Favenio-<version>.dmg` from the
[Releases page](../../releases/latest), open it and drag both apps into
`Applications`.

The DMG is signed with a Developer ID and notarized by Apple, so Gatekeeper
opens the apps without extra steps.

Starting with version 0.14.0, both apps check for signed updates automatically
and install them only after confirmation. The main app also provides
**Favenio → Nach Updates suchen …** (“Check for Updates”). No hardware or
system profile is sent with update checks. Versions before 0.14.0 have no
updater, so 0.14.0 must be installed once from the DMG.

Building from source instead — three separate scripts, none of which does the
others' job:

```bash
./build-app.sh      # build and self-test both apps in the repository
./release.sh        # build the DMG, notarize and staple it (no install)
./install.sh        # install a verified DMG into /Applications
```

Source builds may be ad-hoc signed and are never installed automatically.
`install.sh` only accepts a DMG with a stapled notarization ticket that
Gatekeeper accepts, checks both bundles before and after copying, and exits
with code 2 without touching `/Applications` if anything fails.
`./install.sh --verify-only` runs the checks alone.

## Quick start (CLI)

```bash
# Search file names ("contains", case-insensitive)
./favenio.py invoice ~/Documents

# Glob pattern (matches the whole name)
./favenio.py "*.sketch" ~/Projects

# Exact file name — without -e, "release.sh" is a substring and also
# matches "test-github-release.sh"
./favenio.py -e release.sh ~/git

# Only two directory levels deep (like find -maxdepth): which projects
# have a release script?
./favenio.py -e --max-depth 2 release.sh ~/git

# Search file contents, including inside archives
./favenio.py -c "notice period" ~/Documents

# Regular expression, case-sensitive
./favenio.py -r -s "invoice-\d{4}" .

# Search archives inside archives (depth 2)
./favenio.py -c secret ~/Backups --archive-depth 2

# Ignore archives
./favenio.py note . --no-archives
```

Hits inside archives are marked with `!/`:

```
backup.tar.gz!/save/old.txt:1
outer.zip!/inner.zip!/deep/hidden.txt
```

For content search, `:N` appends the line number of the first match.

## Use by scripts and AI agents (headless)

Favenio is deliberately machine-friendly:

- **`--json`**: one hit per line as a JSON object (JSONL), e.g.
  `{"path": "...", "type": "member", "filesystemPath": "/tmp/a.zip", "archiveMembers": ["inside.txt"], "line": 2}`.
  `path` remains the human-readable representation; automation should use the
  unambiguous structured fields.
- **Exit codes** as with grep: `0` = hits, `1` = no hits,
  `2` = error (invalid regex, missing path)
- **Warnings** (unreadable files, broken archives) go to stderr;
  the search continues and stdout stays cleanly parseable.

```bash
./favenio.py --json -c "TODO" src/ | jq -r .path | sort -u
```

## Options

| Option | Effect |
|---|---|
| `-c`, `--content` | search file contents instead of names |
| `-r`, `--regex` | interpret the pattern as a regular expression |
| `-s`, `--case-sensitive` | match case-sensitively |
| `--no-archives` | do not look inside archives |
| `--archive-depth N` | nesting depth (default 1) |
| `--max-archive-member-bytes BYTES` | maximum uncompressed bytes read per archive member |
| `--max-archive-total-bytes BYTES` | maximum uncompressed archive bytes read per search |
| `--max-archive-ratio FACTOR` | maximum ZIP compression ratio |
| `--only both\|files\|dirs` | limit hits to files, directories or both (default) |
| `--hidden` | include hidden (dot) files and directories |
| `--json` | JSONL output for scripts/agents (includes `size` in bytes) |
| `--progress` | report where the search currently is (JSONL objects with `--json`, stderr otherwise) |
| `--extract HIT` | extract a hit path (`!/` notation) to a temp folder and print the usable path |
| `--extract-json JSON` | extract an unambiguous structured JSON hit |
| `--version` | show version |

## Search modes — and how to find only `.md` files

Favenio detects the search mode **automatically from the pattern** — there is
no switch:

| Input | Mode | Finds |
|---|---|---|
| `note` | "contains" (default) | anything with the text **anywhere** in the name |
| `*.md` | glob/wildcards (`* ? [`) | **only** names ending exactly in `.md` |
| `invoice-\d{4}` with `-r` | regex | any pattern (`re.search`) |

This is why the input `.md` also finds `.mdi`, `.mdx` or `readme.md` — `.md`
does occur *somewhere* in those names. **To find only real `.md` files, search
for `*.md`.** The `*` switches to glob matching, which checks the **whole**
name. (If a *directory* ends in `.md`, additionally use `--only files` or
"Files only" in the GUI.) The regex `\.md$` is exactly equivalent.

In name search, directory names count as hits too.

## GUI (Favenio.app)

EasyFind-style interface: search field, folder picker, options, results list.

From the results list:

- **Double-click**: opens the file. Archive members are extracted once into an
  app-owned temporary folder and reused by preview, open, reveal and drag
- **Right-click**: Open / **Open With…** (all matching apps) /
  Show in Finder / Copy path
- **Drag & drop**: drag hits into Finder or other apps. This also works for
  files inside archives; the extracted copy is dragged

The GUI is only a frontend: searching always happens through `favenio.py`.

## Quick search (FavenioQuick.app)

A Spotlight alternative for the Finder toolbar: drag `FavenioQuick.app` into
the header of a Finder window while holding **Cmd**.

- One click on the icon opens a small floating search field (no Dock icon)
- **Return** starts the name search (including archives) in the search scope
  shown next to the field — by default the folder of the frontmost Finder
  window
- With hits, the main app opens with the finished list (hits are handed
  over, nothing is searched twice); without hits, only the small field with
  a message remains
- **Esc** (with an empty field) quits the quick search

The search scope is never guessed silently. While the Finder is being asked,
the menu says so and a search waits briefly instead of starting somewhere else.
If the folder cannot be determined — automation denied, no Finder window open,
Finder not responding — the reason is shown, and the folder actually being
searched is named.

Note: On the first search across your home folder, macOS may ask for access
to Desktop and Documents (TCC). Allowing it once is enough. Asking the Finder
for the current folder needs a separate permission (Settings → Privacy &
Security → Automation).

To see what the apps detect, without any window:

```bash
FavenioQuick.app/Contents/MacOS/FavenioQuick --finder-scope
```

One JSON line with the detected folders (frontmost first). Exit code 0 =
folders found, 1 = no Finder window, 2 = error (including denied access).

## Tests

```bash
python3 -m unittest discover -s tests            # unit tests (core)
/usr/bin/python3 -m unittest discover -s tests   # app runtime interpreter
Favenio.app/Contents/MacOS/Favenio --selftest    # headless GUI wiring
```

`build-app.sh` runs both app self-tests automatically after every build and
leaves the resulting bundles in the repository. See [CHANGELOG.md](CHANGELOG.md)
for release changes.

## License

[MIT](LICENSE). The macOS apps include Sparkle under its own compatible license;
see [third-party software](THIRD-PARTY.md).
