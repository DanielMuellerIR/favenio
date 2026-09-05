**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

# Favenio

**"facile invenio" — Latin for "I find with ease".**

Favenio is an index-free file search for macOS in the spirit of EasyFind: it
scans the file system directly (no index, no Spotlight) for file names or file
contents. What sets it apart: **Favenio also looks inside archives.** Supported
are the zip family (zip, jar, whl, epub, docx, xlsx, pptx, odt, ods, odp,
pages, numbers, key), the
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
  `"type": "member"` just like a file does. Metadata hits add `field` and
  `value`; with a size filter, hits add `width` and `height` (pixels). All
  four are optional. `modified` and `created` are the modification and
  creation time as Unix seconds (float): plain files and folders carry
  both (from the same `stat` call as `size`), ZIP and TAR entries only
  `modified` from the archive catalogue, `bsdtar` entries and single
  compressed files neither — so treat both as optional.
- **Exit codes** as with grep: `0` = hits, `1` = no hits,
  `2` = error (invalid regex, missing path, and any unexpected error that
  cut the run short — an aborted run must never look like an empty result)
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
| `-m`, `--metadata` | search the curated metadata text fields (keywords, title, description …) instead of names; needs `exiftool` |
| `--metadata-field TAG` | restrict `--metadata` to one field from the curated list (repeatable; implies `--metadata`) |
| `--list-metadata-fields` | print the curated field list, one per line, and exit |
| `--min-size BYTES`, `--max-size BYTES` | inclusive file-size bounds; whole nonnegative bytes, optionally B/KiB/MiB/GiB/TiB |
| `--modified-from ISO`, `--modified-to ISO` | inclusive modification-time bounds; ISO datetime with `Z` or explicit offset |
| `--created-from ISO`, `--created-to ISO` | inclusive creation-time bounds; ISO datetime with `Z` or explicit offset |
| `--min-width PX`, `--max-width PX` | only images at least / at most this wide (pixels) |
| `--min-height PX`, `--max-height PX` | only images at least / at most this tall (pixels); all four dimension filters are ANDed with the pattern, which may then be omitted |
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
| `--exclude GLOB` | exclude matching files and subtrees before opening or descending (repeatable; case-sensitive; see below) |
| `--json` | JSONL output for scripts/agents (with `size` in bytes where the format states it) |
| `--progress` | report where the search currently is (JSONL objects with `--json`, stderr otherwise) |
| `--extract HIT` | extract a hit path (`!/` notation) to a temp folder and print the usable path |
| `--extract-json JSON` | extract an unambiguous structured JSON hit |
| `--extract-root FOLDER` | temp root for extraction (used by the apps, which clean it up themselves) |
| `--version` | show version |

Exclusions use whole-name glob matching (`*`, `?`, `[abc]`), independently of
the search pattern and `--regex`, `--exact` or `--case-sensitive`. Quote them
in the shell. Without `/`, a pattern matches any whole path component:
`--exclude cache` skips every directory or file named `cache`, including its
contents, but keeps `mycache` and `Cache`. With `/`, it matches the complete
path relative to each start directory: `--exclude build/generated` skips that
subtree, but keeps `other/build/generated`. `*` can cross `/`, so
`--exclude 'build/*/cache'` also skips `build/a/b/cache`. `**` has no separate
meaning; there is no directory-only trailing-slash syntax.

Each archive, including a nested archive, starts a new relative root for
these patterns. Parent paths are checked even when the archive lists no
separate directory entry. `./` components in archive paths are ignored for
matching. The literal `!` in an entry name remains part of that name;
`--exclude 'odd!/skip.txt'` matches that relative entry path, not a transition
between archives. Each of several start paths is independent. An explicitly
selected start directory remains the search root even when its own name
matches; an explicitly selected file is checked by its basename. Use relative
patterns without a leading `/` or `./`.

For example, `./favenio.py --exclude cache --exclude '*.zip' invoice ~/Documents`
skips cache subtrees and never opens the excluded ZIP files, including for
raw-byte content search. Exclusions remove the matching objects from results
as well. There are no default exclusion patterns; the existing `--hidden`
setting continues to control dot files and directories separately.

`--no-archives` (and `--archive-depth 0`) means **do not look inside**, not
**skip**. The file then counts as an ordinary file, so with `-c` its raw bytes
are searched. That is exactly what happens to a `.7z` when `bsdtar` is absent —
the reason Favenio does not look inside must not change the result, otherwise
whether a file is examined at all would depend on which tools happen to be
installed. In practice a hit on the container itself only appears when the text
really is in its raw bytes, i.e. for uncompressed (stored) entries. The same
holds one level down: an archive inside an archive that the remaining
`--archive-depth` no longer opens counts as an ordinary entry as well.

The extension is only a hint. When a file cannot be opened as the format its
extension promises, its first bytes decide:

- They carry **no** archive signature — the extension was simply ambiguous
  (`.key` is far more often a TLS key than a Keynote document). The file is an
  ordinary file, with no message.
- They carry the signature — the file is a **damaged archive**, e.g. an
  interrupted download. It is skipped with a warning on stderr instead of
  being searched as raw bytes: otherwise a stored (uncompressed) entry inside
  it produced a perfectly ordinary file hit, and nobody learned that the
  archive was broken.

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

Directories can match a name search and known date facts; file-size,
dimension, metadata and content filters cannot match directories.

## File size and date filters

`--min-size` and `--max-size` compare file sizes in bytes. Bounds are inclusive;
`--min-size 0 --max-size 0` finds empty files with a known size. Values are whole
nonnegative numbers, optionally followed by `B`, `KiB`, `MiB`, `GiB` or `TiB`:
`'2 MiB'` means 2 × 1024² bytes. Units are case-sensitive; decimal values and
ambiguous `KB`/`MB` are rejected. Directories have no file size for these
filters; `--only dirs` together with a size bound therefore yields no hits.

`--modified-from`/`--modified-to` filter modification times, and
`--created-from`/`--created-to` filter creation times. All bounds are inclusive
instants, not whole calendar days. Use `YYYY-MM-DDTHH:MM[:SS[.ffffff]]` with
`Z` or an explicit `±HH:MM` offset, for example `2024-01-01T00:00:00Z` or
`2024-01-01T01:00+01:00`; these two values denote the same instant. Date-only
values and times without a zone are rejected. Up to six fractional-second
digits are supported. A lower bound above its upper bound is an error.

Requested facts must be known and valid. ZIP and TAR entries provide sizes
and modification times from their catalogs; they have no creation time.
Single-compressed entries and entries read through bsdtar have no size or
timestamps in the current catalog. They fail a requested fact filter, and
Favenio does not inflate them just to discover a size. Local creation time
depends on the filesystem exposing it. Date filters also apply to directories
with known timestamps. A container's size or timestamp never decides whether
its archive entries qualify: Favenio still descends into an allowed archive,
and checks each entry's own facts.

All enabled filters are ANDed with the search pattern and each other. The
pattern may be omitted when any size, date or pixel-dimension filter is set;
multiple start paths remain supported. `--content` and `--metadata` still
require a pattern. For example:

```sh
./favenio.py --min-size '2 MiB' --max-size '10 MiB' ~/Documents
./favenio.py --modified-from 2024-01-01T00:00:00Z '*.pdf' ~/Documents ~/Downloads
```

File facts are read once per object for filtering and result output. Files
rejected by these cheap checks never reach image-header, metadata or content
readers; archive traversal remains independent as described above.

## Metadata and image size search

`--metadata` runs the pattern against a **curated list of text fields**
(keywords, title, description, comment, artist, album …; `--list-metadata-fields`
prints it). "All metadata" is useless as a search space: in a real mix of
images, PDFs and audio the most frequent fields are ICC profile noise, and the
user-relevant text sits in about fifteen fields. The list is one constant in
`favenio.py`, meant to be changed. Reading is done by the optional
[`exiftool`](https://exiftool.org) (`brew install exiftool`) in **one** process
per search (`-stay_open`), which costs well under a millisecond per image and
about 60 ms per PDF. Only files with a media extension are handed to it. A
metadata hit reports the field and value: in text output as
`path:Keywords: Winter`, in JSON as `field` and `value`. Entries inside
archives and directories cannot satisfy a metadata search.

The four dimension filters `--min-width`, `--max-width`, `--min-height` and
`--max-height` always apply **in addition** (AND) to the pattern, whichever mode
it runs in — `--metadata Winter --min-width 1000` finds pictures tagged
"Winter" that are at least 1000 px wide. Width and height are read from the
file header (JPEG, PNG, GIF, BMP, WebP, TIFF; inside archives too) without any
dependency; only HEIC, AVIF, RAW and video fall back to `exiftool`. Files
without readable dimensions never match a dimension filter. With a dimension
filter the
pattern may be omitted (`favenio.py --min-width 3000 ~/Pictures`, and several
start paths work too); the search then runs without a text criterion, so
`--content` and `--metadata` — which say what the pattern runs against — need
one. JSON hits carry `width` and `height`. Cheap checks run first: name, then
file size and timestamps, then dimensions, metadata and content. For the
formats the built-in reader knows,
`exiftool` therefore only sees files that already passed the dimension filter. For
HEIC, AVIF, RAW and video it is asked earlier, because there the dimensions
themselves come from `exiftool` — there is no cheaper way to learn them.

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

The **Size**, **Modified** and **Created** rows each provide lower and upper
bounds. All bounds are inclusive. Size accepts whole bytes from 0, optionally
with B, KiB, MiB, GiB or TiB. Timestamps require ISO 8601 with `Z` or an
offset, such as `2026-09-05T12:00:00+02:00`; a date without a time/zone is
invalid. Empty fields mean no bound. These filters also work without search
text and are passed on by Quick Search. Invalid inputs receive a specific
error from the Python engine in the status line.

The **Exclude** field accepts one pattern per line, such as `node_modules`
or `Cache/*.zip`. Return starts a new line. Empty lines are ignored; spaces
remain part of the pattern. Quick Search passes all patterns to the main app.
Matching is case-sensitive independently of the search text; see the
`--exclude` rules above.

Both apps read search results in the background and receive bounded batches.
Stop and search changes cancel runs even while result delivery is backed up.
A JSONL record exceeding 1 MiB ends the run with a specific error message.



EasyFind-style interface: search field, folder picker, options, results list.
The **Name | Content | Metadata** switch says what the pattern runs against;
in metadata mode a field menu narrows it to one field. The **Image size** row
(width and height, each from/to) filters with AND and works on its own without
a pattern. In both apps, invalid pixel fields turn red and show a concrete
error in the status line and field tooltip. Search and transfer to the main
app stay blocked until corrected. Empty fields mean no limit; `1.000 px`
means 1000. Negative, decimal and overflowing numbers, and from > to, are
rejected. The columns, in order: **Name**, **Size** (bytes), **Path**,
**Type**, **Modified**, **Created**, **Location**, **Dimensions**. **Path**
is the folder of the hit relative to the search folder — the file name is
already in the first column — and is truncated at the start, so the
distinguishing end stays readable; an entry inside an archive shows
`archive.zip!/folder`. The two date columns pick their notation from their
own width: drag a column wider and `04.09.26` becomes `04.09.26, 14:03`,
`04.09.2026, 14:03` and finally `4. September 2026 um 14:03`. Columns may
add up to more than the window width (horizontal scroll bar); widths and
order are remembered. **Location** shows the line number of a content hit or
`Keywords: Winter` for a metadata hit, **Dimensions** the pixel size.

From the results list:

- **Double-click**: opens the file. Archive members are extracted once into an
  app-owned temporary folder and reused by preview, open, reveal and drag
- **Right-click**: Open / **Open With…** (all matching apps) /
  Show in Finder / Copy path
- **Drag & drop**: drag hits into Finder or other apps. This also works for
  files inside archives; the extracted copy is dragged
- **Space**: QuickLook preview. Keyboard focus stays in the result list, so
  Up/Down walks the preview through the hits

The footer counts hits, their total size and how many folders they are spread
across; from two selected rows on, also the size of the selection. A `≥` in
front of the total size means at least one file has no size known up front
(see `size` in the JSON contract).

### Refine, export and clean up the result list

These entries live in the **Ablage** (File) menu and in the result list's
context menu. The shortcuts that act on the selection (⌫, ⌘⌫, ⇧⌘E) only apply
while the result list has focus — in the search field, ⌫ still deletes a
character. ⌘E exports the whole list and works whenever the main window is
active; it never applies inside a dialog.

| Action | Shortcut | Effect |
| --- | --- | --- |
| Remove from result list | ⌫ | Drops rows from the **display** only. The files are left alone. This is how a large result list is narrowed down step by step to what was actually meant |
| Move to Trash | ⌘⌫ | After confirmation, moves the files to the Trash — like Finder, with the same sound, and recoverable from the Trash. Entries *inside* an archive are skipped and named: there is no file of their own behind them |
| Export all hits… | ⌘E | Writes the whole list to a file |
| Export selection… | ⇧⌘E | The same for the selected rows only |

Export uses the result snapshot selected when invoked and writes in the
background, keeping search responsive. The footer shows export and search
status together. Only one export can run at a time. The output file is
replaced atomically. Large exports are still assembled entirely in memory;
background processing does not reduce that memory requirement.

The save dialog offers four formats:

| Format | For |
| --- | --- |
| Paths, one line per hit (`.txt`) | What command line tools expect: `xargs`, `while read`, `grep -f` |
| Paths, NUL-separated (`.txt`) | The same list for `xargs -0`. On macOS a filename may contain any character except `/` and NUL — including a newline. Only this form carries **every** name intact |
| JSON Lines (`.jsonl`) | The same objects `favenio.py --json` writes (`path`, `type`, `isDirectory`, `filesystemPath`, `archiveMembers`, optional `size`/`line`/`modified`/`created`) — for `jq` and your own scripts |
| CSV (`.csv`) | For spreadsheets; with a UTF-8 BOM, otherwise Excel on macOS misreads non-ASCII names. Timestamps as ISO 8601 |

Both path formats carry the same path as “Copy path”: for a plain file its
POSIX path, for an archive entry the `!/` notation that `favenio.py --extract`
reads back (an entry name that itself contains `!/` is resolved against the
archive's member list). An archive entry has no POSIX path of its own;
dropping it silently would be worse than marking it.

```bash
# Grep all exported hits for "TODO" (BSD xargs on macOS has no -a; feed stdin)
xargs -0 grep -l TODO < Favenio-Treffer.txt
```

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
- **Name | Content | Metadata** picks what the one search term runs against;
  the `px` row (width and height, from/to) adds size filters and also works
  without a term
- The result columns are sortable and resizable; horizontal scrolling exposes
  long source paths
- Quick search shows up to 20 hits. **All in Favenio** (or **Cmd-Return**) hands
  them to the main app, which continues the same search without duplicates
- **Esc** closes an open preview; with an empty field it quits the quick search

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
