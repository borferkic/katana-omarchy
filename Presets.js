.pragma library

// Equalizer presets: preamp and gain in dB for 32, 64, 125, 250, 500, 1K, 2K, 4K, 8K and 16K Hz.
// The preamp of the boosting presets takes back the headroom their boost uses, so they don't clip.
// "custom" (the one personal profile) is not listed here: it holds the user's last manual setting.
var list = [
  { key: "flat",         preamp: 0,  bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
  { key: "bassBooster",  preamp: -5, bands: [6, 5, 4, 2, 1, 0, 0, 0, 0, 0] },
  { key: "bassReducer",  preamp: 0,  bands: [-6, -5, -4, -2, -1, 0, 0, 0, 0, 0] },
  { key: "trebleBooster", preamp: -5, bands: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6] },
  { key: "trebleReducer", preamp: 0, bands: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6] },
  { key: "rock",         preamp: -4, bands: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5] },
  { key: "pop",          preamp: -3, bands: [-1, -1, 0, 2, 4, 4, 2, 0, -1, -2] },
  { key: "jazz",         preamp: -3, bands: [3, 2, 1, 2, -2, -2, 0, 1, 2, 3] },
  { key: "classical",    preamp: -3, bands: [4, 3, 3, 2, -1, -1, 0, 2, 3, 3] },
  { key: "vocal",        preamp: -3, bands: [-2, -3, -3, 1, 4, 4, 3, 1, 0, -1] },
  { key: "electronic",   preamp: -4, bands: [5, 4, 1, 0, -2, 2, 1, 1, 4, 5] },
  { key: "loudness",     preamp: -5, bands: [6, 4, 1, 0, -1, -1, 0, 2, 4, 5] }
]

function byKey(key) {
  for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
  return list[0]
}

var freqLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
