**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

# Favenio

**"facile invenio" — Latin for "I find with ease".**

Favenio is an index-free file search for macOS in the spirit of EasyFind: it
scans the file system directly (no index, no Spotlight) for file names or file
contents. What sets it apart: **Favenio also looks inside archives.** Supported
are the zip family (zip, jar, whl, epub, docx, xlsx, pptx, odt, ods, odp), the
tar family (tar, tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz) and singly compressed
files (gz, bz2, xz — e.g. `notes.txt.gz` contains `notes.txt`) — optionally
even archives nested inside archives.

Two optional integrations extend the list: with the system's `bsdtar`
(included in macOS) Favenio also reads **7z** and **ISO** images, and if a
`zstd` program is installed (e.g. via Homebrew, auto-detected) additionally
**zst** and **tar.zst**. Without these tools the files are simply treated as
regular files, exactly as before.

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

Building from source instead — three scripts, each self-contained:

```bash
./build-app.sh      # build and self-test both apps in the repository
./install.sh        # build, notarize, install into /Applications
./release.sh        # build, notarize, build and notarize the DMG (no install)
```

Source builds may be ad-hoc signed and are never installed automatically.
Whatever lands in `/Applications` carries a stapled notarization ticket:
`install.sh` notarizes the bundles itself, verifies them before and after
copying (`codesign`, `spctl`, `stapler validate`), and exits with code 2 without
touching `/Applications` if anything fails. A valid signature alone is not
enough: the bundle identifiers and matching versions are checked as well, so a
foreign notarized app cannot take Favenio's place under the same file name.
Both apps are swapped as a single transaction — if any step fails, both
previous bundles are restored. `./install.sh --dmg <path>` installs from a
finished DMG instead; `./install.sh --verify-only` runs the checks alone. Both
bundles inside a DMG need their own stapled ticket as well, so they start
offline; very old DMGs that carry the ticket only on the image are rejected.
Both scripts also check that the bundles point at the production update feed:
`build-app.sh` accepts a different `SPARKLE_FEED_URL` for local end-to-end
tests, but an app installed or shipped with a foreign feed is refused.

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
  `{"path": "...", "type": "member", "isDirectory": false, "filesystemPath": "/tmp/a.zip", "archiveMembers": ["inside.txt"], "line": 2}`.
  `path` remains the human-readable representation; automation should use the
  unambiguous structured fields. Every hit carries `path`, `type`,
  `isDirectory`, `filesystemPath` and `archiveMembers`; content hits also
  `line`. Files carry `size` (uncompressed bytes) **as far as the format
  states it up front**: plain files, ZIP and TAR entries do, single compressed
  files (`.gz`, `.bz2`, `.xz`) and entries read through `bsdtar` (7z, ISO,
  `.tar.zst`) do not — their size is only known after full decompression, and
  the search stops at the first hit. It is also absent when the size of a plain
  file cannot be determined (for example, a broken symlink). So treat `size`
  as optional. Ask
  `isDirectory`, not `type`: a **folder inside an archive** arrives as
  `"type": "member"` just like a file does.
- **Exit codes** as with grep: `0` = hits, `1` = no hits,
  `2` = error (invalid regex, missing path)
- **Warnings** (unreadable files, broken archives) go to stderr;
  the search continues and stdout stays cleanly parseable.

```bash
./favenio.py --json -c "TODO" src/ | jq -r .path | sort -u
```

If the search pattern begins with `-`, put `--` before it so it cannot be
mistaken for an option: `./favenio.py -- -draft ~/Documents`.

## Options

| Option | Effect |
|---|---|
| `-c`, `--content` | search file contents instead of names |
| `-r`, `--regex` | interpret the pattern as a regular expression |
| `-s`, `--case-sensitive` | match case-sensitively |
| `-e`, `--exact` | pattern must match the WHOLE name (with `-r`: fullmatch; with `-c` per line) |
| `--max-depth N` | search only N directory levels deep (1 = directly in the start path, like `find -maxdepth`) |
| `--no-archives` | do not look inside archives; they stay ordinary files (see below) |
| `--archive-depth N` | nesting depth (0 = like `--no-archives`, default 1) |
| `--max-archive-member-bytes BYTES` | maximum uncompressed bytes read per archive member |
| `--max-archive-total-bytes BYTES` | maximum uncompressed archive bytes read per search |
| `--max-archive-ratio FACTOR` | maximum ZIP compression ratio |
| `--only both\|files\|dirs` | limit hits to files, directories or both (default) |
| `--hidden` | include hidden (dot) files and directories |
| `--json` | JSONL output for scripts/agents (with `size` in bytes where the format states it) |
| `--progress` | report where the search currently is (JSONL objects with `--json`, stderr otherwise) |
| `--extract HIT` | extract a hit path (`!/` notation) to a temp folder and print the usable path |
| `--extract-json JSON` | extract an unambiguous structured JSON hit |
| `--extract-root FOLDER` | temp root for extraction (used by the apps, which clean it up themselves) |
| `--version` | show version |

`--no-archives` (and `--archive-depth 0`) means **do not look inside**, not
**skip**. The file then counts as an ordinary file, so with `-c` its raw bytes
are searched. That is exactly what happens to a `.7z` when `bsdtar` is absent —
the reason Favenio does not look inside must not change the result, otherwise
whether a file is examined at all would depend on which tools happen to be
installed. In practice a hit on the container itself only appears when the text
really is in its raw bytes, i.e. for uncompressed (stored) entries. The same
holds one level down: an archive inside an archive that the remaining
`--archive-depth` no longer opens counts as an ordinary entry as well.

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

## How content search reads

With `-c`, Favenio reads in chunks and stops at the first hit. For a fixed
search text (no `-r`, no wildcards) it works in two steps: a cheap check
whether the text occurs at all, and only for a real hit a second pass that
determines the line number. That is roughly **1.4× to 1.9× faster** than
checking every line of every file, inside archives as well, and produces
exactly the same hits and line numbers.

Two consequences worth knowing:

- Content is read as UTF-8 with `errors="replace"`, so hits in partly binary
  files remain possible; other text encodings are not promised.
- Because reading stops at the first hit, the CRC checksum of a ZIP member is
  **not** verified — Python only checks it at the end of the member. A hit is a
  find, not a statement about archive integrity. Use an archive tool if you
  need that.

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

- One click on the icon opens a small regular app window (no Dock icon)
- **Return** starts the name search in the search scope shown next to the
  field — by default the folder of the frontmost Finder window. Archives are
  an optional switch and are **off** by default; tick **Archives** to search
  inside them
- The type switch limits hits to files and folders, files only, or folders only
- The result columns are sortable and resizable; horizontal scrolling exposes
  long source paths
- Quick search shows up to 20 hits. **All in Favenio** (or **Cmd-Return**) hands
  them to the main app, which continues the same search without duplicates
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
