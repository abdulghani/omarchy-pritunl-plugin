.pragma library

// One profiles.sh reading into a plain object. A reading that is not JSON
// comes back as null, so the panel can keep showing the last good one.
function parse(text) {
  var raw
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    return null
  }
  if (!raw || typeof raw !== "object") return null

  var profiles = []
  var list = raw.profiles instanceof Array ? raw.profiles : []
  for (var i = 0; i < list.length; i++) {
    var p = list[i] || {}
    if (!p.id) continue
    profiles.push({
      id: String(p.id),
      name: String(p.name || p.id),
      active: p.run_state === "Active",
      connected: p.connected === true,
      status: String(p.status || ""),
      uptime: Number(p.uptime) || 0,
      serverAddress: String(p.server_address || ""),
      clientAddress: String(p.client_address || ""),
      passwordMode: String(p.password_mode || ""),
      interface: String(p.interface || "")
    })
  }

  return {
    installed: raw.installed === true,
    profiles: profiles,
    error: String(raw.error || "")
  }
}

// Where a profile is, as one word. Connected profiles report their uptime in
// `status` rather than a state, so `connected` decides that case; a profile
// the service is running but has not connected is somewhere in between.
function phase(profile) {
  if (!profile) return "off"
  if (profile.connected) return "connected"
  var s = profile.status.toLowerCase()
  if (s === "disconnecting") return "disconnecting"
  if (!profile.active) return "off"
  if (s === "authenticating" || s === "reconnecting") return s
  return "connecting"
}

function phaseLabel(phase) {
  if (phase === "connected") return "Connected"
  if (phase === "connecting") return "Connecting…"
  if (phase === "authenticating") return "Authenticating…"
  if (phase === "reconnecting") return "Reconnecting…"
  if (phase === "disconnecting") return "Disconnecting…"
  return "Disconnected"
}

function busyPhase(phase) {
  return phase !== "off" && phase !== "connected"
}

// "1h 20m", "12m", "40s" from seconds.
function duration(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m"
  return s + "s"
}

// What a profile asks for before it connects, from the client's password
// mode. Pritunl sends a PIN and one-time code as one password, PIN first.
function credentials(mode) {
  switch (mode) {
  case "":
  case "none":
    return { username: false, fields: [] }
  case "pin":
    return { username: false, fields: [{ key: "pin", label: "PIN", secret: true }] }
  case "otp":
    return { username: false, fields: [{ key: "otp", label: "One-time code", secret: false }] }
  case "otp_pin":
    return { username: false, fields: [
      { key: "pin", label: "PIN", secret: true },
      { key: "otp", label: "One-time code", secret: false }
    ] }
  case "username":
    return { username: true, fields: [] }
  case "username_password":
    return { username: true, fields: [{ key: "password", label: "Password", secret: true }] }
  default:
    // duo, onelogin, okta, yubikey and anything newer: one passcode box
    // covers what the desktop client would prompt for.
    return { username: false, fields: [{ key: "passcode", label: "Passcode", secret: true }] }
  }
}

// Joins the filled-in fields into the single password the client sends.
function password(mode, values) {
  var fields = credentials(mode).fields
  var out = ""
  for (var i = 0; i < fields.length; i++) out += String(values[fields[i].key] || "")
  return out
}

// Output of a command run as `cmd 2>&1; echo "__exit $?"`: the exit status from
// the last line, and everything before it joined as the message.
function commandResult(output) {
  var lines = String(output || "").trim().split("\n")
  var match = /^__exit (\d+)$/.exec(lines[lines.length - 1] || "")
  return {
    status: match ? Number(match[1]) : 1,
    message: (match ? lines.slice(0, -1) : lines).join(" ").trim()
  }
}

// Every field filled in, so Connect has something to send.
function ready(mode, values, username) {
  var c = credentials(mode)
  if (c.username && !String(username || "").trim()) return false
  for (var i = 0; i < c.fields.length; i++)
    if (!String(values[c.fields[i].key] || "")) return false
  return true
}

// One traffic.sh line, "<rx_bytes> <tx_bytes> <uptime>", or null for a blank or
// garbled reading.
function trafficReading(text) {
  var f = String(text || "").trim().split(/\s+/)
  if (f.length < 3) return null
  var rx = Number(f[0])
  var tx = Number(f[1])
  var t = Number(f[2])
  if (!isFinite(rx) || !isFinite(tx) || !isFinite(t)) return null
  return { rx: rx, tx: tx, t: t }
}

// Speed in bits per second each way between two readings of the same tunnel.
// Counters that went backwards (the tunnel was torn down and rebuilt) or no
// time between the readings give null instead of a nonsense spike.
function rates(prev, cur) {
  if (!prev || !cur) return null
  var dt = cur.t - prev.t
  var down = cur.rx - prev.rx
  var up = cur.tx - prev.tx
  if (dt <= 0 || down < 0 || up < 0) return null
  return { down: down * 8 / dt, up: up * 8 / dt }
}

// "840 bps", "12.4 kbps", "3.1 Mbps", "120 Mbps" — bits, the way network speeds
// are quoted and the way Omarchy's own speed test reports them.
function bitrate(bps) {
  var v = Math.max(0, Number(bps) || 0)
  if (v < 1000) return Math.round(v) + " bps"
  var units = ["kbps", "Mbps", "Gbps"]
  var i = 0
  v /= 1000
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000
    i++
  }
  return (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + " " + units[i]
}

