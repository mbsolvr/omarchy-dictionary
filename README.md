# Omarchy Dictionary

A bilingual dictionary for the Omarchy bar. English words show English and
Chinese definitions; Chinese words show English translations. It also offers
IPA, pronunciation audio for available English entries, fuzzy English
suggestions, and a global hotkey for highlighted text.

English prefers the Free Dictionary API for modern definitions, IPA, and
pronunciation audio, then falls back to the bundled Webster's 1913 and ECDICT
dictionaries, followed by English Wiktionary. After an English entry succeeds,
its Chinese definitions come from bundled ECDICT data; Chinese Wiktionary is
queried only when ECDICT has no matching translation. This enrichment does not
block or replace the English entry or its pronunciation. Chinese headwords use
the bundled CC-CEDICT Chinese-English dictionary first. Words and phrases
missing from CC-CEDICT use MyMemory as an online translation fallback.

Click the bar icon to open a search field. Type an English or Chinese word and press
Enter to look it up. When no match exists, up to three similar words are
suggested as clickable chips.

![Dictionary preview](preview.png)

## Requirements

- Omarchy (uses the Quickshell bar plugin system)
- `wl-clipboard` for the global selection hotkey — preinstalled on Omarchy
- `ffmpeg` and PipeWire's `pw-play` for reliable pronunciation playback —
  both are included with Omarchy
- Network access is optional. It adds modern English definitions and audio via
  `api.dictionaryapi.dev`, a final English fallback via `en.wiktionary.org`,
  Chinese definitions for words absent from ECDICT via `zh.wiktionary.org`, and
  Chinese-English translation for words absent from CC-CEDICT via
  `api.mymemory.translated.net`.

## Offline support

English definitions ship with the plugin: 108,181 headwords from
Webster's New International Dictionary (1913), via the GCIDE XML dataset,
compressed into per-letter files under `data/webster/` (~6 MB total).
Lookups read the one relevant letter file with `gzip` — no new runtime
dependencies. English-Chinese translations ship as 256 ECDICT buckets under
`data/ecdict/` (~29 MB), covering 767,533 English headwords. Chinese-English
translations ship as 256 CC-CEDICT buckets under `data/cedict/` (~6 MB). Both
simplified and traditional Chinese headwords are indexed. ECDICT data carries
an MIT license notice in `data/ecdict/LICENSE-DATA.txt`; CC-CEDICT data is
licensed CC BY-SA 4.0, with attribution in `data/cedict/LICENSE-DATA.txt`.

Dictionary sources are adapters (`Model.js`: `ADAPTERS`). Each adapter
declares the languages it serves plus an `argsFor`/`parse` pair, and the
panel tries them in order until one succeeds. Adding a future source is a
new adapter object and one line in the registry.

To rebuild the data files from the upstream source:

```sh
scripts/build-webster.py   # downloads GCIDE XML, writes data/webster/*.json.gz
```

The raw XML is gitignored; only the generated files are committed.
Licensing: the 1913 Webster's core text is public domain, but GCIDE's
markup and additions are GPL — see `data/webster/LICENSE-DATA.txt`.

To rebuild the Chinese-English data from an official CC-CEDICT release:

```sh
curl -fsSL -o /tmp/cedict.txt.gz https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz
python3 scripts/build-cedict.py /tmp/cedict.txt.gz
```

To rebuild the English-Chinese data from ECDICT's CSV:

```sh
curl -fsSL -o /tmp/ecdict.csv https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv
python3 scripts/build-ecdict.py /tmp/ecdict.csv
```

## Install

```sh
omarchy plugin add https://github.com/tristonarmstrong/omarchy-dictionary.git --enable
```

Optionally place it in the center section after the clock:

```sh
omarchy bar move tristonarmstrong.dictionary --section center --after omarchy.clock
```

## Usage

### Bar search

- Click the bar icon to open the search panel
- Type an English or Chinese word and press Enter to look it up
- English results show Chinese definitions first, followed by English definitions
- Chinese results show English translations and pinyin when available
- When no match exists, up to three similar words appear as chips you can
  click to retry
- Press Esc to close the panel

### Global selection hotkey

Bind `SUPER + D` in `~/.config/hypr/bindings.lua` to look up the highlighted
word in any application:

```lua
o.bind("SUPER + D", "Look up selection in dictionary", "omarchy-dictionary-lookup")
```

The plugin bundles `scripts/omarchy-dictionary-lookup` but never installs
it on its own. Open the dictionary panel and use the
**Install hotkey script** section at the bottom (border-separated footer
with an Install button) to copy it to `~/.local/bin/` (idempotent —
re-runs only when the bundled copy changes). Once installed, the footer
dismisses itself — the plugin re-verifies the installed copy against the
bundled script at startup (via `cmp`) and keeps the footer hidden while
they match, so the prompt doesn't reappear after a shell restart. If the
bundled script ever changes, the footer returns to offer the update.
The script reads the
Wayland primary selection (highlighted text), falls back to the clipboard
if empty, extracts the first word, and opens the dictionary panel with that
word pre-filled. With nothing selected it just opens the empty panel.

Word extraction is script-agnostic — Chinese, Japanese, Korean, Greek,
Cyrillic, Arabic and accented Latin all work. Note that CJK and Thai have no
word delimiters, so a selection spanning several terms is sent as one string
and will miss; highlight the single term you want.

> **Note:** A desktop notification confirms when the script is installed.
> You may want to inspect it before use — review
> `scripts/omarchy-dictionary-lookup` in the plugin repo, or run
> `cat ~/.local/bin/omarchy-dictionary-lookup` to see what was installed.

### IPC

External callers can drive the plugin via `omarchy-shell`:

```sh
omarchy-shell tristonarmstrong.dictionary search <word>   # search and open
omarchy-shell tristonarmstrong.dictionary open           # open empty panel
omarchy-shell tristonarmstrong.dictionary toggle         # toggle panel
omarchy-shell tristonarmstrong.dictionary close          # close panel
```

## Validate

```sh
omarchy plugin validate ~/.config/omarchy/plugins/tristonarmstrong.dictionary
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/tristonarmstrong.dictionary/BarWidget.qml \
  ~/.config/omarchy/plugins/tristonarmstrong.dictionary/Panel.qml
```

## Tests

```sh
bash tests/run.sh
```

Runs four suites — QML lint checks, Model.js unit tests, lookup-script tests,
and install-stage tests. Model.js is parsed
in-process; the lookup script's pure functions are exercised in a
subprocess with stubbed `wl-paste` and `omarchy-shell` so the suite
needs no Wayland session or running shell.

## Remove

```sh
omarchy plugin remove tristonarmstrong.dictionary --yes
rm ~/.local/bin/omarchy-dictionary-lookup
```

`omarchy plugin remove` drops the plugin files; the lookup script at
`~/.local/bin/omarchy-dictionary-lookup` stays (the plugin doesn't know
when it's being removed). Remove it manually with the second command.

## License

Plugin code is MIT licensed. The bundled Webster data follows the terms in
`data/webster/LICENSE-DATA.txt`; ECDICT data retains the upstream MIT notice
in `data/ecdict/LICENSE-DATA.txt`; CC-CEDICT data is CC BY-SA 4.0 and follows
`data/cedict/LICENSE-DATA.txt`.
