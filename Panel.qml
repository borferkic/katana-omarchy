import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Presets.js" as Presets

// Sound BlasterX Katana widget: a bar icon and a popup with the volume bar, the Katana's
// stored sound profiles (as icons) and a 10-band equalizer with presets and one personal profile.
//
// bin/katana.py runs as a long-lived `daemon` that keeps the system volume and the
// Katana's bar in sync, runs the equalizer filter and reports changes made on the speaker,
// one JSON line each. Commands (profile, volume, eq, status) are short calls to the same
// script, queued so they never overlap.
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

  // One icon per stored profile, chosen from what each profile switches on in the speaker:
  // 0 tuned EQ, 1 surround, 2 custom EQ, 3 crystalizer, 4 smart volume (night), 5 personal.
  readonly property var profileIcons: [0xF001, 0xF025, 0xF1DE, 0xF219, 0xF186, 0xF007]
  function profileGlyph(n) { return String.fromCodePoint(profileIcons[n] || 0xF1DE) }

  // ---- state --------------------------------------------------------------
  property var rep: null
  property string errorCode: ""
  property var queue: []
  property bool daemonBusy: false

  readonly property var flatCurve: ({ preamp: 0, bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] })
  property var eq: ({ on: false, preset: "flat", preamp: 0, bands: flatCurve.bands, custom: flatCurve })
  readonly property bool eqEditing: eqDebounce.running || sliderDragging
  property bool sliderDragging: false

  readonly property int profile: rep && rep.profile !== null && rep.profile !== undefined ? rep.profile : -1
  readonly property int barLevel: rep && rep.bar !== null && rep.bar !== undefined ? rep.bar : -1
  readonly property string errorText: errorCode === "" ? ""
    : (strings.t("error." + errorCode) !== "error." + errorCode ? strings.t("error." + errorCode) : strings.t("error.generic"))

  // ---- commands -----------------------------------------------------------
  function run(args) {
    // A newer read supersedes one still waiting; a newer equalizer write replaces an older one.
    var supersede = args[0] === "status" || (args[0] === "eq" && args.length > 1)
    if (supersede) {
      queue = queue.filter(function (q) { return !(q[0] === args[0] && q.length === args.length) })
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
    if (!res.ok) { errorCode = res.error || "generic"; return }
    errorCode = ""
    if (args[0] === "status") rep = res
    else if (args[0] === "eq") { if (args.length === 1 && !eqEditing) eq = res }
    else refreshTimer.restart()
  }

  function patch(obj) {
    var n = {}
    for (var k in rep) n[k] = rep[k]
    for (var p in obj) n[p] = obj[p]
    rep = n
  }

  function refresh() { run(["status"]); run(["eq"]) }
  function setProfile(n) { patch({ profile: n }); run(["profile", String(n)]) }
  function setBar(n) { patch({ bar: n }); run(["volume", String(n)]) }

  // ---- equalizer ----------------------------------------------------------
  function eqWith(fields) {
    var n = {}
    for (var k in eq) n[k] = eq[k]
    for (var p in fields) n[p] = fields[p]
    return n
  }
  function eqSave(fields) { run(["eq", "set", JSON.stringify(fields)]) }

  function setEqOn(on) {
    eq = eqWith({ on: on })
    eqSave({ on: on })
  }

  function applyPreset(key) {
    var c = key === "custom" ? eq.custom : Presets.byKey(key)
    eq = eqWith({ preset: key, preamp: c.preamp, bands: c.bands.slice() })
    eqSave({ preset: key, preamp: c.preamp, bands: c.bands })
  }

  // index -1 is the preamp. Any manual move lands in the one personal profile.
  function eqMove(index, value) {
    var bands = eq.bands.slice()
    var preamp = eq.preamp
    if (index < 0) preamp = value
    else bands[index] = value
    eq = eqWith({ preset: "custom", preamp: preamp, bands: bands, custom: { preamp: preamp, bands: bands.slice() } })
    eqDebounce.restart()
  }
  function eqFlush() {
    eqDebounce.stop()
    eqSave({ preset: "custom", preamp: eq.preamp, bands: eq.bands, custom: eq.custom })
  }

  readonly property var presetOptions: {
    var o = Presets.list.map(function (p) { return { value: p.key, label: strings.t("preset." + p.key) } })
    o.push({ value: "custom", label: strings.t("preset.custom") })
    return o
  }

  Timer { id: eqDebounce; interval: 100; onTriggered: root.eqFlush() }

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
        else if (ev.event === "profile") {
          root.patch({ profile: ev.profile })
          if (root.setting("announceProfile", true) === true)
            Quickshell.execDetached(["omarchy-osd", "-i", root.icon, "-m", strings.t("announce").arg(root.profileGlyph(ev.profile))])
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
              checked: root.eq.on
              foreground: root.foreground
              onToggled: root.setEqOn(!root.eq.on)
            }
          }
        }

        Dropdown {
          width: parent.width
          showLabel: false
          fontFamily: root.fontFamily
          foreground: root.foreground
          options: root.presetOptions
          value: root.eq.preset
          onChanged: function (v) { root.applyPreset(v) }
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
                  dimmed: !root.eq.on
                  value: isPreamp ? root.eq.preamp : root.eq.bands[index - 1]
                  onMoved: function (v) { root.sliderDragging = true; root.eqMove(index - 1, v) }
                  onReleased: function (v) { root.sliderDragging = false; root.eqFlush() }
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
      }
    }
  }
}
