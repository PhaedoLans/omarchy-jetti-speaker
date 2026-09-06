.pragma library

// Pure helpers for Jetti Speaker. Kept free of QML types so the same
// functions can be exercised directly by tests/model.test.mjs.

var ROLES = ["stereo", "left", "right", "mono"]

function safeParse(text, fallback) {
  try {
    if (typeof text !== "string" || text.length === 0 || text.length > 1048576)
      return fallback
    var value = JSON.parse(text)
    return value === null || value === undefined ? fallback : value
  } catch (e) {
    return fallback
  }
}

// Bar tooltips and labels take whatever a device calls itself, which is a
// vendor string and can contain anything at all.
function clean(value, limit) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\r\n\t]+/g, " ")
    .slice(0, limit || 60)
}

function roleLabel(role) {
  switch (role) {
  case "left": return "Left only"
  case "right": return "Right only"
  case "mono": return "Mono"
  default: return "Stereo"
  }
}

function nextRole(role) {
  var i = ROLES.indexOf(role)
  return ROLES[(i < 0 ? 0 : i + 1) % ROLES.length]
}

function enabledSpeakers(profile) {
  if (!profile || !profile.speakers) return []
  return profile.speakers.filter(function (s) { return s.enabled && s.sink })
}

// One line describing what the group is doing, for the bar tooltip.
function summary(status, profile) {
  if (!status || status.state !== "running")
    return "Jetti Speaker is off"
  var n = status.speakerCount || 0
  var names = enabledSpeakers(profile).map(function (s) { return clean(s.label, 24) })
  return n + (n === 1 ? " speaker: " : " speakers: ") + names.join(", ")
}

// The delay spread tells the user whether alignment is actually doing work.
function delaySpread(profile) {
  var list = enabledSpeakers(profile)
  if (list.length < 2) return 0
  var delays = list.map(function (s) { return Number(s.delayMs) || 0 })
  return Math.round(Math.max.apply(null, delays) - Math.min.apply(null, delays))
}

function isCalibrated(profile) {
  return enabledSpeakers(profile).some(function (s) {
    return s.measured && s.measured.heard
  })
}

function formatDelay(ms) {
  var v = Number(ms) || 0
  return (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + " ms"
}

var BANDS = ["primary", "tweeter", "bass"]

function bandLabel(band) {
  switch (band) {
  case "tweeter": return "Tweeter"
  case "bass": return "Bass"
  default: return "Primary"
  }
}

// What the role actually does to the sound, in one line, so the buttons are
// not three words the user has to guess the meaning of.
function bandHint(band, crossoverHz) {
  var hz = Math.round(Number(crossoverHz) || 0)
  switch (band) {
  case "tweeter": return "highs only, above " + hz + " Hz"
  case "bass": return "lows only, below " + hz + " Hz"
  default: return "full range, carries the bass"
  }
}

// Calibration grades how much low end a speaker has compared with the best one
// in the group. That is the "weakest speaker" signal the roles are built on.
function weaknessNote(speaker) {
  var m = speaker && speaker.measured
  if (!m || !m.heard || m.bassToMidDb === undefined || m.bassToMidDb === null)
    return ""
  if (m.suggestedBand === "tweeter")
    return "measured " + Math.round(m.weakness) + " dB less low end — suits a tweeter"
  if (m.suggestedBand === "primary")
    return "strongest low end — suits the primary"
  return ""
}

// An output that measured silent more than once is very likely not a speaker.
// A monitor can advertise audio over EDID and have no drivers behind it.
function looksDead(speaker) {
  return Number(speaker && speaker.silentRuns) >= 2
}

function deadNote(speaker) {
  var n = Number(speaker && speaker.silentRuns) || 0
  if (n < 2) return ""
  return "measured silent " + n + " times — this output may have no speakers behind it"
}

// ---------------------------------------------------------------------------
// Live level history for the output chart.

var LEVEL_HISTORY = 160

// Fold one snapshot into the rolling history, keyed by speaker. Speakers that
// come and go (a Bluetooth speaker dropping out) keep their own track rather
// than shifting everyone else's data along.
function pushLevels(history, snapshot, limit) {
  var cap = limit || LEVEL_HISTORY
  var next = {}
  var speakers = (snapshot && snapshot.speakers) || []
  for (var i = 0; i < speakers.length; i++) {
    var sp = speakers[i]
    var prior = (history && history[sp.key]) || []
    var series = prior.slice(-(cap - 1))
    series.push(Number(sp.rmsDb))
    next[sp.key] = series
  }
  return next
}

// Map a dB value onto 0..1 across the chart's range.
function levelFraction(db, floorDb) {
  var floor = Number(floorDb) || -70
  var v = Number(db)
  if (!isFinite(v)) return 0
  if (v <= floor) return 0
  if (v >= 0) return 1
  return (v - floor) / (0 - floor)
}

function formatDb(db) {
  var v = Number(db)
  if (!isFinite(v)) return "--"
  return v.toFixed(0) + " dB"
}

function suggestionDiffers(speaker) {
  var m = speaker && speaker.measured
  if (!m || !m.suggestedBand) return false
  return m.suggestedBand !== (speaker.band || "primary")
}

function formatGain(gain) {
  var v = Number(gain)
  if (!isFinite(v)) v = 1
  return Math.round(v * 100) + "%"
}

// Gain is a linear amplitude, so dB is the honest way to show a boost: 2.0 is
// "+6 dB", which means something, where "200%" invites doubling-the-loudness
// expectations it will not meet.
function gainDb(gain) {
  var v = Number(gain)
  if (!isFinite(v) || v <= 0) return "muted"
  var db = 20 * Math.log(v) / Math.LN10
  return (db >= 0 ? "+" : "") + db.toFixed(1) + " dB"
}

var GAIN_STEPS = [0.25, 0.35, 0.5, 0.7, 1.0, 1.4, 2.0, 2.8, 4.0]

function nextGain(current, direction) {
  var v = Number(current)
  if (!isFinite(v)) v = 1.0
  var i = 0
  while (i < GAIN_STEPS.length && GAIN_STEPS[i] < v - 0.001) i++
  i = Math.max(0, Math.min(GAIN_STEPS.length - 1, i + (direction >= 0 ? 1 : -1)))
  return GAIN_STEPS[i]
}

// Delay steps for tuning by ear. Fine near zero, where a few milliseconds is
// the difference between "together" and "smeared", and coarser further out
// where you are chasing a codec's buffer rather than a speaker's position.
var DELAY_STEPS = [0, 2, 5, 10, 15, 20, 30, 45, 60, 90, 130, 180, 240, 320, 420]

function nextDelay(current, direction) {
  var v = Number(current)
  if (!isFinite(v) || v < 0) v = 0
  var i = 0
  while (i < DELAY_STEPS.length && DELAY_STEPS[i] < v - 0.01) i++
  i = Math.max(0, Math.min(DELAY_STEPS.length - 1, i + (direction >= 0 ? 1 : -1)))
  return DELAY_STEPS[i]
}

// Above unity the speaker is being pushed, which is worth saying out loud.
function gainIsBoost(gain) { return (Number(gain) || 1) > 1.0001 }
