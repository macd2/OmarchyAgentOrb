// Agent Orb — a floating wireframe orb that watches every agent session.
//
// Geometry is a port of the aiplify.io hero: IcosahedronGeometry + wireframe
// + simplex-style vertex displacement + a 4-colour iridescent gradient mapped
// over the surface normals, plus a Lambert term and a fresnel edge glow.
// Rendered with Canvas 2D (projection + edge drawing) so it also works on
// software GL (llvmpipe), where ShaderEffect does not.
//
// Colours come from the active Omarchy theme (qs.Commons) so the orb follows
// `omarchy theme set` instead of carrying its own palette.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

PanelWindow {
  id: panel
  // Panel contract: the shell drives open()/close() and reads `opened`. The bar
  // widget's click comes in through `shell toggle io.github.macd2.agent-orb`, which only
  // works if the panel actually implements these instead of pinning visible.
  property bool opened: true
  visible: opened
  function open(payloadJson) { panel.opened = true; return "ok" }
  function close() { panel.opened = false; return "ok" }
  // No box: the surface itself is transparent and only the mesh edges are
  // painted, so the orb floats free with nothing behind it.
  color: "transparent"
  // Ask the compositor for an alpha-capable surface, otherwise the
  // transparent clear below would composite as opaque black.
  surfaceFormat.opaque: false
  updatesEnabled: true
  // Window is intentionally larger than the visible tile: the mesh is drawn in
  // the middle and the canvas is cropped to the box below, so shrinking the
  // box never rescales the mesh — it just reveals less of the surround.
  implicitWidth: 150
  implicitHeight: 150
  anchors { bottom: true; left: true }
  // Bottom-left corner, clear of the bar and the screen edge.
  margins { bottom: 0; left: 0 }
  WlrLayershell.namespace: "agent-orb"
  WlrLayershell.layer: WlrLayer.Overlay
  // Hyprland only honours an interactive move (startSystemMove) on a surface
  // that is allowed keyboard focus — with None the compositor silently refuses
  // the grab, so the window never follows the cursor.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: 0
  focusable: true
  // Empty input region: nothing visible to click, so the orb must not swallow
  // clicks meant for the window underneath. This is the OSD's pattern.
  mask: Region {}

  // No mouse interaction at all: there is no box to grab and nothing to click,
  // so the surface stays purely a visual indicator.

  // ------------------------------------------------------------- agent data
  readonly property string home: Quickshell.env("HOME") || ""
  // Locate the watcher relative to this plugin so the folder is portable:
  // it works wherever the plugin is installed, no absolute paths baked in.
  // AGENT_ORB_WATCHER overrides for running from a checkout.
  readonly property string watcherScript:
      Quickshell.env("AGENT_ORB_WATCHER")
      || (home + "/.config/omarchy/plugins/io.github.macd2.agent-orb/watcher/agent-watcher.sh")
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") +
                                       "/omarchy/agent-watch/state.json"

  property var state: ({})
  property real energy: 0
  property real pop: 0
  property bool busyNow: false      // any agent actively working right now
  property real lastAt: 0
  property string lastSource: ""
  property double lastTickMs: 0
  property double clock: 0          // monotonic seconds since load
  property int frameMs: 16         // adaptive: converges on the achievable rate
  property real surge: 0            // smoothed impulse envelope (see Timer)
  property double rushPhase: 0      // continuous forward scroll of the noise field

  // The watcher is a singleton (pid lockfile) shared with the Agent Pulse bar
  // widget, which may live in a different project entirely. So this never
  // restarts blindly on exit: it re-checks whether the state file is still
  // being refreshed, and only claims the lock when nobody else is feeding it.
  property bool claimed: false

  function claimWatcher() {
    var age = Date.now() - (Number(panel.state.now) || 0)
    if (age < 20000) return          // someone else owns it and is alive
    if (panel.claimed) return
    panel.claimed = true
    watcher.running = true
  }

  Process {
    id: watcher
    running: false
    command: ["/bin/bash", panel.watcherScript]
    onExited: panel.claimed = false
  }

  Timer {
    id: watcherAdopt
    interval: 20000
    repeat: true
    running: true
    onTriggered: panel.claimWatcher()
  }

  Component.onCompleted: panel.claimWatcher()

  FileView {
    path: panel.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: panel.applyState(text())
    onLoadFailed: { }
  }

  function applyState(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "{}")) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return
    panel.state = parsed
    if (parsed.source) panel.lastSource = agentLabel(parsed.source)

    var at = Number(parsed.at) || 0
    if (at > panel.lastAt) panel.lastAt = at

    // The impulse fires on the rising edge of "some agent is working", not on
    // every file write. opencode checkpoints its sqlite WAL in bursts of up to
    // 34 writes a second while it works, and popping per write turned the orb
    // into a permanent vibration.
    var busy = false
    if (parsed.busy) {
      for (var k in parsed.busy) { if (parsed.busy[k]) { busy = true; break } }
    }
    if (busy && !panel.busyNow) panel.pop = 1
    panel.busyNow = busy
  }

  // Prefer the label the watcher publishes so the caption matches the tooltip.
  function agentLabel(id) {
    var list = (panel.state && panel.state.agents) || []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].id === id) return list[i].label || id
    }
    return id
  }

  Timer {
    interval: panel.frameMs
    repeat: true
    running: true
    onTriggered: {
      var now = Date.now()
      var dt = panel.lastTickMs > 0 ? (now - panel.lastTickMs) / 1000 : 1 / 60

      // Adaptive pacing. Asking for 60fps from a renderer that can only
      // deliver 8 does not give you 8fps — it backs the queue up and delivers
      // them in bursts, which reads as judder even though the average rate is
      // unchanged. Measured here: the orb's 196x196 canvas and the bar widget's
      // 23x23 canvas both land at ~125ms per frame, because on software GL the
      // cost is compositing the whole scene, not the drawing.
      //
      // Track the rate actually achieved rather than nudging on a threshold.
      // The earlier version grew by 25% on any spike but shrank only 7% per
      // tick, so a single hitch ratcheted the interval up and it never came
      // back: measured drifting 127 -> 146 -> 169ms, heading for the 250ms cap
      // and 4fps, which reads as frozen. The cap is now 150ms so it can never
      // fall below ~7fps, rise is bounded, and fall is an absolute step rather
      // than a percentage. On hardware GL this sits at the 16ms floor and never
      // moves.
      if (dt > 0) {
        var target = Math.min(150, Math.max(16, dt * 1000 * 1.15))
        panel.frameMs = target > panel.frameMs
          ? Math.min(target, panel.frameMs * 1.3 + 2)
          : Math.max(target, panel.frameMs - 4)
      }

      panel.lastTickMs = now
      if (dt > 0.25) dt = 0.25

      var target = 0
      if (panel.lastAt > 0) target = Math.max(0, 1 - (now - panel.lastAt) / 5000)
      // Slow rise, slow fall: energy is the ambient "how busy" level. The
      // violent part is pop, which is the one-shot impulse.
      var k = 1 - Math.pow(0.0006, dt)
      panel.energy += (target - panel.energy) * k
      // pop is the impulse envelope: full at the instant of a write, gone in
      // ~0.6s. Rounded and unhurried so the mesh breathes rather than snaps.
      if (panel.pop > 0) panel.pop = Math.max(0, panel.pop - dt / 0.60)

      // Surge is the impulse envelope the mesh actually reads, and it is
      // deliberately slower and rounder than pop: pop is a linear ramp with a
      // hard start, feeding it straight into the displacement made the surface
      // flinch. A second-order follower (fast attack, slower release) removes
      // that snap, so activity swells in and fades out without a kink.
      var want = Math.sin(Math.min(1, panel.pop) * Math.PI)
      var sk = 1 - Math.pow(want > panel.surge ? 0.00002 : 0.0009, dt)
      panel.surge += (want - panel.surge) * sk

      // The noise field is scrolled by an integrated phase rather than an
      // offset added per frame, so the surface never jumps ahead — it just
      // starts drifting forward while the burst lasts.
      panel.rushPhase += panel.surge * 0.45 * dt

      panel.clock += dt
      canvas.requestPaint()
    }
  }

  // ============================================================ the mesh
  // Clip so the oversized canvas is cropped to the window, never scaled:
  // the mesh keeps its exact pixel size while the visible box is smaller.
  Item {
    anchors.fill: parent
    clip: true

    Canvas {
      id: canvas
      width: 196
      height: 196
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      antialiasing: true

    // Palette sampled from the active Omarchy theme. Four anchors spread around
    // the hue wheel so the surface still reads as iridescent even when the
    // theme is near-monochrome.
    readonly property color paletteA: Color.accent
    readonly property color paletteB: Color.popups.border
    readonly property color paletteC: Color.notifications.countdown
    readonly property color paletteD: Color.tooltip.border

    readonly property var cA: [paletteA.r, paletteA.g, paletteA.b]
    readonly property var cB: [paletteB.r, paletteB.g, paletteB.b]
    readonly property var cC: [paletteC.r, paletteC.g, paletteC.b]
    readonly property var cD: [paletteD.r, paletteD.g, paletteD.b]
    readonly property real ambient: 0.2

    property var verts: []
    property var edges: []

    // ---- geometry: IcosahedronGeometry(1.2, subdiv) -------------------
    function initIcosphere(subdiv) {
      var t = (1.0 + Math.sqrt(5.0)) / 2.0
      var v = [
        [-1,  t,  0], [ 1,  t,  0], [-1, -t,  0], [ 1, -t,  0],
        [ 0, -1,  t], [ 0,  1,  t], [ 0, -1, -t], [ 0,  1, -t],
        [ t,  0, -1], [ t,  0,  1], [-t,  0, -1], [-t,  0,  1]
      ]
      for (var i = 0; i < v.length; i++) v[i] = norm(v[i])
      var faces = [
        [0,11,5],[0,5,1],[0,1,7],[0,7,10],[0,10,11],
        [1,5,9],[5,11,4],[11,10,2],[10,7,6],[7,1,8],
        [3,9,4],[3,4,2],[3,2,6],[3,6,8],[3,8,9],
        [4,9,5],[2,4,11],[6,2,10],[8,6,7],[9,8,1]
      ]
      var cache = {}
      function mid(a, b) {
        var key = a < b ? a + "_" + b : b + "_" + a
        if (cache[key] !== undefined) return cache[key]
        var pa = v[a], pb = v[b]
        v.push(norm([(pa[0]+pb[0])/2, (pa[1]+pb[1])/2, (pa[2]+pb[2])/2]))
        cache[key] = v.length - 1
        return cache[key]
      }
      for (var s = 0; s < subdiv; s++) {
        var next = []
        for (var f = 0; f < faces.length; f++) {
          var a = faces[f][0], b = faces[f][1], c = faces[f][2]
          var ab = mid(a,b), bc = mid(b,c), ca = mid(c,a)
          next.push([a,ab,ca],[b,bc,ab],[c,ca,bc],[ab,bc,ca])
        }
        faces = next
      }
      var seen = {}, e = []
      for (var k = 0; k < faces.length; k++) {
        var fc = faces[k]
        for (var j = 0; j < 3; j++) {
          var a2 = fc[j], b2 = fc[(j+1)%3]
          var key2 = a2 < b2 ? a2 + "_" + b2 : b2 + "_" + a2
          if (!seen[key2]) { seen[key2] = true; e.push([a2, b2]) }
        }
      }
      canvas.verts = v
      canvas.edges = e
    }

    function norm(v) {
      var l = Math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]) || 1
      return [v[0]/l, v[1]/l, v[2]/l]
    }
    function dot(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2] }
    function mix(a, b, t) {
      return [a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t, a[2]+(b[2]-a[2])*t]
    }
    // 4-Farben-Blend über die Oberfläche (iridescent)
    function iridescent(n) {
      var tx = n[0] * 0.5 + 0.5
      var ty = n[1] * 0.5 + 0.5
      return mix(mix(cA, cB, tx), mix(cC, cD, tx), ty)
    }

    // ---- 3D value noise (cheap stand-in for snoise) ------------------
    function h3(x, y, z) {
      var n = Math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453
      return n - Math.floor(n)
    }
    function noise3(x, y, z) {
      var ix = Math.floor(x), iy = Math.floor(y), iz = Math.floor(z)
      var fx = x - ix, fy = y - iy, fz = z - iz
      var ux = fx*fx*(3-2*fx), uy = fy*fy*(3-2*fy), uz = fz*fz*(3-2*fz)
      var s = 0
      for (var dz = 0; dz < 2; dz++)
        for (var dy = 0; dy < 2; dy++)
          for (var dx = 0; dx < 2; dx++) {
            var w = h3(ix+dx, iy+dy, iz+dz)
            s += w * (dx ? ux : 1-ux) * (dy ? uy : 1-uy) * (dz ? uz : 1-uz)
          }
      return s
    }
    function snoise(x, y, z) {
      return (noise3(x, y, z) * 2.0 - 1.0) +
             (noise3(x*2.03, y*2.03, z*2.03) * 2.0 - 1.0) * 0.5
    }

    Component.onCompleted: initIcosphere(2)   // 162 verts, 480 edges — finer wireframe net

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)

      var W = width, H = height
      var cx = W / 2, cy = H / 2
      var time = panel.clock
      var e = panel.energy
      var pop = panel.pop

      // ---- background: the theme's own background, vignetted --------
      // No background fill: the canvas is cleared to transparent so only the
      // mesh edges are painted.

      // ---- orbit centre: calm, slow drift ------------------------------
      // Deliberately lazy at rest. All the motion budget belongs to the impulse.
      var orbitAmp = 0.010 + 0.045 * e
      var ox = cx + Math.sin(time * 0.34) * orbitAmp * W
      var oy = cy + Math.cos(time * 0.27) * orbitAmp * H

      // ---- fixed key light (no mouse coupling) ---------------------
      var lightDir = norm([0.35, 0.55, 2.0])

      // ---- geometry: displace, rotate, project ---------------------
      // Sized to sit well inside the surface: with no opaque box, anything that
      // reaches the window edge would show up as a clipped edge.
      var radius = Math.min(W, H) * (0.30 + 0.05 * e)
      var camZ = 3.0
      // Spin rate is tied to how busy things are, so the resting orb is genuinely
      // still rather than "slowly busy". On a software-GL compositor the frame
      // rate is low, and every degree of rotation per frame is visible as a
      // step; a slower surface at rest is also what makes the active state read
      // as a change rather than as more of the same.
      var rotY = time * (0.12 + 0.24 * e)
      var rotX = time * (0.05 + 0.14 * e)
      var cy_ = Math.cos(rotY), sy = Math.sin(rotY)
      var cxr = Math.cos(rotX), sx = Math.sin(rotX)

      // ---- how alive the surface is -----------------------------------
      // Idle is a slow, low-amplitude crawl. Activity raises the amplitude and
      // adds a faster flutter, so the mesh looks like something stirring
      // rather than something being switched on.
      // Already smoothed by the Timer's follower; 0 -> 1 -> 0 with no kink.
      var surge = panel.surge * 0.5
      var dispAmp = 0.125 + 0.16 * e + 0.24 * surge

      // Two noise fields: a slow body wave and a fine skin shimmer. The shimmer
      // stays on a long wavelength and a low amplitude — it is there to keep
      // the surface from looking frozen, not to twitch.
      var skinW = 0.16 + 0.28 * e + 0.30 * surge
      var skinA = 0.020 + 0.028 * e + 0.030 * surge

      // Impulse scrolls the whole field forward in time, so a burst reads as
      // the surface rushing rather than merely brightening.
      var rush = panel.rushPhase

      var n = verts.length
      var px = new Array(n), py = new Array(n), pz = new Array(n)
      var rnx = new Array(n), rny = new Array(n), rnz = new Array(n)

      for (var i = 0; i < n; i++) {
        var v = verts[i]
        // slow body wave
        var d = snoise(v[0]*2.0 + time*0.34 + rush, v[1]*2.0 + time*0.34, v[2]*2.0 + time*0.34) * dispAmp
        // fine skin shimmer, riding on top
        d += snoise(v[0]*3.6 + time*skinW, v[1]*3.6 - time*skinW*0.7, v[2]*3.6) * skinA

        var wx = v[0] + v[0]*d
        var wy = v[1] + v[1]*d
        var wz = v[2] + v[2]*d

        // rotate around Y
        var ry1 = wx * cy_ - wz * sy
        var rz1 = wx * sy + wz * cy_
        // rotate around X
        var ry2 = ry1 * cxr - rz1 * sx
        var rz2 = ry1 * sx + rz1 * cxr
        px[i] = ry2; py[i] = wy; pz[i] = rz2

        // undisplaced normal, rotated (site uses the undisplaced normal)
        var nx = v[0], ny = v[1], nz = v[2]
        var nry = nx * cy_ - nz * sy
        var nrz = nx * sy + nz * cy_
        rnx[i] = nry; rny[i] = ny * cxr - nrz * sx; rnz[i] = ny * sx + nrz * cxr
      }

      // ---- draw edges, painter's algorithm by depth ----------------
      var edges = canvas.edges
      var order = []
      for (var k = 0; k < edges.length; k++) order.push(k)
      var depth = new Array(edges.length)
      for (var k2 = 0; k2 < edges.length; k2++) {
        var ed = edges[k2]
        depth[k2] = (pz[ed[0]] + pz[ed[1]]) * 0.5
      }
      order.sort(function(a, b) { return depth[a] - depth[b] })

      ctx.lineCap = "round"
      ctx.globalCompositeOperation = "lighter"
      for (var oi = 0; oi < order.length; oi++) {
        var idx = order[oi]
        var e2 = edges[idx]
        var a = e2[0], b = e2[1]

        // perspective projection
        var za = camZ - pz[a], zb = camZ - pz[b]
        if (!(za > 0.3) || !(zb > 0.3)) continue
        var sa = radius / za, sb = radius / zb
        var ax = ox + px[a] * sa, ay = oy - py[a] * sa
        var bx = ox + px[b] * sb, by = oy - py[b] * sb
        if (!isFinite(ax) || !isFinite(ay) || !isFinite(bx) || !isFinite(by)) continue

        // normal-based iridescent colour
        var mid = 0.5
        var mn = norm([(rnx[a]+rnx[b])*mid, (rny[a]+rny[b])*mid, (rnz[a]+rnz[b])*mid])
        var base = iridescent(mn)

        var diffuse = Math.max(0, dot(mn, lightDir))
        var fresnel = Math.pow(1 - Math.min(1, Math.abs(mn[2])), 2)
        // Keep hue: scale the palette colour by light instead of adding white,
        // otherwise bright lines clip to white and the iridescence disappears.
        var lum = canvas.ambient + diffuse * 1.35
        var glow = 0.78 + 0.50 * e + pop * 0.85
        var r = Math.min(248, Math.round(base[0] * (lum + fresnel * 0.45) * 255 * glow * 0.82))
        var g = Math.min(248, Math.round(base[1] * (lum + fresnel * 0.45) * 255 * glow * 0.82))
        var bl = Math.min(248, Math.round(base[2] * (lum + fresnel * 0.45) * 255 * glow * 0.82))

        // depth fade: far edges dimmer
        var zfade = Math.max(0, Math.min(1, (depth[idx] + 1.4) / 2.4))
        // thinner net => fewer lines would vanish, so keep alpha up but rely on
        // the narrower stroke plus additive blending to build the tone
        var alpha = (0.5 + 0.4 * zfade) * (0.72 + 0.26 * e)
        if (alpha < 0.03) continue

        ctx.strokeStyle = "rgba(" + r + "," + g + "," + bl + "," + alpha.toFixed(3) + ")"
        ctx.lineWidth = 0.5 + 0.45 * zfade
        ctx.beginPath()
        ctx.moveTo(ax, ay)
        ctx.lineTo(bx, by)
        ctx.stroke()
      }
      ctx.globalCompositeOperation = "source-over"

      // ---- impulse flash: soft bloom that swells and fades ----------
      // The canvas is deliberately larger than the window (see the clip above),
      // so the visible area is only half the window across. The halo has to be
      // kept inside that: any alpha that survives past the window edge gets
      // clipped by the compositor on a straight line, which is precisely when
      // the box becomes visible.
      var vis = Math.min(panel.width, panel.height) / 2

      if (pop > 0.01) {
        var fade = Math.sin(Math.min(1, pop) * Math.PI)
        var haloR = Math.min(radius * (1.3 + 1.1 * (1 - pop)), vis - 2)

        // impulse glow: themed, so it belongs to the palette rather than fighting it
        var acc = "rgba(" + Math.round(paletteA.r * 255) + "," +
                        Math.round(paletteA.g * 255) + "," +
                        Math.round(paletteA.b * 255) + ","
        var fg = ctx.createRadialGradient(ox, oy, 0, ox, oy, haloR)
        fg.addColorStop(0,    "rgba(255,255,255," + (fade * 0.18).toFixed(3) + ")")
        fg.addColorStop(0.32, acc + (fade * 0.11).toFixed(3) + ")")
        fg.addColorStop(0.62, acc + (fade * 0.05).toFixed(3) + ")")
        fg.addColorStop(1,    acc + "0)")
        ctx.fillStyle = fg
        ctx.beginPath()
        ctx.arc(ox, oy, haloR, 0, Math.PI * 2)
        ctx.fill()
      }

      // ---- soft edge --------------------------------------------------
      // destination-in multiplies what is already painted by this gradient's
      // alpha, so it forces every pixel out to zero regardless of what was
      // drawn or how bright. The ramp is kept to the outer tenth on purpose:
      // it has to reach exactly zero at the window border to kill the clipped
      // edge, but a wider one would start eating into the mesh, which is far
      // more visible as dimming than a faint square ever was.
      ctx.globalCompositeOperation = "destination-in"
      var edge = ctx.createRadialGradient(cx, cy, vis * 0.88, cx, cy, vis)
      edge.addColorStop(0, "rgba(0,0,0,1)")
      edge.addColorStop(1, "rgba(0,0,0,0)")
      ctx.fillStyle = edge
      ctx.fillRect(0, 0, W, H)
      ctx.globalCompositeOperation = "source-over"

      // ---- status ---------------------------------------------------
      ctx.font = "9px monospace"
      ctx.textAlign = "center"
      ctx.fillStyle = e > 0.05 ? Util.alpha(paletteA, 0.95) : Util.alpha(Color.muted, 0.7)
      ctx.fillText(e > 0.05 ? ("● " + (panel.lastSource || "agent") + " busy") : "watching agents",
                   cx, H - 12)
      }
    }
  }
}