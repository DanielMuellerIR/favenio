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

Building from source instead:

```bash
./build-app.sh    # builds, tests and installs both apps to /Applications
```

## Quick start (CLI)

```bash
# Search file names ("contains", case-insensitive)
./favenio.py invoice ~/Documents

# Glob pattern (matches the whole name)
./favenio.py "*.sketch" ~/Projects

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
  `{"path": "...", "type": "file|dir|member", "line": 2}`
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
| `--only both\|files\|dirs` | limit hits to files, directories or both (default) |
| `--hidden` | include hidden (dot) files and directories |
| `-j`, `--jobs [N]` | search file contents in N threads (default 1 = serial; bare `--jobs` or `--jobs 0` uses the CPU core count) |
| `--json` | JSONL output for scripts/agents (includes `size` in bytes) |
| `--progress` | report where the search currently is (JSONL objects with `--json`, stderr otherwise) |
| `--extract HIT` | extract a hit path (`!/` notation) to a temp folder and print the usable path |
| `--version` | show version |

### When `--jobs` helps

Parallel content search is off by default, and that default is deliberate.
The threads only pay off when reading actually has to wait — a cold cache, an
external or network volume, a spinning disk. Then several reads overlap and
the search gets markedly faster.

When the files are already in the page cache, the work is pure CPU inside the
Python interpreter, which runs one thread at a time. `--jobs` is then a net
loss, and the more small files are involved, the bigger that loss gets.
So treat it as a knob for slow storage, and measure your own case before
leaving it on.

Archives stay serial regardless: their entries share one open archive
object. With `--jobs` the set of hits and the exit code are unchanged — only
their **order** may differ, so sort if you need a stable sequence.

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

- **Double-click**: opens the file. Archive members are extracted to a temp
  folder first (`--extract`)
- **Right-click**: Open / **Open With…** (all matching apps) /
  Show in Finder / Copy path
- **Drag & drop**: drag hits into Finder or other apps. This also works for
  files inside archives; the extracted copy is dragged

The GUI is only a frontend: searching always happens through `favenio.py`.

## Quick search (FavenioQuick.app)

A Spotlight alternative for the Finder toolbar: drag `FavenioQuick.app` into
the header of a Finder window while holding **Cmd**.

- One click on the icon opens a small floating search field (no Dock icon)
- **Return** starts the name search in your home folder (including archives)
- With hits, the main app opens with the finished list (hits are handed
  over, nothing is searched twice); without hits, only the small field with
  a message remains
- **Esc** (with an empty field) quits the quick search

Note: On the first search across your home folder, macOS may ask for access
to Desktop and Documents (TCC). Allowing it once is enough.

## Tests

```bash
python3 -m unittest discover -s tests            # unit tests (core)
Favenio.app/Contents/MacOS/Favenio --selftest    # headless GUI wiring
```

`build-app.sh` runs the self-test automatically after every build.

## License

[MIT](LICENSE). The macOS apps include Sparkle under its own compatible license;
see [third-party software](THIRD-PARTY.md).
