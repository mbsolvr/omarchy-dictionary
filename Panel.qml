import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "wordlist.js" as Wordlist

// Dictionary search panel. The bar widget owns a magnify glyph that toggles
// this popup; everything user-facing lives here — the search field, the
// fetch lifecycle, and the rendered entry.
//
// Layout: a search field pinned to the top, a meaning stack beneath that
// grows from the entry's parts of speech. The entry is treated as a
// read-out rather than a picker, so there's no per-row cursor — arrows move
// the field caret instead, Enter fires search, Esc closes the panel.
Panel {
  id: root
  moduleName: "tristonarmstrong.dictionary"
  ipcTarget: "tristonarmstrong.dictionary"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Panel lifecycle. Stays in the bar's popout coordinator so adjacent
  //      panels can swap with TAB without leaving the bar that owns this
  //      slot. Setting opened = false (or close()) is the canonical way out.
  function open() {
    root.controller.show()
    root.refreshFocus()
  }

  function openFromHotkey() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) refreshFocus()
    })
  }

  function close() {
    if (root.status === "loading") {
      root.lookupGeneration++
      root.lookupCancelled = true
      root.lookupPending = false
      lookupProc.running = false
      root.status = "idle"
    }
    root.glossGeneration++
    root.glossCancelled = true
    root.glossPending = false
    if (chineseGlossProc.running) chineseGlossProc.running = false
    root.stopPronunciation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- Look up a word. Called both by Enter / clicking Search and from
  //      the IPC bridge so external tools can preload an entry before the
  //      panel is even opened.
  function search(word) {
    var q = String(word || "").trim()
    root.query = q
    if (searchField.text !== q) searchField.text = q
    // Make the panel visible. No-op if already open (controller.show() is
    // idempotent). Without this the hotkey path would silently populate
    // the search field on an invisible panel.
    root.open()
    if (q === "") {
      lookupProc.running = false
      root.resetResults()
      return
    }
    runLookup()
  }

  // ---- Search state. status drives which body section (hero + list) the
  //      panel shows; entry holds the parsed response on success.
  property string query: ""
  property var entry: null
  property string status: "idle"        // "idle" | "loading" | "ok" | "notfound" | "error" | "suggestions"
  property string statusMessage: ""
  property int variants: 0               // > 1 when the API returned more than one entry object

  // Detect the input script for each query. Chinese uses a Chinese-English
  // dictionary; English retains its pronunciation and bilingual definitions.
  property string language: "en"
  property var chineseMeanings: []
  property string chineseGlossQuery: ""
  property string chineseGlossStatus: "idle"
  property var glossAdapterQueue: []
  property int glossAdapterIndex: 0
  property bool glossInFlight: false
  property bool glossOutputReady: false
  property bool glossExited: false
  property bool glossPending: false
  property bool glossCancelled: false
  property int glossGeneration: 0
  property string glossOutput: ""
  property string pronunciationState: "idle"
  property string pronunciationQuery: ""
  property string preparedPronunciationQuery: ""
  property string pronunciationDownloadUrl: ""
  property string pronunciationFallbackUrl: ""

  // ---- Fuzzy state. Populated only when the user's exact query was a 404
  //      and the local wordlist surfaced closer candidates. suggestions is
  //      the chip list shown for the user to choose from; originalQuery is
  //      what the user typed before auto-match rewrote query to a better
  //      word (kept so we can render a "showing 'X' for 'Y'" hint).
  property var suggestions: []
  property string originalQuery: ""
  property bool isAutoMatched: false

  // Suppress the user-edit reset in applyEdited when the *plugin itself*
  // rewrites the search field (auto-match path: we set searchField.text to
  // the chosen candidate, and the resulting onTextChanged would otherwise
  // clobber isAutoMatched and originalQuery mid-fetch).
  property bool programmaticEdit: false

  // ---- Adapter chain. Model.adaptersFor(language) returns the ordered list
  //      of dictionary sources for the current language — English prefers
  //      Free Dictionary for modern definitions and audio, then falls back
  //      to bundled Webster and Wiktionary. The first ok result wins.
  property var adapterQueue: []
  property int adapterIndex: 0
  property bool lookupInFlight: false
  property bool lookupOutputReady: false
  property bool lookupExited: false
  property bool lookupPending: false
  property bool lookupCancelled: false
  property string lookupOutput: ""
  property int lookupExitCode: 0
  property int lookupGeneration: 0

  // True once the hotkey script is confirmed installed — "installed" after
  // a successful click-to-install this session, "up-to-date" when the
  // startup check found the installed copy identical. Drives the footer
  // visibility below so the prompt dismisses itself after install
  // (issue #9).
  readonly property bool hotkeyScriptInstalled: {
    if (!root.hostWidget) return false
    var s = root.hostWidget.installStatus
    return s === "installed" || s === "up-to-date"
  }

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string heroSummary: entry ? Model.summaryLabel(entry) : ""
  // Build tag shown in the popup's bottom-right corner so we can visually
  // confirm which build is loaded. This is distinct from manifest version.
  readonly property string buildVersion: "v0.2"
  readonly property int panelWidth: Style.space(420)
  readonly property int panelMaxHeight: Style.space(620)
  readonly property int searchDelayMs: 250
  readonly property string audioRuntimeDir: {
    var dir = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    return dir !== "" ? dir : "/tmp"
  }
  readonly property string audioSourcePath: audioRuntimeDir + "/omarchy-dictionary-pronunciation.source"
  readonly property string audioPaddedPath: audioRuntimeDir + "/omarchy-dictionary-pronunciation.wav"

  // Bundled offline dictionary data (data/webster). Same URL-to-path
  // treatment as BarWidget's scriptPath: Qt.resolvedUrl returns a
  // percent-encoded file:// URL, so strip the scheme and decode it back
  // into a real filesystem path for the lookup process.
  readonly property string dataDir: {
    var url = String(Qt.resolvedUrl("data/webster"))
    var raw = url.replace(/^file:\/\//, "/")
    try { return decodeURIComponent(raw) } catch (e) { return raw }
  }
  readonly property string cedictDir: {
    var url = String(Qt.resolvedUrl("data/cedict"))
    var raw = url.replace(/^file:\/\//, "/")
    try { return decodeURIComponent(raw) } catch (e) { return raw }
  }
  readonly property string ecdictDir: {
    var url = String(Qt.resolvedUrl("data/ecdict"))
    var raw = url.replace(/^file:\/\//, "/")
    try { return decodeURIComponent(raw) } catch (e) { return raw }
  }

  // ---- Reset all result-related state back to idle. Called from search(),
  //      runLookup(), applyEdited(), and the language-change handler.
  function resetResults() {
    root.glossGeneration++
    root.glossCancelled = true
    root.glossPending = false
    if (chineseGlossProc.running) chineseGlossProc.running = false
    root.stopPronunciation()
    root.entry = null
    root.chineseMeanings = []
    root.chineseGlossQuery = ""
    root.chineseGlossStatus = "idle"
    root.variants = 0
    root.status = "idle"
    root.statusMessage = ""
    root.suggestions = []
    root.originalQuery = ""
    root.isAutoMatched = false
  }

  // Inject the bundled wordlist into Model.js so fuzzyMatch() can use it,
  // and the bundled offline data dir so the local adapter can find it.
  Component.onCompleted: {
    if (typeof Model.setWordlist === "function" && typeof Wordlist.ENGLISH_WORDLIST !== "undefined")
      Model.setWordlist(Wordlist.ENGLISH_WORDLIST)
    if (typeof Model.setDataDir === "function")
      Model.setDataDir(root.dataDir)
    if (typeof Model.setCedictDir === "function")
      Model.setCedictDir(root.cedictDir)
    if (typeof Model.setEcdictDir === "function")
      Model.setEcdictDir(root.ecdictDir)
  }

  // ---- Bindings need the source data checked before any property
  //      access; pulling the wording into functions lets the body
  //      short-circuit cleanly when entry is null mid-fetch (the
  //      auto-match recovery path blanks entry briefly between lookups).
  function autoMatchedNote() {
    if (!root.entry || !root.originalQuery) return ""
    return "Showing \"" + root.entry.word + "\" (closest match for \"" + root.originalQuery + "\")."
  }
  function entryWord() {
    return root.entry ? String(root.entry.word || "") : ""
  }
  function entryPhonetic() {
    return root.entry ? String(root.entry.phonetic || "") : ""
  }
  function entryAudioUrl() {
    return root.entry ? String(root.entry.audioUrl || "") : ""
  }
  function entryAudioSourceUrl() {
    return root.entry ? String(root.entry.audioSourceUrl || "") : ""
  }
  function stopPronunciation() {
    if (audioResolver.running) audioResolver.running = false
    if (audioDownload.running) audioDownload.running = false
    if (audioPadding.running) audioPadding.running = false
    if (pronunciationPlayer.running) pronunciationPlayer.running = false
    root.pronunciationState = "idle"
    root.pronunciationQuery = ""
    root.preparedPronunciationQuery = ""
    root.pronunciationDownloadUrl = ""
    root.pronunciationFallbackUrl = ""
  }
  function playPreparedPronunciation() {
    pronunciationPlayer.command = [
      "pw-play", "--latency", "100ms", root.audioPaddedPath
    ]
    root.pronunciationState = "playing"
    pronunciationPlayer.running = true
  }
  function downloadPronunciation(url) {
    var source = String(url || "").trim()
    if (source === "") {
      root.pronunciationState = "error"
      return
    }
    root.pronunciationDownloadUrl = source
    audioDownload.command = [
      "curl", "-fsSL", "--connect-timeout", "2", "--max-time", "12",
      "--retry", "2", "--retry-delay", "1",
      "-H", "User-Agent: omarchy-dictionary/1.0",
      "-o", root.audioSourcePath, source
    ]
    root.pronunciationState = "downloading"
    audioDownload.running = true
  }
  function playPronunciation() {
    if (root.preparedPronunciationQuery === root.query) {
      root.playPreparedPronunciation()
      return
    }
    root.pronunciationQuery = root.query
    root.pronunciationFallbackUrl = root.entryAudioUrl()
    var args = Model.commonsAudioArgs(entryAudioSourceUrl())
    if (args.length > 0) {
      if (audioResolver.running) audioResolver.running = false
      audioResolver.command = args
      root.pronunciationState = "resolving"
      audioResolver.running = true
      return
    }
    root.downloadPronunciation(entryAudioUrl())
  }

  function runChineseGlossLookup() {
    if (root.language !== "en") return
    root.glossGeneration++
    root.chineseGlossQuery = root.query
    root.chineseGlossStatus = "loading"
    root.glossAdapterQueue = Model.chineseGlossAdaptersFor(root.language)
    root.glossAdapterIndex = 0
    if (root.glossInFlight) {
      root.glossPending = true
      root.glossCancelled = true
      chineseGlossProc.running = false
      return
    }
    root.glossCancelled = false
    root.runGlossAdapter()
  }

  function runGlossAdapter() {
    while (root.glossAdapterIndex < root.glossAdapterQueue.length) {
      var adapter = root.glossAdapterQueue[root.glossAdapterIndex]
      var args = []
      try { args = adapter.argsFor(root.chineseGlossQuery, root.language) || [] }
      catch (e) { console.warn("omarchy-dictionary: gloss adapter args failed:", e) }
      if (args.length > 0) {
        root.glossInFlight = true
        root.glossOutputReady = false
        root.glossExited = false
        root.glossOutput = ""
        chineseGlossProc.command = args
        chineseGlossProc.running = true
        return
      }
      root.glossAdapterIndex++
    }
    root.chineseGlossStatus = "none"
  }

  function queueGlossAdapterRun() {
    var generation = root.glossGeneration
    Qt.callLater(function() {
      if (root.glossGeneration !== generation || root.glossInFlight ||
          root.status !== "ok" || root.chineseGlossStatus !== "loading") return
      root.runGlossAdapter()
    })
  }

  function finishGlossIfReady() {
    if (!root.glossInFlight || !root.glossOutputReady || !root.glossExited) return
    root.glossInFlight = false
    if (root.glossPending) {
      root.glossPending = false
      root.glossCancelled = false
      root.queueGlossAdapterRun()
      return
    }
    if (root.glossCancelled || root.status !== "ok" ||
        root.chineseGlossQuery !== root.query) return
    var adapter = root.glossAdapterQueue[root.glossAdapterIndex]
    var result = null
    try { result = adapter.parse(root.glossOutput, root.chineseGlossQuery, root.language) }
    catch (e) { console.warn("omarchy-dictionary: gloss adapter parse failed:", e) }
    if (result && result.ok) {
      root.chineseMeanings = result.meanings
      root.chineseGlossStatus = "ok"
      return
    }
    root.glossAdapterIndex++
    root.queueGlossAdapterRun()
  }

  // ---- Focus handling. The field owns initial focus; Esc redirects to close.
  function refreshFocus() {
    if (!root.opened) return
    Qt.callLater(function() {
      if (searchField) {
        searchField.forceActiveFocus()
        if (String(searchField.text || "").length > 0) searchField.selectAll()
      }
    })
  }

  // ---- Lookup. The active query is the one in the field; if it changes
  //      while a request is in flight we kill the running process so a
  //      stale response can't overwrite the newer one. Each adapter writes
  //      to stdout; we parse it once on completion and advance down the
  //      chain until one succeeds.
  function runLookup(preserveRecovery) {
    root.lookupGeneration++
    var q = String(searchField.text || "").trim()
    root.query = q
    var oldOriginal = preserveRecovery ? root.originalQuery : ""
    var oldAutoMatch = preserveRecovery === true && root.isAutoMatched
    root.resetResults()
    if (q === "") {
      root.lookupCancelled = true
      root.lookupPending = false
      lookupProc.running = false
      return
    }
    root.originalQuery = oldOriginal
    root.isAutoMatched = oldAutoMatch
    root.language = Model.lookupLanguage(q)
    root.adapterQueue = (typeof Model.adaptersFor === "function")
      ? Model.adaptersFor(root.language) : []
    root.adapterIndex = 0
    root.status = "loading"
    if (root.lookupInFlight) {
      root.lookupPending = true
      root.lookupCancelled = true
      lookupProc.running = false
      return
    }
    root.lookupCancelled = false
    runAdapter()
  }

  // Run the current adapter in the chain. Adapters whose argsFor() yields
  // no argv (e.g. the local adapter with no data dir, or an empty query)
  // are skipped without touching the process.
  function runAdapter(lastResult) {
    while (root.adapterIndex < root.adapterQueue.length) {
      var adapter = root.adapterQueue[root.adapterIndex]
      var args = []
      try {
        args = adapter.argsFor(root.query, root.language) || []
      } catch (e) {
        console.warn("omarchy-dictionary: adapter", adapter && adapter.id, "argsFor failed:", e)
      }
      if (args.length > 0) {
        root.lookupInFlight = true
        root.lookupOutputReady = false
        root.lookupExited = false
        root.lookupOutput = ""
        lookupProc.command = args
        lookupProc.running = true
        return
      }
      root.adapterIndex++
    }
    // No adapter could even start — handle as an exhausted chain.
    onAdapterChainExhausted(lastResult ||
      { ok: false, kind: "error", error: "no dictionary source available" })
  }

  // Wait for both stdout and exit before using a result. This prevents a
  // failed process from advancing the adapter chain twice.
  function finishAdapterIfReady() {
    if (!root.lookupInFlight || !root.lookupOutputReady || !root.lookupExited) return
    root.lookupInFlight = false
    if (root.lookupPending) {
      root.lookupPending = false
      root.lookupCancelled = false
      root.queueAdapterRun(null)
      return
    }
    if (root.lookupCancelled || root.status !== "loading") return
    var adapter = root.adapterQueue[root.adapterIndex]
    var result = null
    try {
      result = adapter.parse(root.lookupOutput, root.query, root.language)
    } catch (e) {
      console.warn("omarchy-dictionary: adapter", adapter && adapter.id, "parse failed:", e)
    }
    if (result && result.ok) {
      root.entry = result.entry
      root.variants = result.variants || 0
      root.status = "ok"
      root.statusMessage = ""
      if (result.chineseMeanings && result.chineseMeanings.length) {
        root.chineseMeanings = result.chineseMeanings
        root.chineseGlossStatus = "ok"
      } else {
        root.runChineseGlossLookup()
      }
      return
    }
    root.adapterIndex++
    root.queueAdapterRun(result || { ok: false, kind: "error", error: "dictionary response failed" })
  }

  function queueAdapterRun(lastResult) {
    var generation = root.lookupGeneration
    Qt.callLater(function() {
      if (root.lookupGeneration !== generation || root.lookupInFlight || root.status !== "loading") return
      root.runAdapter(lastResult)
    })
  }

  // The whole chain failed. `result` is the last adapter's outcome and
  // drives the same end states a single-source lookup used to produce:
  // notfound-ish results get fuzzy recovery, anything else is an error.
  function onAdapterChainExhausted(result) {
    root.entry = null
    if (result && (result.kind === "notfound" || result.kind === "invalid" || result.kind === "empty")) {
      if (root.isAutoMatched) {
        // Recovery round tripped without finding a working word —
        // don't loop, just show the notfound state.
        root.originalQuery = ""
        root.isAutoMatched = false
        root.status = "notfound"
        root.statusMessage = "no definition found"
        return
      }
      root.originalQuery = root.query
      var fuzzy = root.language === "en" ? Model.fuzzyMatch(root.query) : null
      if (fuzzy && fuzzy.autoMatch) {
        // Rewrite the field to the candidate so the user can see what
        // we fetched, keep it marked "auto", and fetch it. The next
        // round will see isAutoMatched === true on any further 404.
        // programmaticEdit suppresses applyEdited's user-reset clauses
        // while the field is being updated by us, not the user.
        root.isAutoMatched = true
        root.programmaticEdit = true
        searchField.text = fuzzy.autoMatch
        root.query = fuzzy.autoMatch
        root.programmaticEdit = false
        root.runLookup(true)
        return
      }
      if (fuzzy && fuzzy.alternatives && fuzzy.alternatives.length > 0) {
        root.suggestions = fuzzy.alternatives
        root.status = "suggestions"
        root.statusMessage = "no definition found for \"" + root.originalQuery + "\""
      } else {
        root.status = "notfound"
        root.statusMessage = "no definition found for \"" + root.originalQuery + "\""
      }
    } else {
      root.status = "error"
      root.statusMessage = (result && result.error) || "could not look up the word"
    }
  }

  // The grammar of "search" — Enter fires immediately; typing clears any
  // pending debounce and resets state so a stale response can't surprise
  // the user. Esc routes to the panel close (the keyCatcher handles it).
  // When programmaticEdit is true (auto-match recovery just rewrote the
  // field to a candidate word) we skip the user-reset clauses so the
  // isAutoMatched flag survives into the second lookup.
  function applyEdited() {
    if (root.programmaticEdit) return
    root.lookupGeneration++
    var q = String(searchField.text || "").trim()
    root.query = q
    if (root.lookupInFlight) {
      root.lookupCancelled = true
      root.lookupPending = false
      lookupProc.running = false
    }
    if (q === "") {
      root.resetResults()
      return
    }
    if (searchDebounce.running) searchDebounce.stop()
    // Don't auto-fire on every keystroke — the API is rate-limited and
    // half-typed words make noise — but clear any in-flight result so the
    // panel doesn't show stale data next to fresh text.
    if (root.status !== "idle") {
      root.resetResults()
    }
  }

  // Lookup process. Each adapter in the chain gets one run of this process:
  // curl for the network adapters, gzip for the local one. Curl exits 22
  // on the not-found path (HTTP 404), which is not a network error from
  // the user's perspective; the response body carries the API's own
  // message, so we always try to parse stdout first.
  Process {
    id: lookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.lookupOutput = text
        root.lookupOutputReady = true
        root.finishAdapterIfReady()
      }
    }
    stderr: StdioCollector {
      id: lookupStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.lookupExitCode = exitCode
      root.lookupExited = true
      root.finishAdapterIfReady()
    }
  }

  Process {
    id: chineseGlossProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.glossOutput = text
        root.glossOutputReady = true
        root.finishGlossIfReady()
      }
    }
    onExited: function(exitCode) {
      root.glossExited = true
      root.finishGlossIfReady()
    }
  }

  Process {
    id: audioResolver
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.pronunciationQuery !== root.query) return
        var directUrl = Model.parseCommonsAudioUrl(text)
        root.downloadPronunciation(directUrl !== "" ? directUrl : root.entryAudioUrl())
      }
    }
  }

  Process {
    id: audioDownload
    onExited: function(exitCode) {
      if (root.pronunciationQuery !== root.query) return
      if (exitCode !== 0) {
        if (root.pronunciationFallbackUrl !== "" &&
            root.pronunciationDownloadUrl !== root.pronunciationFallbackUrl) {
          root.downloadPronunciation(root.pronunciationFallbackUrl)
          return
        }
        root.pronunciationState = "error"
        console.warn("omarchy-dictionary: pronunciation download failed")
        return
      }
      audioPadding.command = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", root.audioSourcePath,
        "-af", "adelay=250:all=1",
        "-ar", "48000", root.audioPaddedPath
      ]
      root.pronunciationState = "padding"
      audioPadding.running = true
    }
  }

  Process {
    id: audioPadding
    onExited: function(exitCode) {
      if (root.pronunciationQuery !== root.query) return
      if (exitCode !== 0) {
        root.pronunciationState = "error"
        console.warn("omarchy-dictionary: pronunciation padding failed")
        return
      }
      root.preparedPronunciationQuery = root.pronunciationQuery
      root.playPreparedPronunciation()
    }
  }

  Process {
    id: pronunciationPlayer
    onExited: function(exitCode) {
      root.pronunciationState = exitCode === 0 ? "idle" : "error"
      if (exitCode !== 0) console.warn("omarchy-dictionary: pronunciation playback failed")
    }
  }

  // Debounce kept as a Timer in case auto-search is enabled later — for now
  // it's only used to dedupe rapid Enter presses during a request.
  Timer {
    id: searchDebounce
    interval: root.searchDelayMs
    repeat: false
    onTriggered: runLookup()
  }

  onOpenedChanged: if (opened) refreshFocus()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, root.panelMaxHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Type to search shortcuts when the field isn't focused: "/" focuses
      // and selects the search field (fuzzy launcher convention); "Esc"
      // arrives here only when the field does not own focus.
      onTextKey: function(t) {
        if (t === "/") {
          root.refreshFocus()
        }
      }

Column {
      id: panelColumn
      width: parent.width
      spacing: Style.space(14)

        // ---------- Hero: title + entry summary
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: "󰗚"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Dictionary"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: {
                if (root.status === "ok" && root.entry) {
                  var parts = root.heroSummary
                  var suffix = root.variants > 1 ? " · " + root.variants + " entries" : ""
                  return (parts === "" ? "found" : parts) + suffix
                }
                if (root.status === "loading") return "looking up…"
                if (root.status === "notfound") return "no definition"
                if (root.status === "error") return "couldn't reach the API"
                return "English ↔ 中文"
              }
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

        }

        // ---------- Search field ----------
        PanelSeparator {
          foreground: root.contentForeground
        }

        Item {
          width: parent.width
          implicitHeight: Style.space(46)

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: "transparent"
            border.width: Style.spacing.hairline
            border.color: searchField.activeFocus
              ? Color.accent
              : Qt.darker(root.contentForeground, 1.7)

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(10)

              Text {
                text: "󰍉"
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
              }

              TextField {
                id: searchField
                width: parent.width - clearRow.width - iconText.width - Style.space(10) * 2
                height: parent.height
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                color: root.contentForeground
                placeholderText: "Search English or Chinese…"
                placeholderTextColor: Qt.darker(root.contentForeground, 2.0)
                background: null
                selectByMouse: true
                clip: true
                onTextChanged: root.applyEdited()
                Keys.onEscapePressed: function(event) {
                  // Esc with empty field → close; Esc with text → clear the text.
                  if (String(searchField.text || "").length > 0) {
                    searchField.text = ""
                  } else {
                    root.close()
                    event.accepted = true
                    return
                  }
                  event.accepted = true
                }
              }

              Row {
                id: clearRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Button {
                  id: clearButton
                  visible: String(searchField.text || "") !== ""
                  text: "✕"
                  onClicked: {
                    searchField.text = ""
                    root.refreshFocus()
                  }
                  foreground: root.contentForeground
                }

                Button {
                  id: searchButton
                  text: "→"
                  enabled: String(searchField.text || "").trim() !== "" && root.status !== "loading"
                  onClicked: {
                    searchDebounce.stop()
                    root.runLookup()
                  }
                  foreground: root.contentForeground
                }
              }
            }

            // Tag the pressed-Enter inside the TextField to the lookup. The
            // field handles onAccepted, but Quickshell's TextField wraps its
            // keys, so onAccepted plus the explicit returnPressed below give
            // a single firing path regardless of focus holder quirks.
            Item {
              id: iconText
              width: Style.space(22)
              height: Style.space(22)
              visible: false
            }
          }
        }

        Keys.onReturnPressed: function(event) {
          if (String(searchField.text || "").trim() !== "") {
            searchDebounce.stop()
            root.runLookup()
            event.accepted = true
          }
        }
        Keys.onEnterPressed: function(event) {
          if (String(searchField.text || "").trim() !== "") {
            searchDebounce.stop()
            root.runLookup()
            event.accepted = true
          }
        }

        // ---------- Body ----------
        PanelSeparator {
          foreground: root.contentForeground
        }

        // Body container — one slot per response state, only the active one
        // is visible. Pinned at top-left, full column width. Each branch
        // carries its own spacing/typography so swapping them doesn't
        // shift adjacent layout.
        Item {
          id: body
          width: parent.width
          implicitHeight: bodyColumn.implicitHeight

          Column {
            id: bodyColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(8)

            // Idle — no query yet.
            Column {
              width: parent.width
              visible: root.status === "idle"
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: "Type an English or Chinese word above, then press Enter."
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: "English and Chinese words have bundled offline definitions and translations; online sources add pronunciation and extra entries."
                color: Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // Loading. The Omarchy UI kit doesn't ship a spinner component,
            // so the magnify glyph is reused and rotated indefinitely while
            // a fetch is in flight.
            Row {
              visible: root.status === "loading"
              spacing: Style.space(10)
              width: parent.width

              Item {
                width: Style.space(18)
                height: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  text: "󰗚"
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  transformOrigin: Item.Center

                  NumberAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                    running: root.status === "loading"
                  }
                }
              }

              Text {
                text: "Looking up \"" + root.query + "\"…"
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Suggestions from the local fuzzy match.
            Column {
              width: parent.width
              visible: root.status === "suggestions"
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "No definition for \"" + (root.originalQuery || root.query) + "\"."
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.0)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: "Did you mean:"
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.0
              }

              // Chip row — one clickable Button per candidate.
              Flow {
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: root.suggestions

                  Button {
                    required property string modelData
                    text: modelData
                    foreground: root.contentForeground
                    onClicked: root.search(modelData)
                  }
                }
              }
            }

            // Not found (no fuzzy candidates).
            Column {
              width: parent.width
              visible: root.status === "notfound"
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: "No definition for \"" + root.query + "\"."
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.0)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                visible: root.statusMessage !== ""
                text: root.statusMessage
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // Error.
            Column {
              width: parent.width
              visible: root.status === "error"
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: "Couldn't look up \"" + root.query + "\"."
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.0)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: root.statusMessage
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // ---------- Results: word header + scrollable meaning list ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.status === "ok" && root.entry !== null

          // Auto-match note. Only rendered when the user's original query
          // was misspelled and we silently fetched the closest match.
          // The text body is computed by a JS function so the ternary
          // doesn't evaluate the .word property on a null entry — that
          // pattern raises "Cannot read property 'word' of null" in QML
          // because it pre-evaluates both sides of `?:`.
          Text {
            width: parent.width
            visible: root.isAutoMatched && root.originalQuery !== "" && root.entry !== null
            text: root.autoMatchedNote()
            textFormat: Text.PlainText
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              id: wordText
              text: root.entryWord()
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
              font.bold: true
              elide: Text.ElideRight
              width: Math.max(Style.space(80),
                parent.width - phoneticLabel.width - sourceTag.width
                - (pronunciationButton.visible ? pronunciationButton.width + Style.space(10) : 0)
                - Style.space(20))
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: phoneticLabel
              text: root.entryPhonetic()
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.italic: true
              anchors.verticalCenter: parent.verticalCenter
              visible: text !== ""
            }

            Button {
              id: pronunciationButton
              iconText: "󰕾"
              tooltipText: "Play pronunciation"
              visible: root.entryAudioUrl() !== ""
              enabled: root.pronunciationState === "idle" || root.pronunciationState === "error"
              foreground: root.contentForeground
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.playPronunciation()
            }

            // Small muted source tag (e.g. "Wiktionary") to make it obvious
            // which data source filled the panel.
            Text {
              id: sourceTag
              text: root.entry ? Model.sourceLabel(entry) : ""
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.55)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
              anchors.verticalCenter: parent.verticalCenter
              visible: text !== ""
            }
          }

          Flickable {
            id: resultScroll
            width: parent.width
            height: Math.min(
              root.panelMaxHeight - Style.space(320),
              Math.max(Style.space(160), root.entry
                ? Math.min(Style.space(540), meaningStack.implicitHeight + Style.space(16))
                : Style.space(160))
            )
            contentWidth: width
            contentHeight: meaningStack.implicitHeight + Style.space(16)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
              id: meaningStack
              width: resultScroll.width
              spacing: Style.space(14)

              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.chineseGlossStatus === "loading" || root.chineseMeanings.length > 0

                Text {
                  text: "中文释义"
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.4
                }

                Text {
                  visible: root.chineseGlossStatus === "loading"
                  text: "正在加载…"
                  color: Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }

                Repeater {
                  model: root.chineseMeanings

                  Column {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(4)

                    Text {
                      text: modelData.partOfSpeech
                      color: Qt.darker(root.contentForeground, 1.25)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Repeater {
                      model: modelData.definitions
                      Text {
                        required property var modelData
                        width: parent.width
                        text: "• " + modelData.definition
                        textFormat: Text.PlainText
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        wrapMode: Text.WordWrap
                      }
                    }
                  }
                }

                PanelSeparator {
                  foreground: root.contentForeground
                }

                Text {
                  visible: root.chineseMeanings.length > 0 && root.entry && root.entry.meanings.length > 0
                  text: "English definitions"
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.4
                }
              }

              Repeater {
                model: root.entry ? root.entry.meanings : []

                Column {
                  required property var modelData
                  required property int index
                  width: parent.width
                  spacing: Style.space(6)

                  Row {
                    width: parent.width
                    spacing: Style.space(8)
                    // Some offline entries never declare a part of speech
                    // (letters, prefixes) — render their definitions with
                    // no header instead of an empty gold label.
                    visible: modelData.partOfSpeech !== ""

                    Text {
                      text: modelData.partOfSpeech
                      textFormat: Text.PlainText
                      color: Color.accent
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.4
                      font.italic: true
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                      width: parent.width - implicitWidth - Style.space(8)
                      height: Style.spacing.hairline
                      color: Qt.darker(root.contentForeground, 1.9)
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Repeater {
                    model: modelData.definitions

                    Column {
                      required property var modelData
                      required property int index
                      width: parent.width
                      spacing: Style.space(2)

                      Row {
                        width: parent.width
                        spacing: Style.space(8)

                        Text {
                          text: (index + 1) + "."
                          color: Qt.darker(root.contentForeground, 1.5)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          width: Style.space(20)
                          horizontalAlignment: Text.AlignRight
                          anchors.top: parent.top
                          anchors.topMargin: 2
                        }

                        Text {
                          width: parent.width - Style.space(20) - Style.space(8)
                          text: modelData.definition
                          textFormat: Text.PlainText
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          wrapMode: Text.WordWrap
                        }
                      }

                      Text {
                        width: parent.width - Style.space(20) - Style.space(8)
                        x: Style.space(20) + Style.space(8)
                        visible: modelData.example !== ""
                        text: "\"" + modelData.example + "\""
                        textFormat: Text.PlainText
                        color: Qt.darker(root.contentForeground, 1.3)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.italic: true
                        wrapMode: Text.WordWrap
                      }
                    }
                  }

                  Text {
                    visible: modelData.synonyms.length > 0
                    width: parent.width
                    text: "synonyms: " + modelData.synonyms.join(", ")
                    textFormat: Text.PlainText
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    visible: modelData.antonyms.length > 0
                    width: parent.width
                    text: "antonyms: " + modelData.antonyms.join(", ")
                    textFormat: Text.PlainText
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }

              Item {
                width: parent.width
                height: Style.space(4)
              }
            }
          }
        }

        // ---------- Hotkey script footer ----------
        // Explicit opt-in install for the SUPER+D selection lookup.
        // Nothing is written to ~/.local/bin/ until the user clicks
        // Install. Status comes from the host BarWidget
        // (installStatus/installMessage) which runs the mkdir/cmp/install
        // stages shell-free.
        //
        // The footer (and its separator) hide once the script is confirmed
        // installed — either installed this session or verified up-to-date
        // by the startup check — so the prompt doesn't linger after
        // install (issue #9). It stays visible while idle/working/error so
        // progress, failure messages, and retry remain reachable.
        PanelSeparator {
          foreground: root.contentForeground
          visible: !root.hotkeyScriptInstalled
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.hotkeyScriptInstalled

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              id: installLabel
              text: "Install hotkey script"
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              width: parent.width - installButton.width - Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: installButton
              text: "Install"
              enabled: root.hostWidget ? root.hostWidget.installStatus !== "working" : true
              onClicked: {
                if (root.hostWidget && typeof root.hostWidget.installHotkeyScript === "function")
                  root.hostWidget.installHotkeyScript()
              }
              foreground: root.contentForeground
            }
          }

          Text {
            width: parent.width
            visible: text !== ""
            text: root.hostWidget ? root.hostWidget.installMessage : ""
            textFormat: Text.PlainText
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "Enables SUPER+D lookup. Installs to ~/.local/bin/."
            textFormat: Text.PlainText
            color: Qt.darker(root.contentForeground, 1.7)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Build version ----------
        // Right-aligned so it sits in the popup's bottom-right corner and
        // never shifts as the result body changes above it.
        Text {
          anchors.right: parent.right
          text: root.buildVersion
          textFormat: Text.PlainText
          color: Qt.darker(root.contentForeground, 1.8)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
