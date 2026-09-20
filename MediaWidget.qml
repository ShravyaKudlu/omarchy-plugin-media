import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons

// mystaryo.media — always-on cava spectrum in the bar. Click for a two-tab
// player popup: Now Playing (any MPRIS player, cliamp pinned) + cliamp
// browser (radio/local via daemon IPC, cold-start included).
//
// Design rules: MPRIS + audio-tap data only (no notification listeners, so
// unknown sounds can only ever move bars, never crash anything). Every
// external boundary (cava, cliamp socket, metadata shapes) degrades to a
// static/empty state instead of failing. No absolute paths: the cava config
// ships in this folder; colors come from the live bar theme.
BarWidget {
  id: root
  moduleName: "mystaryo.media"

  // ---- MPRIS players directly (no omarchy.media service dependency) ----
  // The shell only grants firstPartyServiceFor("omarchy.media") proxies to
  // full-"bar" facades; plain bar-widgets get null there. Mpris.players hands
  // us the same player objects, so we track them ourselves. Works whether
  // or not the stock media service/widget is enabled.
  readonly property var allPlayers: Mpris.players ? Mpris.players.values : []
  // Preferred Now Playing source (settings gear → Music player). "auto"
  // follows whichever player is active (playing first, then titled, then
  // first found). Stored as a normalized dbus suffix so per-launch
  // ".instanceNNN" suffixes don't break the match. cliamp is never a Now
  // Playing source — it has its own tab.
  property string musicPlayerPref: "auto"
  // Set true for journal debugging (command calls, focus changes, search).
  // Default off: the widget is chatty otherwise (settings IO, cliamp IPC).
  property bool debug: false
  function dbg(msg) { try { if (root.debug) console.log("mystaryo.media: " + msg) } catch (e) {} }
  // Well-known players, always listed so a favorite can be picked even
  // before it has ever run. Live-detected apps are appended below these.
  readonly property var knownPlayers: [
    { id: "firefox", label: "Firefox / Zen" },
    { id: "chromium", label: "Chromium / Chrome" },
    { id: "brave", label: "Brave" },
    { id: "vivaldi", label: "Vivaldi" },
    { id: "opera", label: "Opera" },
    { id: "vlc", label: "VLC" },
    { id: "spotify", label: "Spotify" },
    { id: "mpv", label: "mpv" },
    { id: "rhythmbox", label: "Rhythmbox" },
    { id: "audacious", label: "Audacious" },
    { id: "clementine", label: "Clementine" },
    { id: "strawberry", label: "Strawberry" },
    { id: "elisa", label: "Elisa" },
    { id: "lollypop", label: "Lollypop" },
    { id: "quodlibet", label: "Quod Libet" },
    { id: "tauon", label: "Tauon" },
    { id: "amberol", label: "Amberol" },
    { id: "mpd", label: "MPD" }
  ]
  function normPlayerId(player) {
    try {
      return String(player.dbusName || "")
        .replace(/^org\.mpris\.MediaPlayer2\./, "")
        .replace(/\.instance[0-9]+$/, "")
        .toLowerCase()
    } catch (e) { return "" }
  }
  function playerMatchesPref(player) {
    var pref = String(root.musicPlayerPref || "auto").toLowerCase()
    if (pref === "" || pref === "auto") return false
    var id = normPlayerId(player)
    if (id === pref) return true
    try {
      var label = String(player.identity || player.desktopEntry || "").toLowerCase()
      if (label !== "" && (label === pref || id.indexOf(pref) !== -1 || pref.indexOf(id) !== -1)) return true
    } catch (e) {}
    return false
  }
  // Settings options: Auto first, then the well-known apps (always
  // visible), then any other live-detected player. A stored pick whose app
  // isn't running is kept as an "(offline)" row so the choice is never
  // silently lost.
  readonly property var musicPlayerOptions: {
    var opts = [{ id: "auto", label: "Auto (active player)" }]
    var seen = { "auto": true }
    var k
    try {
      for (k = 0; k < knownPlayers.length; k++) {
        if (seen[knownPlayers[k].id]) continue
        seen[knownPlayers[k].id] = true
        opts.push(knownPlayers[k])
      }
      for (var i = 0; i < allPlayers.length; i++) {
        var p = allPlayers[i]
        if (root.isCliamp(p)) continue
        var id = normPlayerId(p)
        if (id === "" || seen[id]) continue
        seen[id] = true
        opts.push({ id: id, label: root.shortLabel(p) })
      }
    } catch (e) {}
    var pref = String(root.musicPlayerPref || "auto").toLowerCase()
    if (pref !== "" && pref !== "auto" && !seen[pref])
      opts.push({ id: pref, label: pref + " (offline)" })
    return opts
  }
  function setMusicPlayer(id) {
    var v = String(id || "auto").toLowerCase()
    if (v === "") v = "auto"
    if (root.musicPlayerPref === v) return
    root.musicPlayerPref = v
    saveMusicPlayer()
  }
  // Now Playing source list. Under Auto that's whichever app is active
  // (playing first, then titled, then first found, cliamp excluded). With a
  // locked app, that app when present — otherwise falls back to Auto so the
  // tab never goes empty while something else plays.
  // The spectrum still dances for any audio regardless.
  readonly property var sourcePlayers: {
    var pool = []
    for (var i = 0; i < allPlayers.length; i++) {
      try { if (!isCliamp(allPlayers[i])) pool.push(allPlayers[i]) } catch (e) {}
    }
    if (pool.length === 0) return []
    var pref = String(root.musicPlayerPref || "auto").toLowerCase()
    if (pref !== "" && pref !== "auto") {
      var list = []
      for (var j = 0; j < pool.length; j++) {
        try { if (playerMatchesPref(pool[j])) list.push(pool[j]) } catch (e2) {}
      }
      if (list.length > 0) return list
    }
    var titled = null
    for (var k = 0; k < pool.length; k++) {
      try {
        if (pool[k].isPlaying) return [pool[k]]
        if (!titled && pool[k].trackTitle) titled = pool[k]
      } catch (e3) {}
    }
    if (titled) return [titled]
    return [pool[0]]
  }
  property int tabIndex: 0 // 0 = now playing, 1 = cliamp, 2 = settings
  property bool popupOpen: false

  // Blinking search cursor: driven by a timer, not by focus state, so it is
  // visible whenever the cliamp tab is open (focus inside grab popups is
  // unreliable — same reason the field is key-captured, not a TextInput).
  property bool cursorOn: true
  Timer {
    id: cursorTimer
    interval: 530
    repeat: true
    running: root.popupOpen && root.tabIndex === 1
    onTriggered: root.cursorOn = !root.cursorOn
  }
  Timer {
    id: focusTimer
    interval: 250
    repeat: true
    running: root.popupOpen && root.tabIndex === 1
    property bool lastFocus: false
    onTriggered: {
      try {
        if (keyCatcher.activeFocus !== lastFocus) {
          lastFocus = keyCatcher.activeFocus
          root.dbg("catcher focus -> " + lastFocus)
        }
        if (!keyCatcher.activeFocus) keyCatcher.forceActiveFocus()
      } catch (e) {}
    }
  }

  // Called by the popup scrim's outside-click dismissal and Esc handling.
  // Without it the scrim severs our `open:` binding on first dismiss and
  // the popup never reopens.
  function close() { popupOpen = false }

  function shortLabel(player) {
    if (!player) return ""
    var dbus = String(player.dbusName || "").replace(/^org\.mpris\.MediaPlayer2\./, "").replace(/\.instance[0-9]+$/, "")
    return player.desktopEntry || player.identity || dbus || "player"
  }
  function isCliamp(player) {
    if (!player) return false
    return String(player.dbusName || "").indexOf("cliamp") !== -1
  }
  readonly property var selectedPlayer: sourcePlayers.length > 0 ? sourcePlayers[0] : null
  // Tab-0 player switcher jumps straight to a preferred-app lock.
  function selectPlayer(player) {
    if (!player) return
    var id = normPlayerId(player)
    if (id !== "") setMusicPlayer(id)
  }
  Component.onCompleted: { loadSettings() }

  // ---- transport on an explicit player (capability-gated, never throws) ----
  function canToggle(p) { try { return !!(p && (p.canTogglePlaying || p.canPlay || p.canPause)) } catch (e) { return false } }
  function canStep(p, dir) { try { return !!(p && ((dir < 0 && p.canGoPrevious) || (dir > 0 && p.canGoNext))) } catch (e) { return false } }
  function togglePlayer(p) {
    if (!p) return
    try {
      if (p.isPlaying) { if (p.canPause) p.pause(); else if (p.canTogglePlaying) p.togglePlaying() }
      else { if (p.canPlay) p.play(); else if (p.canTogglePlaying) p.togglePlaying() }
    } catch (e) {}
  }
  function stopPlayer(p) {
    if (!p) return
    if (root.isCliamp(p)) cliampCall("runtime.stop", {}, function() { refreshCliampTab() })
    var stopped = false
    try { if (typeof p.stop === "function") { p.stop(); stopped = true } } catch (e) {}
    if (!stopped) { try { if (p.canPause) p.pause(); else if (p.canTogglePlaying) p.togglePlaying() } catch (e2) {} }
  }
  function stepPlayer(p, dir) {
    if (!p) return
    try {
      if (dir < 0 && p.canGoPrevious) p.previous()
      else if (dir > 0 && p.canGoNext) p.next()
    } catch (e) {}
  }
  function cliampPlayer() {
    for (var i = 0; i < sourcePlayers.length; i++) {
      try { if (isCliamp(sourcePlayers[i])) return sourcePlayers[i] } catch (e) {}
    }
    return null
  }
  function cliampPlaying() {
    var p = cliampPlayer()
    try { if (p) return !!p.isPlaying } catch (e) {}
    return root.cliampState === "playing"
  }
  function toggleCliamp() {
    var p = cliampPlayer()
    if (p && root.canToggle(p)) {
      root.togglePlayer(p)
      return
    }
    // No MPRIS player (yet): toggle headless via IPC.
    cliampCall("runtime.toggle", {}, function() { refreshCliampTab() })
  }

  // ---- shared key handling: EITHER window may own keyboard focus ----
  // The popup opens from a bar click, so keyboard focus usually stays on the
  // bar window; Hyprland may or may not move it into the popup as the mouse
  // travels. Handling keys in BOTH windows makes typing work regardless of
  // mouse position. Only the focused window's catcher fires per keypress.
  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.close()
      event.accepted = true
      return
    }
    if (root.tabIndex !== 1 || !root.popupOpen) return
    if (event.key === Qt.Key_Backspace) {
      root.searchQuery = root.searchQuery.slice(0, -1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.runSearch()
      event.accepted = true
    } else if (event.text !== "") {
      root.searchQuery += event.text
      event.accepted = true
    }
  }

  // Bar-side catcher: covers the case where keyboard focus stays on the bar
  // window (e.g. transiently while the popup opens). Shares handleKey.
  Item {
    id: barCatcher
    width: 0
    height: 0
    focus: popupPanel.visible
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) { root.handleKey(event) }
  }

  // Screen hosting the bar (popup shows there; falls back to all screens).
  readonly property var barScreen: {
    try { return root.QsWindow.window.screen } catch (e) { return null }
  }
  // Card anchor: widget center-x / bottom-y in screen coords, captured on open.
  property real cardX: -1
  property real cardY: -1

  // ---- cava spectrum pipe ----
  readonly property int barCount: 12
  readonly property int barMax: 7
  property var barValues: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  property bool cavaDead: false
  property int cavaRestarts: 0

  readonly property string cavaConf: {
    var u = Qt.resolvedUrl("cava.conf").toString()
    if (u.indexOf("file://") === 0) u = u.substring(7)
    try { return decodeURIComponent(u) } catch (e) { return u }
  }
  function parseFrame(line) {
    // cava 0.10 raw ascii emits the full FFT (~1024 bins per frame), not
    // bars_number values: downsample by taking the PEAK of each group.
    // Averaging would dilute a narrow kick drum 85:1 into flatness — peak
    // keeps transients and bass punching through.
    try {
      var parts = String(line).split(";")
      var vals = []
      for (var i = 0; i < parts.length; i++) {
        if (parts[i] === "") continue
        var v = parseInt(parts[i], 10)
        if (isNaN(v) || v < 0) v = 0
        if (v > root.barMax) v = root.barMax
        vals.push(v)
      }
      if (vals.length < root.barCount) return // partial flush line: keep previous
      var per = Math.floor(vals.length / root.barCount)
      var out = []
      for (var b = 0; b < root.barCount; b++) {
        var m = 0
        for (var k = 0; k < per; k++) {
          var vv = vals[b * per + k]
          if (vv > m) m = vv
        }
        out.push(m)
      }
      root.barValues = out
    } catch (e) { /* keep previous frame, never crash on junk */ }
  }
  // Audio chain: parecord taps the default sink monitor as raw s16le into a
  // fifo; cava reads it and emits raw frames. Single recorder child so the
  // EXIT trap reaps it cleanly, plus fuser -k at startup to reap any writers
  // orphaned by earlier hot-reloads (two writers interleave bytes = flat bars).
  Process {
    id: cavaProc
    command: ["sh", "-c", "F=/tmp/mystaryo-media-cava.fifo; [ -p \"$F\" ] || mkfifo \"$F\"; fuser -k \"$F\" 2>/dev/null; M=$(pactl get-default-sink).monitor; parecord --device=\"$M\" --format=s16le --rate=48000 --channels=2 --latency-msec=50 --process-time-msec=20 --raw \"$F\" & REC=$!; trap \"kill $REC 2>/dev/null\" EXIT; cava -p \"" + root.cavaConf + "\""]
    running: !root.cavaDead
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.parseFrame(data) }
    }
    stderr: StdioCollector { waitForEnd: false }
    onExited: {
      // Supervisor: restart with backoff, give up after 5 tries (flat bars).
      if (root.cavaRestarts >= 5) { root.cavaDead = true; return }
      root.cavaRestarts++
      restartTimer.start()
    }
  }
  Timer {
    id: restartTimer
    interval: 2000
    repeat: false
    onTriggered: if (!root.cavaDead) cavaProc.running = true
  }

  // ---- one-shot + async cliamp IPC helpers ----
  Component {
    id: procFactory
    Process {
      property var callback: null
      stdout: StdioCollector { id: out; waitForEnd: true }
      onExited: function(exitCode, exitStatus) {
        var cb = callback
        var txt = out.text
        callback = null
        if (cb) cb(txt, exitCode)
        destroy()
      }
    }
  }
  function runCmd(args, cb) {
    try {
      root.dbg("runCmd " + args.slice(0, 4).join(" "))
      var p = procFactory.createObject(root, { command: args, callback: cb })
      p.running = true
    } catch (e) { root.dbg("runCmd create failed"); if (cb) cb("", 1) }
  }
  Timer {
    id: later
    interval: 400
    repeat: false
    property var fn: null
    onTriggered: { var f = fn; fn = null; if (f) f() }
  }
  function defer(fn) { later.fn = fn; later.restart() }
  // Single round-trip: --wait blocks until the job finishes, so the
  // result (or null on any failure) comes back in one callback.
  // searchBusy guards against overlapping searches; lastError surfaces the
  // raw daemon reply when it isn't parseable (shown in the note line).
  property bool searchBusy: false
  property string lastError: ""
  function cliampCall(op, params, onDone) {
    var args = ["cliamp", "remote", "call", op, "--params", JSON.stringify(params || {}), "--wait"]
    runCmd(args, function(out) {
      var res = null
      try {
        var j = JSON.parse(out)
        if (j && j.job && j.job.state === "succeeded") res = j.job.result
        else root.lastError = String(out).substring(0, 120)
      } catch (e) {
        root.lastError = String(out).substring(0, 120)
      }
      onDone(res)
    })
  }

  // ---- cliamp tab state ----
  property bool cliampUp: false
  property string cliampState: ""
  property string cliampTrack: ""
  property var searchRows: []
  property string cliampNote: ""
  property string searchQuery: ""
  property var playCounts: ({}) // normalized station key -> play count (history)

  // "Radio Mirchi Hindi [128k] · India" -> "radio mirchi hindi"
  function normKey(s) {
    try {
      var k = String(s || "").toLowerCase()
      var i = k.indexOf(" [")
      if (i !== -1) k = k.substring(0, i)
      var j = k.indexOf(" ·")
      if (j !== -1) k = k.substring(0, j)
      return k.trim()
    } catch (e) { return "" }
  }
  function loadPlayCounts() {
    cliampCall("runtime.history", { limit: 100 }, function(res) {
      var counts = {}
      try {
        var h = (res && res.history) || []
        for (var i = 0; i < h.length; i++) {
          var t = (h[i] && h[i].track) || {}
          var k = normKey(t.station || t.title)
          if (k !== "") counts[k] = (counts[k] || 0) + 1
        }
      } catch (e) {}
      root.playCounts = counts
    })
  }

  // Fixed curated top-12 with direct stream URLs (from
  // https://radio.cliamp.stream/streams.m3u). Played via track.play with the
  // same {title,path,stream,realtime} shape the daemon accepts — no search
  // round-trip, so entries can never "not be found".
  readonly property var topStations: [
    { label: "Lofi Stream", path: "https://radio.cliamp.stream/lofi/stream" },
    { label: "Synthwave Stream", path: "https://radio.cliamp.stream/synthwave/stream" },
    { label: "EDM Stream", path: "https://radio.cliamp.stream/edm/stream" },
    { label: "Omarchy Radio", path: "https://radio.cliamp.stream/omarchy/stream" },
    { label: "NCS Stream", path: "https://radio.cliamp.stream/ncs/stream" },
    { label: "NCS House Stream", path: "https://radio.cliamp.stream/ncs-house/stream" },
    { label: "NCS Dubstep Stream", path: "https://radio.cliamp.stream/ncs-dubstep/stream" },
    { label: "NCS Drum & Bass Stream", path: "https://radio.cliamp.stream/ncs-dnb/stream" },
    { label: "NCS Trap Stream", path: "https://radio.cliamp.stream/ncs-trap/stream" },
    { label: "NCS Phonk Stream", path: "https://radio.cliamp.stream/ncs-phonk/stream" },
    { label: "NCS Pop Stream", path: "https://radio.cliamp.stream/ncs-pop/stream" },
    { label: "NCS Chill Stream", path: "https://radio.cliamp.stream/ncs-chill/stream" }
  ]

  function refreshCliampTab() {
    loadPlayCounts()
    runCmd(["cliamp", "remote", "state"], function(out) {
      var snap = null
      try {
        var j = JSON.parse(out)
        if (j && j.ok) snap = j.snapshot
      } catch (e) {}
      if (!snap) {
        root.cliampUp = false
        root.cliampState = ""
        root.cliampTrack = ""
        return
      }
      root.cliampUp = true
      root.cliampState = String(snap.state || "")
      try {
        var lt = snap.logical_track || {}
        root.cliampTrack = String(lt.title || lt.path || "")
      } catch (e) { root.cliampTrack = "" }
    })
  }
  function normRows(res) {
    // Normalize the various result shapes into [{label, ref}] defensively.
    var rows = []
    try {
      var list = null
      if (!res) return rows
      if (Array.isArray(res)) list = res
      else if (Array.isArray(res.playlists)) list = res.playlists
      else if (Array.isArray(res.tracks)) list = res.tracks
      else if (Array.isArray(res.items)) list = res.items
      else if (Array.isArray(res.results)) list = res.results
      if (!list) return rows
      for (var i = 0; i < list.length; i++) {
        var it = list[i] || {}
        var label = String(it.name || it.title || it.path || it.id || "")
        if (!label) continue
        rows.push({ label: label, ref: it })
      }
    } catch (e) {}
    return rows.slice(0, 30)
  }
  function playStation(station) {
    var label = ""
    var path = ""
    try { label = String(station.label || ""); path = String(station.path || "") } catch (e) {}
    if (path === "") { root.cliampNote = "Couldn't start that entry."; return }
    root.cliampNote = "Loading " + label + "…"
    cliampCall("track.play", { track: { title: label, path: path, stream: true, realtime: true } }, function(res) {
      if (res === null) {
        root.cliampNote = "Couldn't start " + label + "."
        return
      }
      root.cliampNote = ""
      refreshCliampTab()
    })
  }
  function runSearch() {
    var q = root.searchQuery.trim()
    root.dbg("runSearch q=" + q + " busy=" + root.searchBusy)
    if (q === "" || root.searchBusy) return
    root.searchBusy = true
    root.searchRows = []
    root.cliampNote = "Searching…"
    cliampCall("provider.search", { provider: "radio", query: q, offset: 0, limit: 20 }, function(res) {
      root.dbg("search callback res=" + (res === null ? "null" : "ok"))
      root.searchBusy = false
      if (res === null) {
        root.cliampNote = "Search failed." + (root.lastError !== "" ? " (" + root.lastError + ")" : "")
        return
      }
      // Most-listened first (by history frequency), server order kept on ties.
      var rows = normRows(res)
      try {
        rows.sort(function(a, b) {
          var ca = root.playCounts[root.normKey(a.label)] || 0
          var cb = root.playCounts[root.normKey(b.label)] || 0
          return cb - ca
        })
      } catch (e) {}
      root.searchRows = rows
      root.cliampNote = rows.length === 0 ? ("No results for '" + q + "'.") : (rows.length + (rows.length === 1 ? " result." : " results."))
    })
  }
  function playSearchRow(row) {
    var ref = null
    try { ref = row.ref } catch (e) {}
    if (!ref) { root.cliampNote = "Couldn't start that entry."; return }
    root.cliampNote = "Loading " + row.label + "…"
    cliampCall("track.play", { track: ref }, function(res) {
      if (res === null) {
        root.cliampNote = "Couldn't start that entry."
        return
      }
      root.cliampNote = ""
      refreshCliampTab()
    })
  }
  function startCliampDaemon(cb) {
    root.cliampNote = "Starting cliamp…"
    if (root.bar) root.bar.run("setsid cliamp -d")
    var tries = 0
    var wait = function() {
      runCmd(["cliamp", "remote", "state"], function(out) {
        var up = false
        try { up = !!(JSON.parse(out) || {}).ok } catch (e) {}
        if (up) {
          root.cliampNote = ""
          refreshCliampTab()
          if (cb) cb()
        } else if (++tries < 10) {
          defer(wait)
        } else {
          root.cliampNote = "cliamp didn't start."
        }
      })
    }
    defer(wait)
  }

  // ---- bar visualizer style (selectable, persisted) ----
  readonly property var visualStyles: [
    { id: "wave", label: "Wave" },
    { id: "bars", label: "Bars" },
    { id: "bloom", label: "Bloom" },
    { id: "blocks", label: "Blocks" },
    { id: "dots", label: "Dots" },
    { id: "blob", label: "Blob" },
    { id: "radar", label: "Radar" },
    { id: "tide", label: "Tide" },
    { id: "stars", label: "Stars" },
    { id: "flame", label: "Flame" },
    { id: "aurora", label: "Aurora" },
    { id: "spikes", label: "Spikes" },
    { id: "orbit", label: "Orbit" },
    { id: "particles", label: "Particles" },
    { id: "confetti", label: "Confetti" },
    { id: "pulse", label: "Pulse" },
    { id: "equalizer", label: "Equalizer" },
    { id: "waveform", label: "Waveform" }
  ]
  property string visualStyle: "blocks"
  function visualStyleValid(id) {
    for (var i = 0; i < visualStyles.length; i++)
      if (visualStyles[i].id === id) return true
    return false
  }
  function settingsPath() {
    try { return (Quickshell.env("HOME") || "") + "/.config/omarchy/mystaryo.media.json" } catch (e) { return "" }
  }
  function loadSettings() {
    var p = settingsPath()
    if (p === "") return
    runCmd(["python3", "-c", "import sys; p=sys.argv[1];\ntry:\n print(open(p).read())\nexcept Exception:\n print('{}')", p], function(out) {
      try {
        var j = JSON.parse(out)
        if (!j) return
        if (typeof j.visualStyle === "string" && visualStyleValid(j.visualStyle)) {
          root.visualStyle = j.visualStyle
          try { vizCanvas.requestPaint() } catch (e) {}
        }
        if (typeof j.musicPlayer === "string" && j.musicPlayer !== "") {
          root.musicPlayerPref = j.musicPlayer.toLowerCase()
        }
      } catch (e) {}
    })
  }
  function saveSettings() {
    var p = settingsPath()
    if (p === "") return
    runCmd(["python3", "-c", "import json,os,sys; p=sys.argv[1]; s=sys.argv[2]; m=sys.argv[3];\nd={}\ntry:\n d=json.load(open(p))\nexcept Exception:\n d={}\nif not isinstance(d, dict):\n d={}\nd['visualStyle']=s;\nd['musicPlayer']=m;\nos.makedirs(os.path.dirname(p), exist_ok=True);\nopen(p,'w').write(json.dumps(d))", p, root.visualStyle, root.musicPlayerPref], null)
  }
  function saveMusicPlayer() {
    saveSettings()
  }
  function setVisualStyle(id) {
    if (!visualStyleValid(id) || root.visualStyle === id) return
    root.visualStyle = id
    saveSettings()
    try { vizCanvas.requestPaint() } catch (e) {}
  }
  function cycleVisualStyle() {
    var idx = 0
    for (var i = 0; i < visualStyles.length; i++)
      if (visualStyles[i].id === root.visualStyle) idx = i
    setVisualStyle(visualStyles[(idx + 1) % visualStyles.length].id)
  }

  // ---- bar presence: spectrum on a stock WidgetButton ----
  // The strip IS a WidgetButton (same as mystaryo.menu and every stock
  // widget), so border/cursor/hover-pill/click routing all behave exactly
  // like the others. The canvas floats above its blank label and never
  // touches mouse input, so hover and clicks fall through to the button.
  implicitWidth: root.cavaDead ? 24 : vizCanvas.width + Style.space(8)
  implicitHeight: barSize
  // Tooltip gate the shell's Bar machinery reads (kept for showTooltip parity).
  readonly property bool tooltipHovered: stripButton.tooltipHovered
  onBarChanged: { if (stripButton.bar !== root.bar) stripButton.bar = root.bar }

  WidgetButton {
    id: stripButton
    anchors.fill: parent
    bar: root.bar
    text: " "
    tooltipText: root.selectedPlayer ? ((root.selectedPlayer.trackTitle || "Unknown title") + (root.selectedPlayer.trackArtist ? " — " + root.selectedPlayer.trackArtist : "")) : "Media"
    onPressed: function(button) { root.barPress(button) }
  }

  Visualizer {
    id: vizCanvas
    anchors.centerIn: parent
    width: 76
    height: parent.height
    visible: !root.cavaDead
    dead: root.cavaDead
    barValues: root.barValues
    barCount: root.barCount
    barMax: root.barMax
    foreground: root.bar.barForeground
    visualStyle: root.visualStyle
  }
  Text {
    anchors.centerIn: parent
    visible: root.cavaDead
    text: "♪"
    color: root.bar.barForeground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.body
  }
  // Single click router used by the strip button: right-click cycles the
  // visual, left toggles the card.
  function barPress(button) {
    if (button === Qt.RightButton) {
      cycleVisualStyle()
      return
    }
    // Capture the widget's screen position so the card opens below it.
    try {
      var p = root.mapToGlobal(root.width / 2, root.height)
      root.cardX = p.x
      root.cardY = p.y
    } catch (e) {}
    root.tabIndex = (root.selectedPlayer && (root.selectedPlayer.isPlaying || root.selectedPlayer.trackTitle)) ? 0 : 1
    if (root.tabIndex === 1) refreshCliampTab()
    root.popupOpen = !root.popupOpen
  }

  // ---- popup: fullscreen transparent PanelWindow (stock menu pattern) ----
  // An xdg-popup card never reliably owns keyboard focus, which forced the
  // move-mouse-out-to-type dance. Exclusive keyboard focus fixes it: while
  // open, keystrokes always reach the popup's catcher. Outside-click still
  // dismisses via the scrim.
  PanelWindow {
    id: popupPanel
    visible: root.popupOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    screen: root.barScreen
    WlrLayershell.namespace: "mystaryo-media"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // scrim: click anywhere outside the card dismisses
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: 348
      height: Math.min(col.implicitHeight + Style.space(20), popupPanel.height - root.height - Style.space(48))
      // Dock below the widget; clamp into the screen; flip above if the bar
      // sits at the bottom. Falls back to the old top-right dock when the
      // anchor wasn't captured (shouldn't happen — set on every open click).
      x: {
        var sw = 0
        try { sw = root.barScreen ? root.barScreen.width : 0 } catch (e) {}
        if (root.cardX < 0 || !(sw > 0)) return sw > 0 ? Math.round(sw - card.width - Style.gapsOut) : 0
        return Math.round(Math.max(Style.gapsOut, Math.min(root.cardX - card.width / 2, sw - card.width - Style.gapsOut)))
      }
      y: {
        var sh = 0
        try { sh = root.barScreen ? root.barScreen.height : 0 } catch (e) {}
        var below = (root.cardY < 0 ? root.height : root.cardY) + Style.gapsOut
        if (sh > 0 && below + card.height > sh) {
          var above = (root.cardY < 0 ? sh : root.cardY) - Style.gapsOut - card.height
          if (above >= Style.gapsOut) return Math.round(above)
        }
        return Math.round(below)
      }
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.space(10)

      MouseArea { anchors.fill: parent; onClicked: {} } // swallow: not a dismiss

      Column {
        id: col
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(8)

      // Popup-side catcher: covers the case where keyboard focus moves into
      // the popup window. Shares handleKey with the bar-side catcher.
      Item {
        id: keyCatcher
        width: 0
        height: 0
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event) }
      }

      // tab switcher: two text tabs plus a gear tab for settings
      Row {
        width: parent.width
        spacing: Style.space(6)
        property real tabBox: (width - spacing * 2 - nowPlayingBtn.implicitHeight) / 2
        Rectangle {
          width: parent.tabBox
          height: nowPlayingBtn.implicitHeight
          radius: Style.cornerRadius
          color: root.tabIndex === 0 ? Color.popups.border : "transparent"
          border.color: Color.popups.border
          border.width: root.tabIndex === 0 ? 0 : 1
          Button {
            id: nowPlayingBtn
            anchors.fill: parent
            iconText: ""
            text: "Now Playing"
            leftAlign: true
            foreground: root.tabIndex === 0 ? Color.popups.background : root.bar.foreground
            opacity: root.tabIndex === 0 ? 1.0 : 0.8
            onClicked: root.tabIndex = 0
          }
        }
        Rectangle {
          width: parent.tabBox
          height: cliampBtn.implicitHeight
          radius: Style.cornerRadius
          color: root.tabIndex === 1 ? Color.popups.border : "transparent"
          border.color: Color.popups.border
          border.width: root.tabIndex === 1 ? 0 : 1
          Button {
            id: cliampBtn
            anchors.fill: parent
            iconText: ""
            text: "cliamp"
            leftAlign: true
            foreground: root.tabIndex === 1 ? Color.popups.background : root.bar.foreground
            opacity: root.tabIndex === 1 ? 1.0 : 0.8
            onClicked: {
              root.tabIndex = 1
              refreshCliampTab()
              try { keyCatcher.forceActiveFocus() } catch (e) {}
            }
          }
        }
        Rectangle {
          width: nowPlayingBtn.implicitHeight
          height: nowPlayingBtn.implicitHeight
          radius: Style.cornerRadius
          color: root.tabIndex === 2 ? Color.popups.border : "transparent"
          border.color: Color.popups.border
          border.width: root.tabIndex === 2 ? 0 : 1
          Button {
            anchors.fill: parent
            iconText: ""
            iconSize: Style.font.body
            foreground: root.tabIndex === 2 ? Color.popups.background : root.bar.foreground
            opacity: root.tabIndex === 2 ? 1.0 : 0.8
            onClicked: root.tabIndex = 2
          }
        }
      }

      // ---- Tab 0: now playing, follows the *selected* player ----
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.tabIndex === 0

        // player switcher
        Row {
          width: parent.width
          spacing: Style.space(4)
          visible: root.sourcePlayers.length > 1
          Repeater {
            model: root.sourcePlayers
            Button {
              iconText: ""
              text: root.shortLabel(modelData)
              foreground: root.bar.foreground
              opacity: (root.selectedPlayer === modelData) ? 1.0 : 0.55
              onClicked: root.selectPlayer(modelData)
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            width: 48; height: 48
            radius: 6
            color: Qt.darker(root.bar.foreground, 2.2)
            clip: true
            Image {
              anchors.fill: parent
              source: root.selectedPlayer ? (root.selectedPlayer.trackArtUrl || "") : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              visible: source !== ""
              onStatusChanged: if (status === Image.Error) source = ""
            }
            Text {
              anchors.centerIn: parent
              visible: !root.selectedPlayer || !root.selectedPlayer.trackArtUrl
              text: "♪"
              color: root.bar.foreground
              opacity: 0.5
              font.pixelSize: Style.font.iconLarge
            }
          }

          Column {
            width: parent.width - 48 - parent.spacing
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              color: root.bar.foreground
              text: {
                if (!root.selectedPlayer) return "Nothing playing"
                return root.selectedPlayer.trackTitle || "Unknown title"
              }
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: Qt.darker(root.bar.foreground, 1.3)
              visible: text !== ""
              text: root.selectedPlayer && root.selectedPlayer.trackArtist ? root.selectedPlayer.trackArtist : ""
            }
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)
          Button {
            iconText: ""
            iconSize: Style.font.iconLarge
            foreground: root.bar.foreground
            enabled: root.canStep(root.selectedPlayer, -1)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.stepPlayer(root.selectedPlayer, -1)
          }
          Button {
            iconText: root.selectedPlayer && root.selectedPlayer.isPlaying ? "" : ""
            iconSize: Style.font.iconLarge
            foreground: root.bar.foreground
            enabled: root.canToggle(root.selectedPlayer)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.togglePlayer(root.selectedPlayer)
          }
          Button {
            iconText: ""
            iconSize: Style.font.iconLarge
            foreground: root.bar.foreground
            enabled: root.canStep(root.selectedPlayer, 1)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.stepPlayer(root.selectedPlayer, 1)
          }
          Button {
            iconText: ""
            iconSize: Style.font.iconLarge
            foreground: root.bar.foreground
            enabled: root.canToggle(root.selectedPlayer)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.stopPlayer(root.selectedPlayer)
          }
        }
      }

      // ---- Tab 1: cliamp ----
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.tabIndex === 1

        // now-playing header: toggle shows pause while playing, play while paused
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.cliampUp
          Button {
            id: cliampToggle
            iconText: root.cliampPlaying() ? "" : ""
            iconSize: Style.font.iconLarge
            foreground: root.bar.foreground
            onClicked: root.toggleCliamp()
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width - cliampToggle.width - parent.spacing
            elide: Text.ElideRight
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            color: root.bar.foreground
            anchors.verticalCenter: parent.verticalCenter
            text: root.cliampTrack !== "" ? root.cliampTrack : ("cliamp " + root.cliampState)
          }
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Qt.darker(root.bar.foreground, 1.3)
          visible: !root.cliampUp
          text: "cliamp daemon not running."
        }
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.cliampUp
          Button {
            iconText: ""
            text: "Start cliamp"
            foreground: root.bar.foreground
            onClicked: startCliampDaemon()
          }
          Button {
            iconText: ""
            text: "Open cliamp"
            foreground: root.bar.foreground
            onClicked: if (root.bar) root.bar.run("xdg-terminal-exec --app-id=org.omarchy.cliamp -e cliamp")
          }
        }

        // search row: field + Search button (transport lives in the header)
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.cliampUp
          Rectangle {
            width: parent.width - searchBtn.width - parent.spacing
            height: Math.max(searchText.implicitHeight, Style.font.bodySmall) + Style.space(8)
            radius: 6
            color: "transparent"
            border.color: Qt.darker(root.bar.foreground, 1.6)
            border.width: 1
            Text {
              id: searchText
              anchors.fill: parent
              anchors.margins: Style.space(4)
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              color: root.searchQuery !== "" ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.8)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              clip: true
              elide: Text.ElideRight
              text: root.searchQuery !== "" ? (root.searchQuery + (root.cursorOn ? "▌" : "")) : ((root.cursorOn ? "▌" : "") + "Type to search stations…")
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.IBeamCursor
              onClicked: {
                try { keyCatcher.forceActiveFocus() } catch (e) {}
                root.tabIndex = 1
              }
            }
          }
          Button {
            id: searchBtn
            iconText: ""
            iconSize: Style.font.body
            foreground: root.bar.foreground
            enabled: !root.searchBusy
            opacity: enabled ? 1.0 : 0.5
            onClicked: {
              try { keyCatcher.forceActiveFocus() } catch (e) {}
              try { root.runSearch() } catch (e2) { root.searchBusy = false; root.cliampNote = "Search failed." }
            }
          }
        }

        // station list: search results when searching, else the fixed top-12.
        // scrollable when overflowing.
        Flickable {
          width: parent.width
          height: Math.min(stationList.implicitHeight, Style.space(380))
          contentWidth: width
          contentHeight: stationList.implicitHeight
          clip: true
          flickableDirection: Flickable.VerticalFlick
          visible: root.cliampUp
          Column {
            id: stationList
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.searchQuery.trim() !== "" ? root.searchRows : []
              Button {
                iconText: "⏵"
                width: stationList.width
                leftAlign: true
                text: (modelData ? modelData.label : "")
                foreground: root.bar.foreground
                onClicked: root.playSearchRow(modelData)
              }
            }
            Text {
              textFormat: Text.PlainText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.bar.foreground, 1.4)
              visible: root.searchQuery.trim() !== "" && root.searchRows.length === 0 && root.cliampNote === ""
              text: "Type a name or country, then Search."
            }

            Text {
              textFormat: Text.PlainText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.bar.foreground, 1.4)
              visible: root.searchQuery.trim() === ""
              text: "Top 12 streams"
            }
            Repeater {
              model: root.searchQuery.trim() === "" ? root.topStations : []
              Button {
                iconText: ""
                width: stationList.width
                leftAlign: true
                text: ((index + 1) + ".  " + (modelData && modelData.label ? modelData.label : ""))
                foreground: root.bar.foreground
                onClicked: root.playStation(modelData)
              }
            }
          }
        }

        Button {
          iconText: ""
          text: "✕ Clear search"
          foreground: root.bar.foreground
          opacity: 0.7
          visible: root.cliampUp && root.searchQuery.trim() !== ""
          onClicked: {
            root.searchQuery = ""
            root.searchRows = []
            root.cliampNote = ""
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.bar.foreground, 1.4)
          visible: root.cliampNote !== ""
          text: root.cliampNote
        }
      }

      // ---- Tab 2: settings (bar visual styles) ----
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.tabIndex === 2
        Text {
          textFormat: Text.PlainText
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.bar.foreground, 1.4)
          text: "Bar visual (right-click bar also cycles)"
        }
        Grid {
          width: parent.width
          columns: 3
          spacing: Style.space(6)
          Repeater {
            model: root.visualStyles
            Button {
              width: (parent.width - parent.spacing * 2) / 3
              text: modelData.label
              leftAlign: true
              selected: root.visualStyle === modelData.id
              foreground: root.bar.foreground
              onClicked: root.setVisualStyle(modelData.id)
            }
          }
        }
        Text {
          textFormat: Text.PlainText
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.bar.foreground, 1.4)
          text: "Music player"
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.bar.foreground, 1.6)
          text: "Now Playing follows this app. Auto follows whichever player is active — pick one to lock it in."
        }
        Flickable {
          width: parent.width
          height: Math.min(playerList.implicitHeight, Style.space(220))
          contentWidth: width
          contentHeight: playerList.implicitHeight
          clip: true
          flickableDirection: Flickable.VerticalFlick
          Column {
            id: playerList
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.musicPlayerOptions
              Button {
                width: parent.width
                text: modelData.label
                leftAlign: true
                selected: root.musicPlayerPref === modelData.id
                foreground: root.bar.foreground
                onClicked: root.setMusicPlayer(modelData.id)
              }
            }
          }
        }
      }
    }
  }
  }
}
