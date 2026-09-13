pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

// HarmonyOS 官方品牌符号 (星环与地平线设计，极简几何纯矢量渲染)
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  // 几何比例 (严谨复刻 HarmonyOS NEXT 官方标志黄金比例)
  readonly property real ringDiameter: Math.max(6, Math.round(width * 0.72))
  readonly property real strokeWidth: Math.max(1.5, Math.round(width * 0.11 * 2) / 2)
  readonly property real barWidth: Math.max(4, Math.round(ringDiameter * 0.64))
  readonly property real barHeight: Math.max(1.5, strokeWidth)
  readonly property real gap: Math.max(1.0, Math.round(height * 0.08))
  readonly property real totalHeight: ringDiameter + gap + barHeight
  readonly property real topOffset: Math.round((height - totalHeight) / 2)

  // 上方星环 (Circle Ring)
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.topOffset
    width: root.ringDiameter
    height: root.ringDiameter
    radius: root.ringDiameter / 2
    color: "transparent"
    border.color: root.color
    border.width: root.strokeWidth
    antialiasing: true
  }

  // 下方地平线 (Horizon Bar)
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.topOffset + root.ringDiameter + root.gap
    width: root.barWidth
    height: root.barHeight
    radius: root.barHeight / 2
    color: root.color
    antialiasing: true
  }
}
