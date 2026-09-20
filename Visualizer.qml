import QtQuick

// Audio spectrum canvas for mystaryo.media. Renders one of the styles in
// `styles` (wave by default) from the cava bar values fed via `barValues`.
//
// Inputs: barValues (0..barMax per bin), barCount, barMax, foreground
// (theme color), visualStyle id, dead (audio pipeline down).
// Everything animation-related lives here: the 50ms motion clock, the
// per-style state fields, and the level helpers. Styles degrade to wave
// on any paint error, so a bad frame can never crash the bar.
Canvas {
  id: viz

  readonly property var styles: [
    "wave", "bars", "bloom", "blocks", "dots", "blob",
    "radar", "tide", "stars", "flame", "aurora", "spikes",
    "orbit", "particles", "confetti", "pulse", "equalizer", "waveform"
  ]

  property var barValues: []
  property int barCount: 12
  property int barMax: 7
  property color foreground: "transparent"
  property string visualStyle: "wave"
  property bool dead: false

  // Animation clock (seconds) for the motion styles.
  property real phase: 0
  // Per-style scratch state, lazily seeded by the painters that need it.
  property var particles: []
  property var peaks: []
  property real pulseEnv: 0
  property real pulseFlash: 0
  property real pulseLastBeat: -10
  property var waveHist: []

  onBarValuesChanged: viz.requestPaint()
  onVisualStyleChanged: viz.requestPaint()

  // Motion clock (~60fps) for the motion styles: cava-fed styles repaint on
  // each audio frame; the others keep animating in silence.
  Timer {
    interval: 16
    repeat: true
    running: viz.visible && !viz.dead
    onTriggered: {
      viz.phase += 0.05
      var s = viz.visualStyle
      if (s === "particles" || s === "blob" || s === "pulse" || s === "confetti"
          || s === "equalizer" || s === "stars" || s === "aurora" || s === "orbit"
          || s === "flame" || s === "waveform" || s === "dots" || s === "bloom"
          || s === "tide")
        viz.requestPaint()
    }
  }

  // Normalized 0..1 level for bin i. The source is full-scale and cava's
  // autosens already spans the 0..barMax range, so NO extra display gain.
  // A 0.7 power curve lifts the mids (where the groove lives) without
  // touching the ceiling — more visible bounce, same headroom.
  function level(i) {
    try {
      var f = Math.min(1, (barValues[i] || 0) / barMax)
      return Math.pow(f, 0.7)
    } catch (e) { return 0 }
  }
  function average() {
    var sum = 0
    for (var i = 0; i < barCount; i++) sum += level(i)
    return sum / Math.max(1, barCount)
  }
  function bassLevel() {
    try { return (level(0) + level(1) + level(2)) / 3 } catch (e) { return 0 }
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, width, height)
    var vals = barValues
    if (!vals || vals.length < 2) return
    try {
      if (visualStyle === "bars") paintBars(ctx)
      else if (visualStyle === "bloom") paintBloom(ctx)
      else if (visualStyle === "blocks") paintBlocks(ctx)
      else if (visualStyle === "dots") paintDots(ctx)
      else if (visualStyle === "blob") paintBlob(ctx)
      else if (visualStyle === "radar") paintRadar(ctx)
      else if (visualStyle === "tide") paintTide(ctx)
      else if (visualStyle === "stars") paintStars(ctx)
      else if (visualStyle === "flame") paintFlame(ctx)
      else if (visualStyle === "aurora") paintAurora(ctx)
      else if (visualStyle === "spikes") paintSpikes(ctx)
      else if (visualStyle === "orbit") paintOrbit(ctx)
      else if (visualStyle === "particles") paintParticles(ctx)
      else if (visualStyle === "confetti") paintConfetti(ctx)
      else if (visualStyle === "pulse") paintPulse(ctx)
      else if (visualStyle === "equalizer") paintEqualizer(ctx)
      else if (visualStyle === "waveform") paintWaveform(ctx)
      else paintWave(ctx)
    } catch (e) { try { paintWave(ctx) } catch (e2) {} }
  }

  // The original smooth wave ribbon (default style).
  function paintWave(ctx) {
    var n = barCount
    var mid = height / 2
    var amp = (height / 2) - 1.5
    var top = [{ x: 1, y: mid }]
    for (var i = 0; i < n; i++) {
      var f = level(i)
      top.push({ x: 1 + (width - 2) * (i / (n - 1)), y: mid - amp * f })
    }
    top.push({ x: width - 1, y: mid })
    // Mirrored bottom half, traced back right-to-left.
    var bottom = []
    for (var j = top.length - 1; j >= 0; j--)
      bottom.push({ x: top[j].x, y: 2 * mid - top[j].y })

    ctx.beginPath()
    ctx.moveTo(top[0].x, top[0].y)
    for (var k = 1; k < top.length - 1; k++) {
      var xc = (top[k].x + top[k + 1].x) / 2
      var yc = (top[k].y + top[k + 1].y) / 2
      ctx.quadraticCurveTo(top[k].x, top[k].y, xc, yc)
    }
    ctx.lineTo(top[top.length - 1].x, top[top.length - 1].y)
    for (var m = 1; m < bottom.length - 1; m++) {
      var xb = (bottom[m].x + bottom[m + 1].x) / 2
      var yb = (bottom[m].y + bottom[m + 1].y) / 2
      ctx.quadraticCurveTo(bottom[m].x, bottom[m].y, xb, yb)
    }
    ctx.closePath()
    ctx.globalAlpha = 0.45
    ctx.fillStyle = foreground
    ctx.fill()
    ctx.globalAlpha = 1.0
    ctx.lineWidth = 1.6
    ctx.strokeStyle = foreground
    ctx.stroke()
  }

  // Classic mirrored bars.
  function paintBars(ctx) {
    var n = barCount
    var mid = height / 2
    var amp = (height / 2) - 1.5
    var slot = (width - 2) / n
    var bw = Math.max(1.5, slot * 0.55)
    ctx.fillStyle = foreground
    for (var i = 0; i < n; i++) {
      var h = Math.max(1, amp * level(i))
      var x = 1 + slot * i + (slot - bw) / 2
      ctx.globalAlpha = 0.9
      ctx.fillRect(x, mid - h, bw, h * 2)
    }
    ctx.globalAlpha = 1.0
  }

  // Bloom: a slow-turning flower whose petals stretch with the music.
  function paintBloom(ctx) {
    var cx = width / 2
    var cy = height / 2
    var maxR = Math.min(width, height) / 2 - 1
    var petals = 12
    ctx.fillStyle = foreground
    for (var i = 0; i < petals; i++) {
      var a = (i / petals) * Math.PI * 2 + phase * 0.12
      var f = level(i % barCount)
      var len = 2 + maxR * (0.35 + 0.65 * f)
      var wdt = 1.2 + 1.6 * f
      ctx.save()
      ctx.translate(cx, cy)
      ctx.rotate(a)
      ctx.scale(2.0, 1)
      ctx.globalAlpha = 0.30 + 0.60 * f
      ctx.beginPath()
      ctx.arc(len / 2, 0, len / 2, 0, Math.PI * 2)
      ctx.fill()
      ctx.restore()
    }
    // glowing heart breathing with the average
    ctx.globalAlpha = 0.85
    ctx.beginPath()
    ctx.arc(cx, cy, 1.6 + average() * 2.2, 0, Math.PI * 2)
    ctx.fill()
    ctx.globalAlpha = 1.0
  }

  // Segmented LED ladder, mirrored around the center line.
  function paintBlocks(ctx) {
    var n = barCount
    var mid = height / 2
    var amp = (height / 2) - 1.5
    var slot = (width - 2) / n
    var bw = Math.max(1.5, slot * 0.55)
    var segH = 2.4
    var gap = 1.1
    var segs = Math.max(1, Math.floor(amp / (segH + gap)))
    ctx.fillStyle = foreground
    for (var i = 0; i < n; i++) {
      var lit = Math.round(level(i) * segs)
      var x = 1 + slot * i + (slot - bw) / 2
      for (var s = 0; s < segs; s++) {
        if (s >= lit) break
        ctx.globalAlpha = 0.35 + 0.65 * (s / Math.max(1, segs - 1))
        var y0 = mid - (s + 1) * (segH + gap) + gap
        ctx.fillRect(x, y0, bw, segH)
        ctx.fillRect(x, 2 * mid - y0 - segH, bw, segH)
      }
    }
    ctx.globalAlpha = 1.0
  }

  // Mirrored bouncing dots on a faint center line. Sized for a short bar
  // strip: big radii so motion reads at a glance, plus a gentle idle bob
  // so silence still looks alive (bob fades out as real levels take over).
  function paintDots(ctx) {
    var n = barCount
    var mid = height / 2
    var amp = (height / 2) - 2
    ctx.globalAlpha = 0.4
    ctx.fillStyle = foreground
    ctx.fillRect(1, mid - 0.75, width - 2, 1.5)
    for (var i = 0; i < n; i++) {
      var f = level(i)
      var idle = Math.sin(phase * 2 + i * 0.9) * (1 - Math.min(1, f * 1.5)) * 1.6
      var x = 1 + (width - 2) * (n === 1 ? 0.5 : (i / (n - 1)))
      var y = mid - amp * f + idle
      var r = 1.5 + 4.5 * f
      ctx.globalAlpha = 1.0
      ctx.beginPath()
      ctx.arc(x, y, r, 0, Math.PI * 2)
      ctx.fill()
      ctx.globalAlpha = 0.65
      ctx.beginPath()
      ctx.arc(x, 2 * mid - y, Math.max(1, r * 0.65), 0, Math.PI * 2)
      ctx.fill()
    }
    ctx.globalAlpha = 1.0
  }

  // Organic blob: radial wobble driven by the spectrum.
  function paintBlob(ctx) {
    var n = barCount
    var cx = width / 2
    var cy = height / 2
    var base = Math.max(2, Math.min(width, height) / 2 - 2.5)
    var pts = []
    var steps = 24
    for (var s = 0; s < steps; s++) {
      var a = (s / steps) * Math.PI * 2
      var bin = Math.floor(((s / steps) * n)) % n
      var wobble = level(bin) * base * 0.55
      // Gentle idle breathing so it never fully freezes in silence.
      wobble += Math.sin(phase * 2 + s * 1.3) * base * 0.06
      var r = base * 0.55 + wobble
      pts.push({ x: cx + Math.cos(a) * r * 1.6, y: cy + Math.sin(a) * r })
    }
    ctx.beginPath()
    ctx.moveTo((pts[0].x + pts[steps - 1].x) / 2, (pts[0].y + pts[steps - 1].y) / 2)
    for (var k = 0; k < steps; k++) {
      var p = pts[k]
      var q = pts[(k + 1) % steps]
      ctx.quadraticCurveTo(p.x, p.y, (p.x + q.x) / 2, (p.y + q.y) / 2)
    }
    ctx.closePath()
    ctx.globalAlpha = 0.4
    ctx.fillStyle = foreground
    ctx.fill()
    ctx.globalAlpha = 1.0
    ctx.lineWidth = 1.4
    ctx.strokeStyle = foreground
    ctx.stroke()
  }

  // Reactive particles: drift always, energize with the music.
  function paintParticles(ctx) {
    var avg = average()
    if (!particles || particles.length === 0) {
      var seed = []
      for (var i = 0; i < 42; i++) {
        seed.push({
          x: Math.random(), y: Math.random(),
          vx: (Math.random() - 0.5) * 0.02, vy: (Math.random() - 0.5) * 0.02,
          r: 0.6 + Math.random() * 1.4
        })
      }
      particles = seed
    }
    var ps = particles
    var energy = 0.4 + avg * 2.2
    ctx.fillStyle = foreground
    for (var k = 0; k < ps.length; k++) {
      var p = ps[k]
      p.x += p.vx * energy
      p.y += p.vy * energy
      if (p.x < 0) p.x += 1
      if (p.x > 1) p.x -= 1
      if (p.y < 0) p.y += 1
      if (p.y > 1) p.y -= 1
      ctx.globalAlpha = 0.25 + Math.min(0.75, avg * 1.2)
      ctx.beginPath()
      ctx.arc(p.x * width, p.y * height, p.r * (0.7 + avg), 0, Math.PI * 2)
      ctx.fill()
    }
    ctx.globalAlpha = 1.0
  }

  // Pulse: a tile grid that shatters outward on every kick. A smoothed
  // bass envelope keeps tiles jittering between hits; each detected beat
  // fires a flash that bursts them outward, then they settle back.
  // No circles, no lines — only bouncing tiles.
  function paintPulse(ctx) {
    var bass = bassLevel()
    var env = pulseEnv || 0
    env += (bass - env) * (bass > env ? 0.6 : 0.10)
    pulseEnv = env
    // Beat flash with cooldown so kicks emit one clean burst each.
    var flash = pulseFlash || 0
    if (bass > 0.5 && (phase - pulseLastBeat) > 0.3) {
      pulseLastBeat = phase
      flash = 1
    }
    flash *= 0.86
    pulseFlash = flash
    var cols = 12
    var rows = 3
    var cw = (width - 2) / cols
    var ch = height / rows
    ctx.fillStyle = foreground
    for (var c = 0; c < cols; c++) {
      for (var r = 0; r < rows; r++) {
        var f = level((c + r) % barCount)
        var jump = env * 3 + flash * 4 * (((c * 7 + r * 13) % 5) / 4)
        var dx = (c - (cols - 1) / 2) * jump * 0.35
        var dy = (r - (rows - 1) / 2) * jump * 0.5
        var s = Math.max(1, Math.min(cw, ch) * 0.42 * (0.6 + 0.4 * f) + flash * 0.8)
        var x = 1 + c * cw + cw / 2 + dx - s / 2
        var y = r * ch + ch / 2 + dy - s / 2
        ctx.globalAlpha = 0.25 + 0.75 * Math.min(1, f + flash * 0.7)
        ctx.fillRect(x, y, s, s)
      }
    }
    ctx.globalAlpha = 1.0
  }

  // Circular sunburst: spectrum spokes around the center.
  function paintRadar(ctx) {
    var n = barCount
    var cx = width / 2
    var cy = height / 2
    var maxR = Math.min(width, height) / 2 - 1
    var inner = 2.5
    ctx.strokeStyle = foreground
    ctx.lineWidth = 1.2
    ctx.lineCap = "round"
    for (var i = 0; i < n; i++) {
      var a = (i / n) * Math.PI * 2 - Math.PI / 2 + phase * 0.15
      var r1 = inner
      var r2 = inner + (maxR - inner) * level(i)
      ctx.globalAlpha = 0.35 + 0.65 * level(i)
      ctx.beginPath()
      // Elliptical squash so it fits the wide strip.
      ctx.moveTo(cx + Math.cos(a) * r1 * 2.2, cy + Math.sin(a) * r1)
      ctx.lineTo(cx + Math.cos(a) * r2 * 2.2, cy + Math.sin(a) * r2)
      ctx.stroke()
    }
    ctx.globalAlpha = 0.5
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.arc(cx, cy, inner, 0, Math.PI * 2)
    ctx.stroke()
    ctx.globalAlpha = 1.0
  }

  // Tide: two slow ribbons drifting past each other, swelling with the
  // average level and rippled per-column by the spectrum.
  function paintTide(ctx) {
    var layers = 2
    ctx.fillStyle = foreground
    for (var L = 0; L < layers; L++) {
      var speed = 0.5 + L * 0.3
      var freq = (1.6 + L * 0.9) * Math.PI * 2 / width
      var amp = (height / 2 - 2) * (0.30 + 0.45 * average()) * (1 - L * 0.25)
      var mid = height / 2 + (L - 0.5) * 3
      ctx.beginPath()
      ctx.moveTo(1, mid)
      for (var x = 1; x <= width - 1; x += 2) {
        var f = level(Math.floor((x / width) * barCount) % barCount)
        var y = mid + Math.sin(x * freq + phase * speed + L * 2.4) * amp * (0.4 + 0.6 * f)
        ctx.lineTo(x, y)
      }
      ctx.lineWidth = 1.6 - L * 0.4
      ctx.globalAlpha = 0.75 - L * 0.25
      ctx.strokeStyle = foreground
      ctx.stroke()
    }
    ctx.globalAlpha = 1.0
  }

  // Stars: a twinkling field — twinkle speed follows the music, loud hits
  // flash a few into little cross sparkles.
  function paintStars(ctx) {
    var avg = average()
    var count = 36
    ctx.fillStyle = foreground
    ctx.strokeStyle = foreground
    for (var i = 0; i < count; i++) {
      var hx = Math.abs(Math.sin(i * 127.1) * 43758.5453) % 1
      var hy = Math.abs(Math.sin(i * 311.7 + 17.3) * 12543.1234) % 1
      var x = 1 + hx * (width - 2)
      var y = 1 + hy * (height - 2)
      var tw = Math.abs(Math.sin(phase * (0.8 + avg * 2.5) + i * 2.39996))
      var f = level(i % barCount)
      var a = 0.15 + 0.75 * tw * (0.35 + 0.65 * Math.max(avg, f))
      var r = 0.7 + 1.1 * tw * (0.4 + 0.6 * f)
      ctx.globalAlpha = Math.min(1, a)
      ctx.beginPath()
      ctx.arc(x, y, r, 0, Math.PI * 2)
      ctx.fill()
      if (tw > 0.93 && f > 0.45) {
        var s = r + 2.2
        ctx.globalAlpha = Math.min(1, a + 0.2)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(x - s, y); ctx.lineTo(x + s, y)
        ctx.moveTo(x, y - s); ctx.lineTo(x, y + s)
        ctx.stroke()
      }
    }
    ctx.globalAlpha = 1.0
  }

  // Twin flame spikes per column with a hot flicker — mirrored around the
  // center line so kicks punch both ways at once.
  function paintFlame(ctx) {
    var n = barCount
    var mid = height / 2
    var amp = (height / 2) - 1.5
    var slot = (width - 2) / n
    var bw = Math.max(2, slot * 0.7)
    ctx.fillStyle = foreground
    for (var i = 0; i < n; i++) {
      var f = level(i)
      var flick = 0.85 + 0.15 * Math.sin(phase * 11 + i * 2.4)
      var h = Math.max(1, amp * f * flick)
      var x = 1 + slot * i + slot / 2
      ctx.globalAlpha = 0.9
      ctx.beginPath()
      ctx.moveTo(x - bw / 2, mid)
      ctx.lineTo(x, mid - h)
      ctx.lineTo(x + bw / 2, mid)
      ctx.closePath()
      ctx.fill()
      ctx.beginPath()
      ctx.moveTo(x - bw / 2, mid)
      ctx.lineTo(x, mid + h)
      ctx.lineTo(x + bw / 2, mid)
      ctx.closePath()
      ctx.fill()
      if (f > 0.5) {
        ctx.globalAlpha = 1.0
        ctx.beginPath()
        ctx.arc(x, mid - h, 1.2, 0, Math.PI * 2)
        ctx.fill()
        ctx.beginPath()
        ctx.arc(x, mid + h, 1.2, 0, Math.PI * 2)
        ctx.fill()
      }
    }
    ctx.globalAlpha = 1.0
  }

  // Aurora: three translucent sine ribbons drifting over each other.
  function paintAurora(ctx) {
    var layers = 3
    ctx.fillStyle = foreground
    for (var L = 0; L < layers; L++) {
      var speed = 0.9 + L * 0.45
      var freq = (2.2 + L * 1.1) * Math.PI * 2 / width
      var amp = (height / 2 - 2) * (0.35 + 0.3 * average()) * (1 - L * 0.22)
      var mid = height / 2 + (L - 1) * 2
      ctx.beginPath()
      ctx.moveTo(1, height - 1)
      for (var x = 1; x <= width - 1; x += 2) {
        var f = level(Math.floor((x / width) * barCount) % barCount)
        var y = mid + Math.sin(x * freq + phase * speed + L * 2.1) * amp * (0.35 + 0.65 * f)
        ctx.lineTo(x, y)
      }
      ctx.lineTo(width - 1, height - 1)
      ctx.closePath()
      ctx.globalAlpha = 0.22 - L * 0.04
      ctx.fill()
    }
    ctx.globalAlpha = 1.0
  }

  // Tall alternating spikes with hot tips — every bin gets full vertical
  // travel, odds firing down while evens fire up.
  function paintSpikes(ctx) {
    var n = barCount
    var mid = height / 2
    var amp = (height / 2) - 1
    ctx.strokeStyle = foreground
    ctx.fillStyle = foreground
    ctx.lineWidth = 1.6
    ctx.lineCap = "round"
    for (var i = 0; i < n; i++) {
      var f = level(i)
      var x = 1 + (width - 2) * (n === 1 ? 0.5 : (i / (n - 1)))
      var h = Math.max(1.5, amp * f)
      var dir = (i % 2 === 0) ? -1 : 1
      ctx.globalAlpha = 0.35 + 0.65 * f
      ctx.beginPath()
      ctx.moveTo(x, mid)
      ctx.lineTo(x, mid + dir * h)
      ctx.stroke()
      ctx.globalAlpha = 0.9
      ctx.beginPath()
      ctx.arc(x, mid + dir * h, 1.4, 0, Math.PI * 2)
      ctx.fill()
    }
    ctx.globalAlpha = 1.0
  }

  // Orbit: rings of dots circling the center, each ring's radius breathing
  // with the music and every dot sized by its own bin. Core throbs on bass.
  function paintOrbit(ctx) {
    var cx = width / 2
    var cy = height / 2
    var maxR = Math.min(width, height) / 2 - 1
    var rings = 3
    ctx.fillStyle = foreground
    for (var r = 0; r < rings; r++) {
      var frac = (r + 1) / rings
      var rad = Math.max(2, maxR * frac * (0.55 + 0.45 * average()))
      var dots = 4 + r * 2
      for (var k = 0; k < dots; k++) {
        var a = phase * (0.8 + r * 0.35) + (k / dots) * Math.PI * 2
        var bin = (r * dots + k) % barCount
        var lv = level(bin)
        var rr = rad + lv * 2.5
        var px = cx + Math.cos(a) * rr * 2.2
        var py = cy + Math.sin(a) * rr
        ctx.globalAlpha = 0.35 + 0.65 * lv
        ctx.beginPath()
        ctx.arc(px, py, 1 + 1.6 * lv, 0, Math.PI * 2)
        ctx.fill()
      }
    }
    ctx.globalAlpha = 0.9
    ctx.beginPath()
    ctx.arc(cx, cy, 1.5 + bassLevel() * 2.5, 0, Math.PI * 2)
    ctx.fill()
    ctx.globalAlpha = 1.0
  }

  // Waveform: scrolling filled band of the recent average level, newest on
  // the right. Reads like an oscilloscope overview of the groove.
  function paintWaveform(ctx) {
    var cols = Math.max(16, Math.floor(width))
    var buf = waveHist || []
    buf.push(average())
    while (buf.length > cols) buf.shift()
    waveHist = buf
    var mid = height / 2
    var amp = (height / 2) - 1.5
    ctx.beginPath()
    ctx.moveTo(width - 1, mid)
    var i, v, x
    for (i = 0; i < buf.length; i++) {
      v = Math.min(1, buf[i] * 1.4)
      x = width - 1 - (buf.length - 1 - i)
      ctx.lineTo(x, mid - amp * v)
    }
    for (var j = buf.length - 1; j >= 0; j--) {
      v = Math.min(1, buf[j] * 1.4)
      x = width - 1 - (buf.length - 1 - j)
      ctx.lineTo(x, mid + amp * v)
    }
    ctx.closePath()
    ctx.globalAlpha = 0.4
    ctx.fillStyle = foreground
    ctx.fill()
    ctx.globalAlpha = 1.0
    ctx.lineWidth = 1.4
    ctx.strokeStyle = foreground
    ctx.stroke()
  }

  // Confetti: spinning paper bits raining through the strip — fall speed,
  // sway, size and brightness all follow the music.
  function paintConfetti(ctx) {
    var count = 26
    ctx.fillStyle = foreground
    for (var i = 0; i < count; i++) {
      var hx = Math.abs(Math.sin(i * 57.3 + 4.2) * 13921.6641) % 1
      var hy = Math.abs(Math.sin(i * 113.1 + 9.7) * 27183.9177) % 1
      var bin = i % barCount
      var f = level(bin)
      var fall = 0.06 + 0.16 * (0.3 + 0.7 * f)
      var y01 = (((hy + phase * fall) % 1) + 1) % 1
      var x = 1 + hx * (width - 2) + Math.sin(phase * 2 + i * 1.3) * 4
      var y = 1 + y01 * (height - 2)
      var s = 1.4 + 1.8 * f
      ctx.save()
      ctx.translate(x, y)
      ctx.rotate(phase * (0.5 + f) + i)
      ctx.globalAlpha = 0.3 + 0.7 * f
      ctx.fillRect(-s / 2, -s / 4, s, s / 2)
      ctx.restore()
    }
    ctx.globalAlpha = 1.0
  }

  // Equalizer: chunky full-travel bars with fast-falling peak caps.
  function paintEqualizer(ctx) {
    var n = barCount
    var mid = height / 2
    var amp = (height / 2) - 2.5
    var slot = (width - 2) / n
    var bw = Math.max(2.5, slot * 0.72)
    if (!peaks || peaks.length !== n) {
      var init = []
      for (var z = 0; z < n; z++) init.push({ v: 0, t: phase })
      peaks = init
    }
    ctx.fillStyle = foreground
    for (var i = 0; i < n; i++) {
      var f = level(i)
      var pk = peaks[i]
      var decayed = pk.v - Math.max(0, phase - pk.t) * 1.4
      if (f >= decayed) {
        pk.v = f
        pk.t = phase
      } else {
        pk.v = Math.max(f, decayed)
      }
      var h = Math.max(1.5, amp * f)
      var x = 1 + slot * i + (slot - bw) / 2
      ctx.globalAlpha = 0.9
      ctx.fillRect(x, mid - h, bw, h * 2)
      var capY = mid - amp * pk.v
      ctx.globalAlpha = 1.0
      ctx.fillRect(x - 0.5, capY - 1, bw + 1, 2)
      ctx.fillRect(x - 0.5, 2 * mid - capY - 1, bw + 1, 2)
    }
    ctx.globalAlpha = 1.0
  }
}
