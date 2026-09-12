pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// HarmonyOS Dev - Omarchy 状态栏插件与构建管理控制台
// 功能：远程构建、代码同步、真机安装、环境监测及参数配置
BarWidget {
  id: root
  moduleName: "harmony.dev"

  // 颜色定义 (Catppuccin Mocha 风格，深度契合 Omarchy 主题)
  readonly property var colors: ({
    base: "#1e1e2e",
    mantle: "#181825",
    crust: "#11111b",
    surface0: "#313244",
    surface1: "#45475a",
    surface2: "#585b70",
    overlay0: "#6c7086",
    overlay1: "#7f849c",
    text: "#cdd6f4",
    subtext0: "#a6adc8",
    subtext1: "#bac2de",
    blue: "#89b4fa",
    sapphire: "#74c7ec",
    green: "#a6e3a1",
    yellow: "#f9e2af",
    peach: "#fab387",
    red: "#f38ba8",
    maroon: "#eba0ac",
    teal: "#94e2d5"
  })

  // 脚本路径计算
  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    return u.replace(/^file:\/\//, "")
  }
  readonly property string buildScriptPath: pluginDir + "/scripts/hm-build.sh"
  readonly property string statusScriptPath: pluginDir + "/scripts/check-status.sh"
  readonly property string configScriptPath: pluginDir + "/scripts/config.sh"

  // 构建状态属性
  property bool building: false
  property string buildStatus: "就绪"
  property string buildStage: ""
  property var buildLogs: []
  property int buildElapsedSeconds: 0

  // 环境检测状态
  property bool sshOk: false
  property string macHost: "chenbolun@10.221.68.124"
  property bool deviceOnline: false
  property string deviceName: "离线"
  property bool projectOk: false
  property string projectPath: ""
  property string projectName: ""
  property string bundleName: ""

  // 配置变量 (直接在插件中填写)
  property string inputMacHost: "chenbolun@10.221.68.124"
  property string inputRemoteDir: "~/Dev/harmony"
  property string inputProjectPath: ""
  property bool autoInstall: true
  property bool autoLaunch: true
  property string saveFeedback: ""

  // 面板开合
  property bool panelOpen: false
  readonly property bool opened: root.panelOpen
  function open() { root.panelOpen = true; root.refreshStatus(); }
  function close() { root.panelOpen = false; }
  function togglePanel() { if (root.panelOpen) root.close(); else root.open(); }

  // 状态点指示颜色
  readonly property color statusColor: {
    if (root.building) return root.colors.blue
    if (!root.sshOk) return root.colors.red
    if (root.deviceOnline) return root.colors.green
    return root.colors.peach
  }

  // 状态栏提示文案
  readonly property string tooltipInfo: {
    var lines = ["HarmonyOS 远程构建与调试"]
    lines.push("• 远程 Mac: " + root.macHost + (root.sshOk ? " (已连接)" : " (未连接)"))
    lines.push("• 本地设备: " + (root.deviceOnline ? (root.deviceName + " (在线)") : "离线"))
    if (root.projectOk) {
      lines.push("• 当前工程: " + root.projectName + (root.bundleName ? (" (" + root.bundleName + ")") : ""))
    } else {
      lines.push("• 当前工程: 未检测到 (可在面板中指定)")
    }
    if (root.building) {
      lines.push("• 状态: 正在构建 (" + root.buildElapsedSeconds + "s) - " + root.buildStage)
    }
    lines.push("点击: 打开控制面板 · 右键: 刷新环境")
    return lines.join("\n")
  }

  // IPC 控制协议支持
  IpcHandler {
    target: "harmony.dev"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refreshStatus() }
    function build(): void { root.startBuild("all") }
    function sync(): void { root.startBuild("sync-only") }
    function install(): void { root.startBuild("install-only") }
  }

  // 构建计时器
  Timer {
    id: buildTimer
    interval: 1000
    repeat: true
    running: root.building
    onTriggered: root.buildElapsedSeconds += 1
  }

  // 状态刷新定时器 (仅在面板开启时每 10 秒刷新，避免后台消耗)
  Timer {
    interval: 10000
    repeat: true
    running: root.opened && !root.building
    onTriggered: root.refreshStatus()
  }

  // 保存提示倒计时
  Timer {
    id: feedbackTimer
    interval: 2500
    repeat: false
    onTriggered: root.saveFeedback = ""
  }

  // 追加日志
  function appendLog(line) {
    if (!line) return
    var clean = line.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "")
    if (clean.indexOf("===>") !== -1) {
      root.buildStage = clean.replace(/={3,}>\s*/, "").trim()
    }
    var logs = root.buildLogs.slice()
    logs.push(clean)
    if (logs.length > 300) logs.shift()
    root.buildLogs = logs
  }

  // 刷新配置
  function refreshConfig() {
    loadConfigProc.running = true
  }

  // 保存配置
  function saveConfig() {
    var payload = JSON.stringify({
      macHost: root.inputMacHost,
      remoteDir: root.inputRemoteDir,
      projectPath: root.inputProjectPath,
      autoInstall: root.autoInstall,
      autoLaunch: root.autoLaunch
    })
    saveConfigProc.command = [root.configScriptPath, "set", payload]
    saveConfigProc.running = true
  }

  // 刷新环境状态
  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = [
      root.statusScriptPath,
      "--host", root.inputMacHost,
      "--path", root.inputProjectPath
    ]
    statusProc.running = true
  }

  // 启动构建流程
  function startBuild(mode) {
    if (root.building) return
    root.building = true
    root.buildElapsedSeconds = 0
    root.buildStage = "正在初始化..."
    root.buildStatus = "构建中..."
    root.buildLogs = ["[" + new Date().toLocaleTimeString() + "] 开始执行模式: " + mode]

    var args = [root.buildScriptPath]
    if (root.inputMacHost) {
      args.push("--host", root.inputMacHost)
    }
    if (root.inputRemoteDir) {
      args.push("--remote-dir", root.inputRemoteDir)
    }
    if (root.inputProjectPath) {
      args.push("--path", root.inputProjectPath)
    }
    if (!root.autoInstall) {
      args.push("--no-install")
    }
    if (!root.autoLaunch) {
      args.push("--no-launch")
    }

    if (mode === "sync-only") {
      args.push("--sync-only")
    } else if (mode === "build-only") {
      args.push("--build-only")
    } else if (mode === "install-only") {
      args.push("--install-only")
    } else if (mode === "clean") {
      args.push("--clean")
    } else if (mode === "deps") {
      args.push("--deps")
    }

    buildProc.command = args
    buildProc.running = true
  }

  // 取消构建
  function cancelBuild() {
    if (buildProc.running) {
      buildProc.kill()
      root.building = false
      root.buildStatus = "已中止"
      root.appendLog("⚠️ 用户手动中止了构建进程。")
    }
  }

  // 外部终端中启动构建
  function runInTerminal(extraArgs) {
    var cmd = root.buildScriptPath
    if (extraArgs) cmd += " " + extraArgs
    Quickshell.execDetached([
      "sh", "-c",
      "command -v omarchy-launch-terminal >/dev/null && omarchy-launch-terminal bash -c '" + cmd + "; echo; read -p \"按回车键退出...\"' || xdg-terminal-exec bash -c '" + cmd + "; echo; read -p \"按回车键退出...\"'"
    ])
  }

  // 进程：读取配置
  Process {
    id: loadConfigProc
    running: false
    command: [root.configScriptPath, "get"]
    stdout: StdioCollector {
      id: configCollector
      waitForEnd: true
    }
    onExited: function(code) {
      if (code !== 0) return
      var text = configCollector.text.trim()
      if (!text) return
      try {
        var cfg = JSON.parse(text)
        if (cfg.macHost) {
          root.inputMacHost = cfg.macHost
          root.macHost = cfg.macHost
        }
        if (cfg.remoteDir) root.inputRemoteDir = cfg.remoteDir
        if (cfg.projectPath !== undefined) root.inputProjectPath = cfg.projectPath
        if (cfg.autoInstall !== undefined) root.autoInstall = cfg.autoInstall
        if (cfg.autoLaunch !== undefined) root.autoLaunch = cfg.autoLaunch
        root.refreshStatus()
      } catch (e) {
        console.warn("HarmonyDev load config error: " + e)
      }
    }
  }

  // 进程：保存配置
  Process {
    id: saveConfigProc
    running: false
    command: []
    onExited: function(code) {
      if (code === 0) {
        root.saveFeedback = "配置已保存 ✓"
        feedbackTimer.restart()
        root.refreshStatus()
      } else {
        root.saveFeedback = "保存失败 ✗"
        feedbackTimer.restart()
      }
    }
  }

  // 进程：环境探测
  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector {
      id: statusCollector
      waitForEnd: true
    }
    onExited: function(code) {
      var text = statusCollector.text.trim()
      if (!text) return
      try {
        var res = JSON.parse(text)
        root.sshOk = res.ssh_ok === true
        root.macHost = res.mac_host || root.inputMacHost
        root.deviceOnline = res.device_online === true
        root.deviceName = res.device_name || "离线"
        root.projectOk = res.project_ok === true
        root.projectPath = res.project_path || ""
        root.projectName = res.project_name || ""
        root.bundleName = res.bundle_name || ""
        if (!root.inputProjectPath && res.project_path) {
          root.inputProjectPath = res.project_path
        }
      } catch (e) {
        console.warn("HarmonyDev status error: " + e + ", raw: " + text)
      }
    }
  }

  // 进程：构建执行
  Process {
    id: buildProc
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) {
        root.appendLog(line)
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        root.appendLog(line)
      }
    }
    onExited: function(code) {
      root.building = false
      if (code === 0) {
        root.buildStatus = "成功"
        root.appendLog("✨ 流程执行完毕 (耗时: " + root.buildElapsedSeconds + "s)")
      } else {
        root.buildStatus = "失败"
        root.appendLog("❌ 流程异常退出，退出码: " + code)
      }
      root.refreshStatus()
    }
  }

  Component.onCompleted: {
    root.refreshConfig()
  }

  // =========================================================================
  // 顶栏图标按钮
  // =========================================================================
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "鸿"
    tooltipText: root.tooltipInfo

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.refreshStatus()
      } else {
        root.togglePanel()
      }
    }

    // 状态小圆点
    Rectangle {
      width: Style.space(6)
      height: Style.space(6)
      radius: Style.space(3)
      color: root.statusColor
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.top: parent.top
      anchors.topMargin: Style.space(2)

      SequentialAnimation on opacity {
        running: root.building
        loops: Animation.Infinite
        NumberAnimation { to: 0.2; duration: 600 }
        NumberAnimation { to: 1.0; duration: 600 }
      }
    }
  }

  // 展开时的高亮下划线
  Rectangle {
    readonly property bool vertical: !!root.bar && root.bar.vertical
    visible: root.panelOpen
    color: root.colors.blue
    radius: Math.min(width, height) / 2
    width: vertical ? Style.space(2) : Math.max(Style.space(12), button.labelWidth)
    height: vertical ? Math.max(Style.space(12), button.labelWidth) : Style.space(2)
    x: vertical
      ? (root.bar.position === "left" ? root.width - width - Style.space(2) : Style.space(2))
      : Math.round((root.width - width) / 2)
    y: vertical
      ? Math.round((root.height - height) / 2)
      : (root.bar && root.bar.position === "top"
        ? root.height - height - Style.space(2) : Style.space(2))
  }

  // =========================================================================
  // 下拉控制面板 (KeyboardPanel)
  // =========================================================================
  KeyboardPanel {
    id: popupPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    focusTarget: keyCatcher
    contentWidth: popupPanel.fittedContentWidth(Style.space(560))
    contentHeight: popupPanel.fittedContentHeight(panelColumn.implicitHeight + Style.space(24), Style.space(780))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // 避免输入框获得焦点时快捷键被拦截
      blocked: hostInput.activeFocus || remoteDirInput.activeFocus || projectPathInput.activeFocus

      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") {
          root.refreshStatus()
        } else if (t === "Escape") {
          root.close()
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        anchors.margins: Style.space(8)
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // -----------------------------------------------------------------
          // 1. 顶部 Header
          // -----------------------------------------------------------------
          Item {
            width: parent.width
            height: Style.space(34)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Rectangle {
                width: Style.space(24)
                height: Style.space(24)
                radius: Style.space(6)
                color: root.colors.surface0
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  text: "鸿"
                  color: root.colors.blue
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              Text {
                text: "HarmonyOS 构建与调试"
                color: root.colors.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              // 状态 Badge
              Rectangle {
                height: Style.space(20)
                width: statusBadgeText.implicitWidth + Style.space(12)
                radius: Style.space(10)
                color: root.building ? root.colors.blue : (root.buildStatus === "成功" ? root.colors.green : (root.buildStatus === "失败" ? root.colors.red : root.colors.surface1))
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: statusBadgeText
                  anchors.centerIn: parent
                  text: root.building ? ("构建中 " + root.buildElapsedSeconds + "s") : root.buildStatus
                  color: root.colors.crust
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            // 右侧关闭与刷新按钮
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Rectangle {
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.space(4)
                color: refreshArea.containsMouse ? root.colors.surface1 : root.colors.surface0

                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refreshStatus()
                }

                Text {
                  anchors.centerIn: parent
                  text: "🔄"
                  font.pixelSize: Style.font.caption
                }
              }

              Rectangle {
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.space(4)
                color: closeArea.containsMouse ? root.colors.surface1 : root.colors.surface0

                MouseArea {
                  id: closeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.close()
                }

                Text {
                  anchors.centerIn: parent
                  text: "✕"
                  color: root.colors.text
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator { foreground: root.colors.surface1 }

          // -----------------------------------------------------------------
          // 2. 环境感知卡片 (Mac SSH / USB 真机 / 鸿蒙工程)
          // -----------------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            // 卡片 1: Mac 连通性
            Rectangle {
              width: (parent.width - Style.space(16)) / 3
              height: Style.space(64)
              radius: Style.space(6)
              color: root.colors.surface0
              border.color: root.sshOk ? root.colors.surface1 : root.colors.red
              border.width: 1

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(6)
                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(8)
                    radius: Style.space(4)
                    color: root.sshOk ? root.colors.green : root.colors.red
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: root.sshOk ? "Mac mini 已连接" : "Mac 未连接"
                    color: root.colors.text
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  text: root.macHost
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption * 0.9
                  elide: Text.ElideMiddle
                  width: parent.width
                }
              }
            }

            // 卡片 2: USB 真机
            Rectangle {
              width: (parent.width - Style.space(16)) / 3
              height: Style.space(64)
              radius: Style.space(6)
              color: root.colors.surface0
              border.color: root.deviceOnline ? root.colors.surface1 : root.colors.surface0
              border.width: 1

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(6)
                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(8)
                    radius: Style.space(4)
                    color: root.deviceOnline ? root.colors.green : root.colors.peach
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: root.deviceOnline ? "USB 真机在线" : "真机未连接"
                    color: root.colors.text
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  text: root.deviceName
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption * 0.9
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }

            // 卡片 3: 本地鸿蒙工程
            Rectangle {
              width: (parent.width - Style.space(16)) / 3
              height: Style.space(64)
              radius: Style.space(6)
              color: root.colors.surface0
              border.color: root.projectOk ? root.colors.surface1 : root.colors.peach
              border.width: 1

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(2)

                Row {
                  spacing: Style.space(6)
                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(8)
                    radius: Style.space(4)
                    color: root.projectOk ? root.colors.green : root.colors.peach
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: root.projectOk ? (root.projectName || "已识别工程") : "未检测到工程"
                    color: root.colors.text
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width - Style.space(16)
                  }
                }

                Text {
                  text: root.bundleName || (root.projectPath ? root.projectPath : "需指定工程路径")
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption * 0.85
                  elide: Text.ElideMiddle
                  width: parent.width
                }
              }
            }
          }

          // -----------------------------------------------------------------
          // 3. 配置编辑区 (用户需求：可直接在插件中填写)
          // -----------------------------------------------------------------
          Rectangle {
            width: parent.width
            implicitHeight: configCol.implicitHeight + Style.space(20)
            radius: Style.space(8)
            color: root.colors.surface0
            border.color: root.colors.surface1
            border.width: 1

            Column {
              id: configCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Item {
                width: parent.width
                height: Style.space(24)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "⚙ 参数配置 (直接在下方填写生效)"
                  color: root.colors.blue
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                // 保存按钮与提示
                Row {
                  id: saveBtnRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    visible: root.saveFeedback !== ""
                    text: root.saveFeedback
                    color: root.colors.green
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Rectangle {
                    width: Style.space(72)
                    height: Style.space(24)
                    radius: Style.space(4)
                    color: saveMouseArea.containsMouse ? root.colors.blue : root.colors.surface2

                    MouseArea {
                      id: saveMouseArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.saveConfig()
                    }

                    Text {
                      anchors.centerIn: parent
                      text: "保存配置"
                      color: saveMouseArea.containsMouse ? root.colors.crust : root.colors.text
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }
              }

              // 输入项 1: Mac Host
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(90)
                  text: "远程主机:"
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                TextField {
                  id: hostInput
                  width: parent.width - Style.space(98)
                  height: Style.space(28)
                  text: root.inputMacHost
                  onTextEdited: root.inputMacHost = text
                  placeholderText: "chenbolun@10.221.68.124"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.colors.text
                  selectionColor: root.colors.surface2
                  selectedTextColor: root.colors.text
                  placeholderTextColor: root.colors.overlay0
                  background: Rectangle {
                    radius: Style.space(4)
                    color: root.colors.mantle
                    border.color: hostInput.activeFocus ? root.colors.blue : root.colors.surface1
                    border.width: 1
                  }
                }
              }

              // 输入项 2: Remote Dir
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(90)
                  text: "远程目录:"
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                TextField {
                  id: remoteDirInput
                  width: parent.width - Style.space(98)
                  height: Style.space(28)
                  text: root.inputRemoteDir
                  onTextEdited: root.inputRemoteDir = text
                  placeholderText: "~/Dev/harmony"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.colors.text
                  selectionColor: root.colors.surface2
                  selectedTextColor: root.colors.text
                  placeholderTextColor: root.colors.overlay0
                  background: Rectangle {
                    radius: Style.space(4)
                    color: root.colors.mantle
                    border.color: remoteDirInput.activeFocus ? root.colors.blue : root.colors.surface1
                    border.width: 1
                  }
                }
              }

              // 输入项 3: Project Path
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(90)
                  text: "本地工程路径:"
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                TextField {
                  id: projectPathInput
                  width: parent.width - Style.space(98)
                  height: Style.space(28)
                  text: root.inputProjectPath
                  onTextEdited: root.inputProjectPath = text
                  placeholderText: "留空将自动根据终端当前工作目录探测"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.colors.text
                  selectionColor: root.colors.surface2
                  selectedTextColor: root.colors.text
                  placeholderTextColor: root.colors.overlay0
                  background: Rectangle {
                    radius: Style.space(4)
                    color: root.colors.mantle
                    border.color: projectPathInput.activeFocus ? root.colors.blue : root.colors.surface1
                    border.width: 1
                  }
                }
              }

              // 开关选项: 自动安装与自动拉起
              Row {
                spacing: Style.space(20)

                Row {
                  spacing: Style.space(6)
                  Rectangle {
                    width: Style.space(16)
                    height: Style.space(16)
                    radius: Style.space(3)
                    color: root.autoInstall ? root.colors.blue : root.colors.mantle
                    border.color: root.colors.surface2
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.autoInstall = !root.autoInstall
                    }

                    Text {
                      visible: root.autoInstall
                      anchors.centerIn: parent
                      text: "✓"
                      color: root.colors.crust
                      font.pixelSize: Style.font.caption * 0.9
                      font.bold: true
                    }
                  }
                  Text {
                    text: "构建后自动推送到真机安装"
                    color: root.colors.text
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  spacing: Style.space(6)
                  Rectangle {
                    width: Style.space(16)
                    height: Style.space(16)
                    radius: Style.space(3)
                    color: root.autoLaunch ? root.colors.blue : root.colors.mantle
                    border.color: root.colors.surface2
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.autoLaunch = !root.autoLaunch
                    }

                    Text {
                      visible: root.autoLaunch
                      anchors.centerIn: parent
                      text: "✓"
                      color: root.colors.crust
                      font.pixelSize: Style.font.caption * 0.9
                      font.bold: true
                    }
                  }
                  Text {
                    text: "安装后自动启动应用"
                    color: root.colors.text
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          // -----------------------------------------------------------------
          // 4. 快捷操作栏 (构建按钮)
          // -----------------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(8)

            // 主按钮: 一键全流程
            Rectangle {
              width: parent.width
              height: Style.space(38)
              radius: Style.space(6)
              color: root.building ? root.colors.surface2 : (mainBtnArea.containsMouse ? root.colors.sapphire : root.colors.blue)

              MouseArea {
                id: mainBtnArea
                anchors.fill: parent
                enabled: !root.building
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startBuild("all")
              }

              Row {
                anchors.centerIn: parent
                spacing: Style.space(8)

                Text {
                  text: root.building ? "⏳" : "🚀"
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: root.building ? ("正在构建中... (" + root.buildElapsedSeconds + "s)") : "一键全流程构建并真机安装"
                  color: root.colors.crust
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }

            // 次要动作按钮网格
            Grid {
              width: parent.width
              columns: 3
              spacing: Style.space(6)

              // 按钮 1: 仅远程构建
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(30)
                radius: Style.space(4)
                color: b1Area.containsMouse ? root.colors.surface2 : root.colors.surface1

                MouseArea {
                  id: b1Area
                  anchors.fill: parent
                  enabled: !root.building
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startBuild("build-only")
                }

                Text {
                  anchors.centerIn: parent
                  text: "🔨 仅远程构建"
                  color: root.colors.text
                  font.pixelSize: Style.font.caption
                }
              }

              // 按钮 2: 仅真机安装
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(30)
                radius: Style.space(4)
                color: b2Area.containsMouse ? root.colors.surface2 : root.colors.surface1

                MouseArea {
                  id: b2Area
                  anchors.fill: parent
                  enabled: !root.building
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startBuild("install-only")
                }

                Text {
                  anchors.centerIn: parent
                  text: "📲 仅真机安装"
                  color: root.colors.text
                  font.pixelSize: Style.font.caption
                }
              }

              // 按钮 3: 仅代码同步
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(30)
                radius: Style.space(4)
                color: b3Area.containsMouse ? root.colors.surface2 : root.colors.surface1

                MouseArea {
                  id: b3Area
                  anchors.fill: parent
                  enabled: !root.building
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startBuild("sync-only")
                }

                Text {
                  anchors.centerIn: parent
                  text: "🔄 仅同步代码"
                  color: root.colors.text
                  font.pixelSize: Style.font.caption
                }
              }

              // 按钮 4: 清理构建
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(30)
                radius: Style.space(4)
                color: b4Area.containsMouse ? root.colors.surface2 : root.colors.surface1

                MouseArea {
                  id: b4Area
                  anchors.fill: parent
                  enabled: !root.building
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startBuild("clean")
                }

                Text {
                  anchors.centerIn: parent
                  text: "🧹 深度清理缓存"
                  color: root.colors.text
                  font.pixelSize: Style.font.caption
                }
              }

              // 按钮 5: 安装三方依赖
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(30)
                radius: Style.space(4)
                color: b5Area.containsMouse ? root.colors.surface2 : root.colors.surface1

                MouseArea {
                  id: b5Area
                  anchors.fill: parent
                  enabled: !root.building
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startBuild("deps")
                }

                Text {
                  anchors.centerIn: parent
                  text: "📦 安装依赖 (ohpm)"
                  color: root.colors.text
                  font.pixelSize: Style.font.caption
                }
              }

              // 按钮 6: 中止构建 (或终端打开)
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(30)
                radius: Style.space(4)
                color: root.building
                  ? (b6Area.containsMouse ? root.colors.maroon : root.colors.red)
                  : (b6Area.containsMouse ? root.colors.surface2 : root.colors.surface1)

                MouseArea {
                  id: b6Area
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.building) {
                      root.cancelBuild()
                    } else {
                      root.runInTerminal()
                    }
                  }
                }

                Text {
                  anchors.centerIn: parent
                  text: root.building ? "⏹ 中止构建" : "🖥 终端中执行"
                  color: root.building ? root.colors.crust : root.colors.text
                  font.pixelSize: Style.font.caption
                  font.bold: root.building
                }
              }
            }
          }

          // -----------------------------------------------------------------
          // 5. 实时输出日志窗口
          // -----------------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: Style.space(20)

              Text {
                anchors.left: parent.left
                anchors.right: logBtns.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "📋 构建日志" + (root.buildStage ? (" — " + root.buildStage) : "")
                color: root.colors.subtext1
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
              }

              Row {
                id: logBtns
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(60)
                  height: Style.space(20)
                  radius: Style.space(3)
                  color: clearLogArea.containsMouse ? root.colors.surface2 : root.colors.surface0

                  MouseArea {
                    id: clearLogArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.buildLogs = []
                  }

                  Text {
                    anchors.centerIn: parent
                    text: "清空日志"
                    color: root.colors.subtext0
                    font.pixelSize: Style.font.caption * 0.85
                  }
                }

                Rectangle {
                  width: Style.space(76)
                  height: Style.space(20)
                  radius: Style.space(3)
                  color: openLogArea.containsMouse ? root.colors.surface2 : root.colors.surface0

                  MouseArea {
                    id: openLogArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      Quickshell.execDetached([
                        "sh", "-c",
                        "command -v xdg-open >/dev/null && xdg-open \"$HOME/.cache/harmony/remote-build.log\""
                      ])
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    text: "查看完整日志"
                    color: root.colors.subtext0
                    font.pixelSize: Style.font.caption * 0.85
                  }
                }
              }
            }

            // 日志框
            Rectangle {
              width: parent.width
              height: Style.space(180)
              radius: Style.space(6)
              color: root.colors.crust
              border.color: root.colors.surface0
              border.width: 1
              clip: true

              ListView {
                id: logListView
                anchors.fill: parent
                anchors.margins: Style.space(6)
                clip: true
                model: root.buildLogs
                spacing: Style.space(2)
                boundsBehavior: Flickable.StopAtBounds

                ScrollBar.vertical: ScrollBar {
                  policy: ScrollBar.AsNeeded
                }

                delegate: Text {
                  width: logListView.width
                  text: modelData
                  color: {
                    if (modelData.indexOf("[ERROR]") !== -1 || modelData.indexOf("失败") !== -1) return root.colors.red
                    if (modelData.indexOf("[WARN]") !== -1) return root.colors.yellow
                    if (modelData.indexOf("===>") !== -1 || modelData.indexOf("[INFO]") !== -1) return root.colors.blue
                    if (modelData.indexOf("✨") !== -1 || modelData.indexOf("成功") !== -1) return root.colors.green
                    return root.colors.subtext0
                  }
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption * 0.85
                  wrapMode: Text.WrapAnywhere
                }

                onCountChanged: {
                  Qt.callLater(function() {
                    logListView.positionViewAtEnd()
                  })
                }
              }

              // 空日志提示
              Text {
                visible: root.buildLogs.length === 0
                anchors.centerIn: parent
                text: "暂无构建日志，点击上方按钮开始构建"
                color: root.colors.overlay0
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
