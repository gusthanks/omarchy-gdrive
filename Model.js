.pragma library

// Pure helpers for the gusthx.gdrive bar widget. No Qt types in here so the
// file can be unit-tested with plain node (see Model.test.js).

var STATES = ["mounted", "starting", "stopped", "error", "unconfigured", "unknown"]

function emptyStatus() {
  return {
    state: "unknown",
    mounted: false,
    responsive: false,
    activeState: "",
    enabled: false,
    managed: "",
    remoteExists: false,
    unitExists: false,
    ownClient: true,
    mountpoint: "",
    cacheBytes: 0,
    cacheMax: "",
    cacheMaxBytes: 0,
    pendingUploads: 0,
    lastError: ""
  }
}

// Output of `omarchy-gdrive status --json` → status object, or null when unusable.
function parseStatus(text) {
  if (!text) return null
  var obj
  try { obj = JSON.parse(String(text)) } catch (e) { return null }
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null
  var st = emptyStatus()
  for (var k in st) if (k in obj) st[k] = obj[k]
  if (STATES.indexOf(st.state) < 0) st.state = "unknown"
  st.cacheBytes = toNumber(st.cacheBytes)
  st.cacheMaxBytes = toNumber(st.cacheMaxBytes)
  st.pendingUploads = Math.max(0, Math.round(toNumber(st.pendingUploads)))
  return st
}

// Output of `omarchy-gdrive quota --json` → {total, used, free} in bytes, or null.
function parseQuota(text) {
  if (!text) return null
  var obj
  try { obj = JSON.parse(String(text)) } catch (e) { return null }
  if (!obj || typeof obj !== "object") return null
  var used = toNumber(obj.used), total = toNumber(obj.total)
  if (used <= 0 && total <= 0) return null
  return { used: used, total: total, free: toNumber(obj.free), trashed: toNumber(obj.trashed) }
}

function toNumber(v) {
  var n = Number(v)
  return isFinite(n) ? n : 0
}

// Nerd-font glyphs: md-google-drive, md-sync, md-cloud-off-outline, md-alert.
function stateIcon(state) {
  switch (state) {
    case "mounted": return "󰊶"      // md-google-drive
    case "starting": return "󰓦"     // md-sync
    case "stopped": return "󰅤"      // md-cloud-off-outline
    case "error": return "󰀦"        // md-alert
    case "unconfigured": return "󰅤" // md-cloud-off-outline
    default: return "󰊶"
  }
}

var UPLOAD_ICON = "󰅧" // md-cloud-upload

// What the bar pill shows: the state glyph, plus a pending-upload count while mounted.
function barText(st) {
  if (!st) return stateIcon("unknown")
  var icon = stateIcon(st.state)
  if (st.state === "mounted" && st.pendingUploads > 0) return icon + " " + UPLOAD_ICON + " " + st.pendingUploads
  return icon
}

// Whether the pill should use the bar's "active"/urgent colour.
function isUrgent(st) {
  return !!st && st.state === "error"
}

function percent(used, total) {
  used = toNumber(used); total = toNumber(total)
  if (total <= 0) return 0
  return Math.max(0, Math.min(100, (used / total) * 100))
}

// 1536 → "1.5 KiB". fmtNum is optional (locale-aware number formatter).
function formatBytes(bytes, decimals, fmtNum) {
  bytes = toNumber(bytes)
  if (decimals === undefined || decimals === null) decimals = 1
  var units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  var i = 0
  var v = Math.abs(bytes)
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  var d = i === 0 ? 0 : decimals
  var num = v.toFixed(d)
  if (fmtNum) num = fmtNum(Number(num), d)
  return num + " " + units[i]
}

// "/home/me/GoogleDrive" → "~/GoogleDrive"
function shortenHome(path, home) {
  path = String(path || ""); home = String(home || "")
  if (home && (path === home || path.indexOf(home + "/") === 0)) return "~" + path.slice(home.length)
  return path
}

// Safe single-quoting for a bash -c command line.
function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

// Strip anything a rich-text Text item could interpret, and clamp the length.
function neutralizeMarkup(s, max) {
  s = String(s || "").replace(/[<>&]/g, " ").replace(/\s+/g, " ").trim()
  if (max && s.length > max) s = s.slice(0, max - 1) + "…"
  return s
}
