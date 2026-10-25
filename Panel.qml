import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Presets.js" as Presets

// Sound BlasterX Katana widget: a bar icon and a popup with the volume bar, the Katana's stored
// sound profiles (as icons), and the equalizer and enhancements of the profile in use.
//
// The equalizer and the enhancements live in the speaker. They can be edited only in the Personal
// profile; in the others the panel shows what that profile holds, read-only, so the factory
// profiles are never changed by accident.
//
// bin/katana.py runs as a long-lived `daemon` that keeps the system volume and the Katana's bar
// in sync, learns what each profile holds, and reports changes made on the speaker, one JSON line
// each. Commands (profile, volume, hw, learn, status) are short calls to the same script, queued
// so they never overlap.
//
// Bar button: left click opens the panel, right click re-reads.
// Panel: Esc closes, r refreshes. Equalizer sliders: drag, scroll, or double-click to reset.
Panel {
  id: root
  moduleName: "io.github.borferkic.katana"
  ipcTarget: "io.github.borferkic.katana"
  manageIpc: false

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    u = u.replace(/^file:\/\//, "")
    try { u = decodeURIComponent(u) } catch (e) {}
    return u.replace(/\/+$/, "")
  }
  readonly property var helper: ["python3", "-B", "-I", root.pluginDir + "/bin/katana.py"]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string icon: String.fromCodePoint(0xF04C3)
  readonly property int barMax: 50

  // The stored profiles follow the order of Creative's own list: 0 Neutral, 1 Gaming, 2 Concert,
  // 3 Cinema, 4 Night and 5 Personal. The speaker does not report which is which, so this is the
  // one table to change if a slot turns out to hold something else.
  // Icons: balance, gamepad, music note, film strip, moon, user.
  readonly property var profileIcons: [0xF24E, 0xF11B, 0xF001, 0xF008, 0xF186, 0xF007]
  readonly property int personalProfile: 5
  function profileGlyph(n) { return String.fromCodePoint(profileIcons[n] || 0xF1DE) }
  function profileName(n) { return strings.t("profile." + n) }

  // ---- state --------------------------------------------------------------
  property var rep: null
  property string errorCode: ""
  property var queue: []
  property bool daemonBusy: false
  property bool learning: false

  readonly property int profile: rep && rep.profile !== null && rep.profile !== undefined ? rep.profile : -1
  readonly property int barLevel: rep && rep.bar !== null && rep.bar !== undefined ? rep.bar : -1
  readonly property bool personal: profile === personalProfile
  readonly property int learned: rep && rep.learned ? rep.learned : 0
  readonly property string errorText: errorCode === "" ? ""
    : (strings.t("error." + errorCode) !== "error." + errorCode ? strings.t("error." + errorCode) : strings.t("error.generic"))

  // What the speaker holds for the profile in use, as the daemon learned it.
  readonly property var deviceProfile: rep && rep.deviceProfiles && rep.deviceProfiles[String(profile)] ? rep.deviceProfiles[String(profile)] : null
  // While the user edits, `edit` ({ on, preamp, bands }) and `fxEdit` ({ name: bool }) hold the
  // values on screen until the speaker's own report arrives; then they are dropped.
  property var edit: null
  property var fxEdit: ({})
  property var pending: ({})

  function number(v) { return v === null || v === undefined ? 0 : v }
  function deviceBand(i) { return deviceProfile ? Math.max(-12, Math.min(12, number(deviceProfile.bands[i]))) : 0 }
  readonly property bool eqOn: edit ? edit.on : (deviceProfile !== null && deviceProfile.eqOn === true)
  readonly property real preamp: edit ? edit.preamp : (deviceProfile ? number(deviceProfile.preamp) : 0)
  function bandValue(i) { return edit ? edit.bands[i] : deviceBand(i) }
  function effectOn(name) {
    if (fxEdit[name] !== undefined) return fxEdit[name]
    var v = deviceProfile ? deviceProfile.effects[name] : null
    return v !== null && v !== undefined && v > 0
  }

  // The preset whose bands match what is on screen, or "custom".
  readonly property string presetKey: {
    for (var p = 0; p < Presets.list.length; p++) {
      var match = true
      for (var i = 0; i < 10 && match; i++) match = Math.abs(bandValue(i) - Presets.list[p].bands[i]) < 0.01
      if (match) return Presets.list[p].key
    }
    return "custom"
  }
  readonly property var presetOptions: {
    var o = Presets.list.map(function (p) { return { value: p.key, label: strings.t("preset." + p.key) } })
    o.push({ value: "custom", label: strings.t("preset.custom") })
    return o
  }

  // ---- commands -----------------------------------------------------------
  function run(args) {
    // A newer read supersedes one still waiting.
    if (args[0] === "status") {
      queue = queue.filter(function (q) { return q[0] !== "status" })
    }
    queue.push(args)
    pump()
  }

  function pump() {
    if (proc.running || queue.length === 0) return
    proc.args = queue.shift()
    proc.command = helper.concat(proc.args)
    proc.running = true
  }

  function handle(args, res) {
    if (args[0] === "learn") { learning = false; refreshTimer.restart() }
    if (args[0] === "hw") settleTimer.restart()
    if (!res.ok) {
      errorCode = res.error || "generic"
      if (args[0] === "hw") { edit = null; fxEdit = ({}) }
      return
    }
    errorCode = ""
    if (args[0] === "status") rep = res
    else if (args[0] !== "hw") refreshTimer.restart()
  }

  function patch(obj) {
    var n = {}
    for (var k in rep) n[k] = rep[k]
    for (var p in obj) n[p] = obj[p]
    rep = n
  }

  function refresh() { run(["status"]) }
  function setProfile(n) { edit = null; fxEdit = ({}); patch({ profile: n }); run(["profile", String(n)]) }
  function setBar(n) { patch({ bar: n }); run(["volume", String(n)]) }
  function learnProfiles() { learning = true; run(["learn"]) }

  // ---- equalizer and enhancements (Personal profile only) ---------------------
  function editCopy() {
    return edit ? { on: edit.on, preamp: edit.preamp, bands: edit.bands.slice() }
      : { on: eqOn, preamp: preamp, bands: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(function (i) { return bandValue(i) }) }
  }

  // Writes are merged and sent together once the sliders pause.
  function queueWrite(fields) {
    var n = {}
    for (var k in pending) n[k] = pending[k]
    for (var f in fields) {
      if (f === "bands" || f === "effects") {
        var merged = {}
        for (var a in n[f]) merged[a] = n[f][a]
        for (var b in fields[f]) merged[b] = fields[f][b]
        n[f] = merged
      } else n[f] = fields[f]
    }
    pending = n
    writeTimer.restart()
  }
  function flushWrite() {
    writeTimer.stop()
    var request = pending
    pending = ({})
    if (Object.keys(request).length > 0) run(["hw", JSON.stringify(request)])
  }

  function setEqOn(on) {
    if (!personal) return
    var e = editCopy(); e.on = on; edit = e
    queueWrite({ eqOn: on })
  }
  function eqMove(index, value) {
    if (!personal) return
    var e = editCopy()
    var fields = {}
    if (index < 0) { e.preamp = value; fields.preamp = value }
    else { e.bands[index] = value; fields.bands = {}; fields.bands[index] = value }
    edit = e
    queueWrite(fields)
  }
  function applyPreset(key) {
    if (!personal || key === "custom") return
    var p = Presets.byKey(key)
    var bands = {}
    for (var i = 0; i < 10; i++) bands[i] = p.bands[i]
    edit = { on: true, preamp: p.preamp, bands: p.bands.slice() }
    queueWrite({ eqOn: true, preamp: p.preamp, bands: bands })
  }
  function setEffect(name, on) {
    if (!personal) return
    var f = {}
    for (var k in fxEdit) f[k] = fxEdit[k]
    f[name] = on
    fxEdit = f
    var effects = {}
    effects[name] = on
    queueWrite({ effects: effects })
  }

  Timer { id: writeTimer; interval: 100; onTriggered: root.flushWrite() }
  // Back to the speaker's own values once it has had time to report the change.
  Timer {
    id: settleTimer
    interval: 1600
    onTriggered: {
      if (root.pending && Object.keys(root.pending).length > 0) return
      root.edit = null
      root.fxEdit = ({})
      root.run(["status"])
    }
  }

  Process {
    id: proc
    property var args: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(String(text).trim().split("\n").pop()) } catch (e) {}
        if (res) root.handle(proc.args, res)
      }
    }
    onExited: root.pump()
  }

  // Re-read once the commands have gone quiet, to show what the Katana kept.
  Timer { id: refreshTimer; interval: 500; onTriggered: root.run(["status"]) }

  // ---- daemon -------------------------------------------------------------
  Process {
    id: daemon
    command: root.helper.concat(["daemon"])
    running: root.setting("syncVolume", true) === true
    stdout: SplitParser {
      onRead: function (line) {
        var ev = null
        try { ev = JSON.parse(line) } catch (e) {}
        if (!ev) return
        root.daemonBusy = ev.event === "busy"
        if (ev.event === "bar") root.patch({ bar: ev.level })
        else if (ev.event === "profileState") { if (!root.edit) root.run(["status"]) }
        else if (ev.event === "profile") {
          root.edit = null
          root.fxEdit = ({})
          root.patch({ profile: ev.profile })
          if (root.setting("announceProfile", true) === true)
            Quickshell.execDetached(["omarchy-osd", "-i", root.icon, "-m", strings.t("announce").arg(root.profileName(ev.profile)).arg(root.profileGlyph(ev.profile))])
        }
      }
    }
    // The helper exits when it crashes: try again later.
    onExited: restartTimer.restart()
  }
  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: daemon.running = root.setting("syncVolume", true) === true
  }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) refresh()

  ShellIpc {
    target: "io.github.borferkic.katana"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function (b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function (t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---- header ----
        Item {
          width: parent.width
          implicitHeight: heroText.implicitHeight

          BlasterMark {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconHeight: Style.space(34)
            color: root.foreground
          }
          Column {
            id: heroText
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: level.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("title")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
          }
          Text {
            id: level
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.barLevel >= 0 ? strings.t("bar").arg(root.barLevel).arg(root.barMax) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        Text {
          visible: root.errorText !== "" || root.daemonBusy || root.setting("syncVolume", true) !== true
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.errorText !== "" ? root.errorText
            : (root.setting("syncVolume", true) !== true ? strings.t("syncOff") : strings.t("busy"))
          color: root.errorText !== "" ? "#e06c75" : Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: root.foreground }

        // ---- volume ----
        PanelSectionHeader {
          text: strings.t("volume").toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        PanelSlider {
          width: parent.width
          bar: root.bar
          minimum: 0
          maximum: root.barMax
          step: 1
          integer: true
          value: Math.max(0, root.barLevel)
          onReleased: function (v) { root.setBar(Math.round(v)) }
        }

        // ---- stored profiles, as icons ----
        PanelSectionHeader {
          text: strings.t("profiles").toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        Row {
          id: profileRow
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: 6
            delegate: Button {
              required property int index
              width: (profileRow.width - profileRow.spacing * 5) / 6
              text: root.profileGlyph(index)
              fontSize: Style.font.title
              selected: root.profile === index
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.setProfile(index)
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- equalizer ----
        Item {
          width: parent.width
          implicitHeight: eqHeader.implicitHeight

          PanelSectionHeader {
            id: eqHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("equalizer").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: strings.t("on")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              cursorRing: false
              trackHeight: Style.space(18)
              enabled: root.personal
              checked: root.eqOn
              foreground: root.foreground
              onToggled: root.setEqOn(!root.eqOn)
            }
          }
        }

        Dropdown {
          visible: root.personal
          width: parent.width
          showLabel: false
          fontFamily: root.fontFamily
          foreground: root.foreground
          options: root.presetOptions
          value: root.presetKey
          onChanged: function (v) { root.applyPreset(v) }
        }

        // Outside the Personal profile: why the sliders are locked.
        Column {
          visible: !root.personal || root.learned < 6
          width: parent.width
          spacing: Style.space(6)
          Text {
            visible: !root.personal
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: strings.t("eq.locked")
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: root.learned < 6
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: strings.t("eq.unknown")
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Button {
            visible: root.learned < 6
            text: root.learning ? strings.t("eq.reading") : strings.t("eq.read")
            enabled: !root.learning
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            bordered: true
            onClicked: root.learnProfiles()
          }
        }

        Item {
          id: eqArea
          width: parent.width
          height: bandsRow.implicitHeight

          readonly property real scaleWidth: Style.space(50)
          readonly property real columnWidth: (width - scaleWidth) / 11
          readonly property real sliderHeight: Style.space(120)

          // dB scale on the left, aligned with the slider travel
          Repeater {
            model: [{ t: "+12 dB", f: 0 }, { t: "0 dB", f: 0.5 }, { t: "-12 dB", f: 1 }]
            delegate: Text {
              required property var modelData
              textFormat: Text.PlainText
              text: modelData.t
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              x: 0
              y: Style.space(7) + modelData.f * (eqArea.sliderHeight - Style.space(14)) - height / 2
            }
          }

          Row {
            id: bandsRow
            x: eqArea.scaleWidth
            Repeater {
              model: 11
              delegate: Column {
                required property int index
                // index 0 is the preamp, 1..10 the bands
                readonly property bool isPreamp: index === 0
                width: eqArea.columnWidth
                spacing: Style.space(4)
                VSlider {
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: eqArea.sliderHeight
                  foreground: root.foreground
                  enabled: root.personal
                  dimmed: !root.eqOn
                  value: isPreamp ? root.preamp : root.bandValue(index - 1)
                  onMoved: function (v) { root.eqMove(index - 1, v) }
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: isPreamp ? strings.t("preamp") : Presets.freqLabels[index - 1]
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- enhancements ----
        PanelSectionHeader {
          text: strings.t("enhancements").toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        Repeater {
          model: ["dialogPlus", "surround", "smartVolume"]
          delegate: Toggle {
            required property string modelData
            width: column.width
            enabled: root.personal
            opacity: root.personal ? 1 : 0.55
            label: strings.t("fx." + modelData)
            description: strings.t("fx." + modelData + ".desc")
            checked: root.effectOn(modelData)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setEffect(modelData, !checked)
          }
        }
      }
    }
  }
}
