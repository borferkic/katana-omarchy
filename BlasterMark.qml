import QtQuick
import QtQuick.Shapes
import qs.Commons as Commons

// Sound BlasterX "X", drawn as a vector so it follows the theme colour.
// Traced from the product logo; the mark belongs to Creative Technology and is used here only to
// identify the device this unofficial widget controls.
Item {
  id: root

  property real iconHeight: 40
  property color color: Commons.Color.foreground

  // The path lives in a 388 x 478 box.
  readonly property real pathWidth: 388
  readonly property real pathHeight: 478
  readonly property real markScale: iconHeight / pathHeight

  implicitWidth: pathWidth * markScale
  implicitHeight: iconHeight

  Shape {
    width: root.pathWidth
    height: root.pathHeight
    transform: Scale {
      xScale: root.markScale
      yScale: root.markScale
    }
    preferredRendererType: Shape.CurveRenderer
    layer.enabled: false

    ShapePath {
      fillColor: root.color
      strokeWidth: -1
      fillRule: ShapePath.WindingFill
      PathSvg {
        path: "M7 0.6c0 0.4 2.9 3.7 6.4 7.4 16.3 17.3 41.1 48.8 57.9 73.6 30.5 44.9 50.7 85.8 68 137.4l2.5 7.5 0.1-28.7 0.1-28.8 7.6 4.7c23.2 14 60.9 41.7 79.3 58l4.4 3.9-11.4 9.6c-20.5 17.1-51.5 39.4-73.1 52.7l-6.8 4.1-0.1-29.3 0-29.2-3.4 10.5c-19.7 62-55.3 125.2-103.2 183.7-7.5 9.1-12.6 15-30.4 34.8l-5.4 5.9 6.5-4.4c77.3-52.2 177.9-133.9 241.4-196l15.8-15.5 14.2 14.5c46.6 48 82.2 100.9 104.8 155.5 6.3 15.2 6.6 15.1 4.3-1.7-6.4-46.4-16.7-92.7-27.2-122-4-11.2-4.8-11.8-3.4-2.7 1.7 11 2.4 23.9 1.4 23.9-0.6 0-3-3.7-5.4-8.2-10.4-19.3-30.5-47.5-51.6-72.3l-11.9-14 11.9-14c21.4-25.1 42.2-54.4 51.7-72.5 6.1-11.9 6.8-10.9 5 7-0.6 5.2-1.3 11.1-1.6 13-1.8 11.4 9-20.3 15.1-44.7 6.9-27 15-71.8 17-93.3l0.6-6.5-5.8 14c-23.3 55.6-58.4 107.5-104.9 155.5l-14.2 14.5-15.8-15.5c-59.1-57.8-131-117-214.9-177.2-19.3-13.8-25.5-17.5-25.5-15.2z"
      }
    }
  }
}
