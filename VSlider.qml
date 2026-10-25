import QtQuick
import qs.Commons
import qs.Commons as Commons

// Vertical slider for the equalizer: drag, scroll or double-click to reset.
// `moved` fires on every change while the value is being edited, `released` when the drag ends.
Item {
  id: root

  property real value: 0
  property real from: -12
  property real to: 12
  property real stepSize: 0.5
  property real resetValue: 0
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property bool dimmed: false
  readonly property bool dragging: mouse.pressed

  signal moved(real value)
  signal released(real value)

  implicitWidth: Style.space(26)
  implicitHeight: Style.space(120)
  opacity: dimmed ? 0.45 : 1
  Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

  readonly property real handleSize: Style.space(14)
  readonly property real travel: height - handleSize

  function clampStep(v) {
    var snapped = Math.round(v / stepSize) * stepSize
    return Math.max(from, Math.min(to, snapped))
  }
  function edit(v) {
    var next = clampStep(v)
    if (next === value) return
    value = next
    moved(next)
  }

  Rectangle {
    id: track
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.handleSize / 2
    width: Style.space(3)
    height: root.travel
    radius: width / 2
    color: Qt.alpha(root.foreground, 0.25)
  }
  // The span between 0 dB and the handle.
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    width: track.width
    radius: width / 2
    color: root.accent
    readonly property real zeroY: handle.parent.height / 2
    y: Math.min(zeroY, handle.y + root.handleSize / 2)
    height: Math.abs(handle.y + root.handleSize / 2 - zeroY)
  }
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height / 2
    width: Style.space(9)
    height: 1
    color: Qt.alpha(root.foreground, 0.5)
  }
  Rectangle {
    id: handle
    anchors.horizontalCenter: parent.horizontalCenter
    width: root.handleSize
    height: root.handleSize
    radius: width / 2
    color: mouse.pressed ? root.accent : root.foreground
    border.width: 1
    border.color: Qt.alpha(root.foreground, 0.6)
    y: (root.to - root.value) / (root.to - root.from) * root.travel
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    function valueAt(y) {
      return root.to - (y - root.handleSize / 2) / root.travel * (root.to - root.from)
    }
    onPressed: function (e) { root.edit(valueAt(e.y)) }
    onPositionChanged: function (e) { if (pressed) root.edit(valueAt(e.y)) }
    onReleased: root.released(root.value)
    onDoubleClicked: { root.edit(root.resetValue); root.released(root.value) }
    onWheel: function (e) {
      root.edit(root.value + (e.angleDelta.y > 0 ? root.stepSize : -root.stepSize))
      root.released(root.value)
    }
  }
}
