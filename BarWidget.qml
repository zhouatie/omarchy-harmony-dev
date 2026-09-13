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
  readonly property string gitScriptPath: pluginDir + "/scripts/check-git.py"

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

  // Git 状态属性
  property bool gitChecking: false
  property bool gitOk: false
  property string gitShellBranch: ""
  property bool gitShellClean: true
  property int gitShellModified: 0
  property int gitShellUntracked: 0
  property int gitShellAhead: 0
  property int gitShellBehind: 0
  property var gitShellFiles: []

  property bool gitLibsExists: false
  property string gitLibsDirName: "libs_source"
  property int gitLibsTotal: 0
  property bool gitLibsClean: true
  property int gitLibsDirtyCount: 0
  property int gitLibsBehindCount: 0
  property int gitLibsAheadCount: 0
  property var gitLibsChangedRepos: []
  property var gitLibsCleanRepos: []
  property bool showCleanRepos: false
  property string hoveredRepoDetails: ""
  property bool showAllGitLibs: false
  property int expandAllTrigger: 0
  property bool expandAllValue: true

  // 视图切换: "main" (构建管理控制台) | "git" (Git 仓库与改动详情面板)
  property string currentView: "main"

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
  function open() { root.panelOpen = true; root.refreshStatus(); root.refreshGitStatus(false); }
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
      if (root.gitShellBranch) {
        var tags = []
        if (root.gitShellClean) tags.push("工作区干净")
        else tags.push("有未提交改动")
        if (root.gitShellBehind > 0) tags.push("需 pull " + root.gitShellBehind)
        if (root.gitLibsDirtyCount > 0) tags.push(root.gitLibsDirtyCount + " 子仓改动")
        if (root.gitLibsBehindCount > 0) tags.push(root.gitLibsBehindCount + " 子仓需 pull")
        lines.push("• Git 状态: " + root.gitShellBranch + " (" + tags.join(" · ") + ")")
      }
    } else {
      lines.push("• 当前工程: 未检测到 (可在面板中指定)")
    }
    if (root.building) {
      lines.push("• 状态: 正在构建 (" + root.buildElapsedSeconds + "s) - " + root.buildStage)
    }
    lines.push("点击: 打开控制面板 · 右键: 刷新环境与Git")
    return lines.join("\n")
  }

  // IPC 控制协议支持
  IpcHandler {
    target: "harmony.dev"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refreshStatus(); root.refreshGitStatus(false); }
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
    onTriggered: {
      root.refreshStatus()
      root.refreshGitStatus(false)
    }
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

  // 刷新 Git 状态 (超轻量纯本地无网络开销，可选 doFetch=true 手动拉取远端引用)
  function refreshGitStatus(doFetch) {
    if (gitStatusProc.running) return
    root.gitChecking = true
    var args = [root.gitScriptPath]
    var path = root.inputProjectPath || root.projectPath
    if (path) {
      args.push("--path", path)
    }
    if (doFetch) {
      args.push("--fetch")
    }
    gitStatusProc.command = args
    gitStatusProc.running = true
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
      root.appendLog("[WARN] 用户手动中止了构建进程。")
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
        root.refreshGitStatus(false)
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
        root.refreshGitStatus(false)
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
        if (!root.gitShellBranch && res.project_path) {
          root.refreshGitStatus(false)
        }
      } catch (e) {
        console.warn("HarmonyDev status error: " + e + ", raw: " + text)
      }
    }
  }

  // 进程：Git 状态探测
  Process {
    id: gitStatusProc
    running: false
    command: []
    stdout: StdioCollector {
      id: gitStatusCollector
      waitForEnd: true
    }
    onExited: function(code) {
      root.gitChecking = false
      if (code !== 0) return
      var text = gitStatusCollector.text.trim()
      if (!text) return
      try {
        var res = JSON.parse(text)
        root.gitOk = (res.ok === true)
        if (res.ok) {
          if (res.shell && res.shell.is_git) {
            root.gitShellBranch = res.shell.branch || ""
            root.gitShellClean = res.shell.clean === true
            root.gitShellModified = res.shell.modified || 0
            root.gitShellUntracked = res.shell.untracked || 0
            root.gitShellAhead = res.shell.ahead || 0
            root.gitShellBehind = res.shell.behind || 0
            root.gitShellFiles = res.shell.files || []
          } else {
            root.gitShellBranch = ""
            root.gitShellClean = true
            root.gitShellModified = 0
            root.gitShellUntracked = 0
            root.gitShellAhead = 0
            root.gitShellBehind = 0
            root.gitShellFiles = []
          }
          if (res.libs) {
            root.gitLibsExists = (res.libs.exists === true)
            root.gitLibsDirName = res.libs.dir_name || "libs_source"
            root.gitLibsTotal = res.libs.total || 0
            root.gitLibsClean = (res.libs.clean === true)
            root.gitLibsDirtyCount = res.libs.dirty_count || 0
            root.gitLibsBehindCount = res.libs.behind_count || 0
            root.gitLibsAheadCount = res.libs.ahead_count || 0
            root.gitLibsChangedRepos = res.libs.changed_repos || []
            root.gitLibsCleanRepos = res.libs.clean_repos || []
          }
        }
      } catch (e) {
        console.warn("HarmonyDev git status parse error: " + e)
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
        root.appendLog("[SUCCESS] 流程执行完毕 (耗时: " + root.buildElapsedSeconds + "s)")
      } else {
        root.buildStatus = "失败"
        root.appendLog("[ERROR] 流程异常退出，退出码: " + code)
      }
      root.refreshStatus()
      root.refreshGitStatus(false)
    }
  }

  Component.onCompleted: {
    root.refreshConfig()
  }

  // =========================================================================
  // 顶栏按钮
  // =========================================================================
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "鸿蒙"
    tooltipText: root.tooltipInfo

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.refreshStatus()
        root.refreshGitStatus(false)
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
          root.refreshGitStatus(false)
        } else if (t === "Escape") {
          if (root.currentView === "git") {
            root.currentView = "main"
          } else {
            root.close()
          }
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
                width: Style.space(26)
                height: Style.space(26)
                radius: Style.space(6)
                color: root.colors.surface0
                anchors.verticalCenter: parent.verticalCenter

                HarmonyIcon {
                  anchors.centerIn: parent
                  iconSize: Style.space(15)
                  color: root.colors.blue
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
                  onClicked: {
                    root.refreshStatus()
                    root.refreshGitStatus(false)
                  }
                }

                Text {
                  anchors.centerIn: parent
                  text: "\uf021"
                  color: refreshArea.containsMouse ? root.colors.text : root.colors.subtext0
                  font.family: "JetBrainsMono Nerd Font, monospace"
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
                  text: "\uf00d"
                  color: closeArea.containsMouse ? root.colors.text : root.colors.subtext0
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // -----------------------------------------------------------------
          // 视图切换 Tabs (构建控制台 vs Git 详细改动清单)
          // -----------------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            // Tab 1: 构建管理控制台
            Rectangle {
              height: Style.space(30)
              width: tab1Row.implicitWidth + Style.space(24)
              radius: Style.space(6)
              color: root.currentView === "main" ? root.colors.surface1 : root.colors.surface0
              border.color: root.currentView === "main" ? root.colors.blue : root.colors.surface1
              border.width: 1

              MouseArea {
                id: tab1Area
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentView = "main"
              }

              Row {
                id: tab1Row
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  text: "\uf0e3"
                  color: root.currentView === "main" ? root.colors.blue : root.colors.subtext0
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "构建管理"
                  color: root.currentView === "main" ? root.colors.text : root.colors.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: root.currentView === "main"
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            // Tab 2: Git 详情
            Rectangle {
              height: Style.space(30)
              width: tab2Row.implicitWidth + Style.space(24)
              radius: Style.space(6)
              color: root.currentView === "git" ? root.colors.surface1 : root.colors.surface0
              border.color: root.currentView === "git" ? root.colors.blue : root.colors.surface1
              border.width: 1

              MouseArea {
                id: tab2Area
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentView = "git"
              }

              Row {
                id: tab2Row
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  text: "\ue725"
                  color: root.currentView === "git" ? root.colors.blue : root.colors.subtext0
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "Git 仓库与改动详情"
                  color: root.currentView === "git" ? root.colors.text : root.colors.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: root.currentView === "git"
                  anchors.verticalCenter: parent.verticalCenter
                }

                // 改动计数徽章
                Rectangle {
                  visible: (root.gitLibsDirtyCount > 0 || !root.gitShellClean)
                  height: Style.space(16)
                  width: gitBadgeCountText.implicitWidth + Style.space(8)
                  radius: Style.space(8)
                  color: root.colors.peach
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: gitBadgeCountText
                    anchors.centerIn: parent
                    text: "" + ((root.gitShellClean ? 0 : 1) + root.gitLibsDirtyCount)
                    color: root.colors.crust
                    font.pixelSize: Style.font.caption * 0.75
                    font.bold: true
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.colors.surface1 }

          // -----------------------------------------------------------------
          // 视图 1: 构建管理控制台主视图 (当 currentView === "main")
          // -----------------------------------------------------------------
          Column {
            id: mainViewCol
            width: parent.width
            spacing: Style.space(12)
            visible: root.currentView === "main"

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
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "\uf108"
                    color: root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Rectangle {
                    width: Style.space(6)
                    height: Style.space(6)
                    radius: Style.space(3)
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
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "\uf10b"
                    color: root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Rectangle {
                    width: Style.space(6)
                    height: Style.space(6)
                    radius: Style.space(3)
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
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "\uf121"
                    color: root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Rectangle {
                    width: Style.space(6)
                    height: Style.space(6)
                    radius: Style.space(3)
                    color: root.projectOk ? root.colors.green : root.colors.peach
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: root.projectOk ? (root.projectName || "已识别工程") : "未检测到工程"
                    color: root.colors.text
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width - Style.space(36)
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

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    text: "\uf013"
                    color: root.colors.blue
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "参数配置 (直接在下方填写生效)"
                    color: root.colors.blue
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
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

                Item {
                  width: Style.space(14)
                  height: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: mainBtnIcon
                    anchors.centerIn: parent
                    text: root.building ? "\uf1ce" : "\uf04b"
                    color: root.colors.crust
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                  }

                  RotationAnimator {
                    target: mainBtnIcon
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                    running: root.building
                  }
                }

                Text {
                  text: root.building ? ("正在构建中... (" + root.buildElapsedSeconds + "s)") : "一键全流程构建并真机安装"
                  color: root.colors.crust
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
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
                height: Style.space(32)
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

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: "\uf0e3"
                    color: b1Area.containsMouse ? root.colors.text : root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "仅远程构建"
                    color: b1Area.containsMouse ? root.colors.text : root.colors.subtext1
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // 按钮 2: 仅真机安装
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(32)
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

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: "\uf10b"
                    color: b2Area.containsMouse ? root.colors.text : root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "仅真机安装"
                    color: b2Area.containsMouse ? root.colors.text : root.colors.subtext1
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // 按钮 3: 仅代码同步
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(32)
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

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: "\uf021"
                    color: b3Area.containsMouse ? root.colors.text : root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "仅同步代码"
                    color: b3Area.containsMouse ? root.colors.text : root.colors.subtext1
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // 按钮 4: 清理构建
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(32)
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

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: "\uf1f8"
                    color: b4Area.containsMouse ? root.colors.text : root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "深度清理缓存"
                    color: b4Area.containsMouse ? root.colors.text : root.colors.subtext1
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // 按钮 5: 安装三方依赖
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(32)
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

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: "\uf1b8"
                    color: b5Area.containsMouse ? root.colors.text : root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "安装依赖 (ohpm)"
                    color: b5Area.containsMouse ? root.colors.text : root.colors.subtext1
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // 按钮 6: 中止构建 (或终端打开)
              Rectangle {
                width: (parent.width - Style.space(12)) / 3
                height: Style.space(32)
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

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: root.building ? "\uf04d" : "\uf120"
                    color: root.building
                      ? root.colors.crust
                      : (b6Area.containsMouse ? root.colors.text : root.colors.subtext0)
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: root.building ? "中止构建" : "终端中执行"
                    color: root.building
                      ? root.colors.crust
                      : (b6Area.containsMouse ? root.colors.text : root.colors.subtext1)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: root.building
                    anchors.verticalCenter: parent.verticalCenter
                  }
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

              Row {
                anchors.left: parent.left
                anchors.right: logBtns.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Text {
                  text: "\uf120"
                  color: root.colors.subtext0
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "构建日志" + (root.buildStage ? (" — " + root.buildStage) : "")
                  color: root.colors.subtext1
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                }
              }

              Row {
                id: logBtns
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(68)
                  height: Style.space(22)
                  radius: Style.space(3)
                  color: clearLogArea.containsMouse ? root.colors.surface2 : root.colors.surface0

                  MouseArea {
                    id: clearLogArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.buildLogs = []
                  }

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)

                    Text {
                      text: "\uf1f8"
                      color: root.colors.subtext0
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: "清空"
                      color: root.colors.subtext0
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                Rectangle {
                  width: Style.space(88)
                  height: Style.space(22)
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

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)

                    Text {
                      text: "\uf08e"
                      color: root.colors.subtext0
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: "完整日志"
                      color: root.colors.subtext0
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
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
                    if (modelData.indexOf("[SUCCESS]") !== -1 || modelData.indexOf("成功") !== -1) return root.colors.green
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
        } // 关闭 mainViewCol

        // -------------------------------------------------------------------
        // 视图 2: Git 详细信息与代码改动清单视图 (当 currentView === "git")
        // -------------------------------------------------------------------
        Column {
          id: gitViewCol
          width: parent.width
          spacing: Style.space(12)
          visible: root.currentView === "git"

          // 1. 顶部操作与返回条
          Rectangle {
            width: parent.width
            height: Style.space(38)
            radius: Style.space(6)
            color: root.colors.surface0
            border.color: root.colors.surface1
            border.width: 1

            Item {
              anchors.fill: parent
              anchors.margins: Style.space(6)

              // 返回控制台按钮
              Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(26)
                width: backBtnRow.implicitWidth + Style.space(16)
                radius: Style.space(4)
                color: backBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                MouseArea {
                  id: backBtnArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.currentView = "main"
                }

                Row {
                  id: backBtnRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)
                  Text {
                    text: "\uf060"
                    color: root.colors.blue
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: "返回控制台"
                    color: root.colors.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // 右侧：检查远端 (Fetch) 与 刷新
              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Rectangle {
                  height: Style.space(26)
                  width: gitViewFetchText.implicitWidth + Style.space(14)
                  radius: Style.space(4)
                  color: gitViewFetchArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                  MouseArea {
                    id: gitViewFetchArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !root.gitChecking
                    onClicked: root.refreshGitStatus(true)
                  }

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Text {
                      text: "\uf0ed"
                      color: root.colors.subtext0
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      id: gitViewFetchText
                      text: "检查远端更新 (Fetch)"
                      color: root.colors.text
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                Rectangle {
                  width: Style.space(26)
                  height: Style.space(26)
                  radius: Style.space(4)
                  color: gitViewRefreshArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                  MouseArea {
                    id: gitViewRefreshArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !root.gitChecking
                    onClicked: root.refreshGitStatus(false)
                  }

                  Text {
                    id: gitViewRefreshIcon
                    anchors.centerIn: parent
                    text: "\uf021"
                    color: root.colors.text
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption
                  }

                  RotationAnimator {
                    target: gitViewRefreshIcon
                    from: 0
                    to: 360
                    duration: 800
                    loops: Animation.Infinite
                    running: root.gitChecking
                  }
                }
              }
            }
          }

          // 2. 壳工程详情卡片
          Rectangle {
            id: shellCardItem
            property bool isExpanded: true

            Connections {
              target: root
              function onExpandAllTriggerChanged() {
                shellCardItem.isExpanded = root.expandAllValue
              }
            }

            width: parent.width
            implicitHeight: shellDetailCol.implicitHeight + Style.space(18)
            radius: Style.space(6)
            color: root.colors.surface0
            border.color: root.gitShellClean ? root.colors.surface1 : root.colors.peach
            border.width: 1

            Column {
              id: shellDetailCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              // 标题与操作栏
              Item {
                width: parent.width
                height: Style.space(26)

                MouseArea {
                  anchors.fill: parent
                  anchors.rightMargin: shellTermBtnRect.width + Style.space(12)
                  hoverEnabled: true
                  cursorShape: (!root.gitShellClean && root.gitShellFiles.length > 0) ? Qt.PointingHandCursor : Qt.ArrowCursor
                  enabled: !root.gitShellClean && root.gitShellFiles.length > 0
                  onClicked: shellCardItem.isExpanded = !shellCardItem.isExpanded
                }

                Row {
                  anchors.left: parent.left
                  anchors.right: shellTermBtnRect.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    visible: !root.gitShellClean && root.gitShellFiles.length > 0
                    text: shellCardItem.isExpanded ? "\uf078" : "\uf054"
                    color: root.colors.subtext0
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption * 0.75
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "\uf121"
                    color: root.colors.blue
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "壳工程: " + (root.projectName || "HarmonyOS Project")
                    color: root.colors.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // 分支徽章
                  Rectangle {
                    height: Style.space(20)
                    width: shellDetailBranchRow.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: root.colors.surface2
                    anchors.verticalCenter: parent.verticalCenter

                    Row {
                      id: shellDetailBranchRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Text {
                        text: "\ue725"
                        color: root.colors.blue
                        font.family: "JetBrainsMono Nerd Font, monospace"
                        font.pixelSize: Style.font.caption * 0.8
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      Text {
                        text: root.gitShellBranch || "未识别分支"
                        color: root.colors.text
                        font.family: "JetBrainsMono Nerd Font, monospace"
                        font.pixelSize: Style.font.caption * 0.85
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }
                  }

                  // 状态徽章
                  Rectangle {
                    height: Style.space(20)
                    width: shellStateText.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: root.gitShellClean ? Qt.rgba(166/255, 227/255, 161/255, 0.15) : Qt.rgba(250/255, 179/255, 135/255, 0.15)
                    border.color: root.gitShellClean ? root.colors.green : root.colors.peach
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: shellStateText
                      anchors.centerIn: parent
                      text: root.gitShellClean ? "✓ 工作区干净" : ("! " + (root.gitShellModified + root.gitShellUntracked) + " 处未提交变更")
                      color: root.gitShellClean ? root.colors.green : root.colors.peach
                      font.pixelSize: Style.font.caption * 0.85
                      font.bold: true
                    }
                  }

                  // 需 pull
                  Rectangle {
                    visible: root.gitShellBehind > 0
                    height: Style.space(20)
                    width: shellBehindText2.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: Qt.rgba(249/255, 226/255, 175/255, 0.15)
                    border.color: root.colors.yellow
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: shellBehindText2
                      anchors.centerIn: parent
                      text: "↓ 需 pull " + root.gitShellBehind
                      color: root.colors.yellow
                      font.pixelSize: Style.font.caption * 0.85
                      font.bold: true
                    }
                  }
                }

                // 终端按钮
                Rectangle {
                  id: shellTermBtnRect
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(22)
                  width: shellTermBtnRow.implicitWidth + Style.space(12)
                  radius: Style.space(3)
                  color: shellTermBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                  MouseArea {
                    id: shellTermBtnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var p = root.inputProjectPath || root.projectPath
                      if (!p) return
                      Quickshell.execDetached([
                        "sh", "-c",
                        "command -v omarchy-launch-terminal >/dev/null && omarchy-launch-terminal bash -c \x27cd \x22" + p + "\x22 && git status; echo; read -p \x22按回车键退出...\x22\x27 || xdg-terminal-exec bash -c \x27cd \x22" + p + "\x22 && git status; echo; read -p \x22按回车键退出...\x22\x27"
                      ])
                    }
                  }

                  Row {
                    id: shellTermBtnRow
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Text {
                      text: "\uf120"
                      color: root.colors.subtext0
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.8
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      text: "终端查看"
                      color: root.colors.text
                      font.pixelSize: Style.font.caption * 0.8
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }

              // 壳工程文件变动列表
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: shellCardItem.isExpanded && !root.gitShellClean && root.gitShellFiles.length > 0

                Repeater {
                  model: root.gitShellFiles
                  delegate: Rectangle {
                    required property var modelData
                    required property int index

                    width: parent.width
                    height: Style.space(24)
                    radius: Style.space(3)
                    color: root.colors.mantle

                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(8)

                      Rectangle {
                        height: Style.space(16)
                        width: Style.space(22)
                        radius: Style.space(2)
                        color: (modelData.status === "M") ? root.colors.peach : ((modelData.status === "??") ? root.colors.blue : root.colors.red)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                          anchors.centerIn: parent
                          text: modelData.status || "M"
                          color: root.colors.crust
                          font.family: "JetBrainsMono Nerd Font, monospace"
                          font.pixelSize: Style.font.caption * 0.75
                          font.bold: true
                        }
                      }

                      Text {
                        text: modelData.path || ""
                        color: root.colors.text
                        font.family: "JetBrainsMono Nerd Font, monospace"
                        font.pixelSize: Style.font.caption * 0.85
                        elide: Text.ElideMiddle
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }
                  }
                }
              }
            }
          }

          // 3. 依赖子仓 (libs_source) 详细列表卡片
          Rectangle {
            width: parent.width
            implicitHeight: libsDetailListCol.implicitHeight + Style.space(18)
            radius: Style.space(6)
            color: root.colors.surface0
            border.color: root.colors.surface1
            border.width: 1

            Column {
              id: libsDetailListCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              // 标题栏
              Item {
                width: parent.width
                height: Style.space(26)

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: "\ue725"
                    color: root.colors.peach
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "依赖子仓改动清单 (" + (root.gitLibsDirName || "libs_source") + ")"
                    color: root.colors.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Rectangle {
                    height: Style.space(20)
                    width: libsDetailSummaryText.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: root.gitLibsClean ? Qt.rgba(166/255, 227/255, 161/255, 0.15) : Qt.rgba(250/255, 179/255, 135/255, 0.15)
                    border.color: root.gitLibsClean ? root.colors.green : root.colors.peach
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: libsDetailSummaryText
                      anchors.centerIn: parent
                      text: root.gitLibsClean ? "全部干净 ✓" : ("共 " + root.gitLibsTotal + " 个子仓 · " + root.gitLibsDirtyCount + " 个有改动")
                      color: root.gitLibsClean ? root.colors.green : root.colors.peach
                      font.pixelSize: Style.font.caption * 0.85
                      font.bold: true
                    }
                  }
                }

                // 全部折叠/展开快捷按钮
                Rectangle {
                  visible: root.gitLibsChangedRepos.length > 0
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(22)
                  width: toggleAllBtnRow.implicitWidth + Style.space(12)
                  radius: Style.space(3)
                  color: toggleAllBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                  MouseArea {
                    id: toggleAllBtnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.expandAllValue = !root.expandAllValue
                      root.expandAllTrigger++
                    }
                  }

                  Row {
                    id: toggleAllBtnRow
                    anchors.centerIn: parent
                    spacing: Style.space(4)

                    Text {
                      text: root.expandAllValue ? "\uf077" : "\uf078"
                      color: root.colors.subtext0
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.75
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: root.expandAllValue ? "全部折叠" : "全部展开"
                      color: root.colors.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption * 0.8
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }

              // 全部干净时的优雅占位
              Rectangle {
                visible: root.gitLibsClean
                width: parent.width
                height: Style.space(56)
                radius: Style.space(4)
                color: root.colors.mantle

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(8)
                  Text {
                    text: "\uf00c"
                    color: root.colors.green
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: "太棒了！所有 " + root.gitLibsTotal + " 个依赖子仓均无未提交文件，且与远端保持同步。"
                    color: root.colors.green
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // 变动仓库列表 (每个变动仓库独立精美卡片)
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.gitLibsChangedRepos.length > 0

                Repeater {
                  model: root.gitLibsChangedRepos
                  delegate: Rectangle {
                    id: repoCardItem
                    required property var modelData
                    required property int index

                    property bool isExpanded: true

                    Connections {
                      target: root
                      function onExpandAllTriggerChanged() {
                        repoCardItem.isExpanded = root.expandAllValue
                      }
                    }

                    width: parent.width
                    implicitHeight: singleRepoCol.implicitHeight + Style.space(16)
                    radius: Style.space(4)
                    color: root.colors.mantle
                    border.color: root.colors.surface1
                    border.width: 1

                    Column {
                      id: singleRepoCol
                      anchors.fill: parent
                      anchors.margins: Style.space(8)
                      spacing: Style.space(6)

                      // 仓库信息头部行
                      Item {
                        width: parent.width
                        height: Style.space(24)

                        MouseArea {
                          anchors.fill: parent
                          anchors.rightMargin: openTermBtnRect.width + Style.space(12)
                          hoverEnabled: true
                          cursorShape: Boolean(modelData.files && modelData.files.length > 0) ? Qt.PointingHandCursor : Qt.ArrowCursor
                          enabled: Boolean(modelData.files && modelData.files.length > 0)
                          onClicked: repoCardItem.isExpanded = !repoCardItem.isExpanded
                        }

                        Row {
                          anchors.left: parent.left
                          anchors.right: openTermBtnRect.left
                          anchors.rightMargin: Style.space(8)
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(8)

                          Text {
                            visible: Boolean(modelData.files && modelData.files.length > 0)
                            text: repoCardItem.isExpanded ? "\uf078" : "\uf054"
                            color: root.colors.subtext0
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.caption * 0.75
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          Text {
                            text: "\ue725"
                            color: root.colors.blue
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          // 仓库名 (加粗、清晰)
                          Text {
                            text: modelData.name || ""
                            color: root.colors.text
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          // 分支徽章
                          Rectangle {
                            height: Style.space(18)
                            width: subBranchBadgeRow.implicitWidth + Style.space(8)
                            radius: Style.space(3)
                            color: root.colors.surface1
                            anchors.verticalCenter: parent.verticalCenter

                            Row {
                              id: subBranchBadgeRow
                              anchors.centerIn: parent
                              spacing: Style.space(3)

                              Text {
                                text: "\ue725"
                                color: root.colors.blue
                                font.family: "JetBrainsMono Nerd Font, monospace"
                                font.pixelSize: Style.font.caption * 0.75
                                anchors.verticalCenter: parent.verticalCenter
                              }

                              Text {
                                text: modelData.branch || "unknown"
                                color: root.colors.subtext1
                                font.family: "JetBrainsMono Nerd Font, monospace"
                                font.pixelSize: Style.font.caption * 0.8
                                anchors.verticalCenter: parent.verticalCenter
                              }
                            }
                          }

                          // 改动状态徽章
                          Rectangle {
                            visible: Boolean(modelData.modified > 0 || modelData.untracked > 0)
                            height: Style.space(18)
                            width: subDirtyBadgeText.implicitWidth + Style.space(8)
                            radius: Style.space(3)
                            color: Qt.rgba(250/255, 179/255, 135/255, 0.15)
                            border.color: root.colors.peach
                            border.width: 1
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                              id: subDirtyBadgeText
                              anchors.centerIn: parent
                              text: (modelData.modified > 0 ? (modelData.modified + " 处修改") : "")
                                  + (modelData.modified > 0 && modelData.untracked > 0 ? " · " : "")
                                  + (modelData.untracked > 0 ? (modelData.untracked + " 未跟踪") : "")
                              color: root.colors.peach
                              font.pixelSize: Style.font.caption * 0.8
                              font.bold: true
                            }
                          }

                          // 需 pull 徽章
                          Rectangle {
                            visible: Boolean(modelData.behind > 0)
                            height: Style.space(18)
                            width: subBehindBadgeText.implicitWidth + Style.space(8)
                            radius: Style.space(3)
                            color: Qt.rgba(249/255, 226/255, 175/255, 0.15)
                            border.color: root.colors.yellow
                            border.width: 1
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                              id: subBehindBadgeText
                              anchors.centerIn: parent
                              text: "↓ 需 pull " + (modelData.behind || 0)
                              color: root.colors.yellow
                              font.pixelSize: Style.font.caption * 0.8
                              font.bold: true
                            }
                          }

                          // 待 push 徽章
                          Rectangle {
                            visible: Boolean(modelData.ahead > 0)
                            height: Style.space(18)
                            width: subAheadBadgeText.implicitWidth + Style.space(8)
                            radius: Style.space(3)
                            color: Qt.rgba(137/255, 180/255, 250/255, 0.15)
                            border.color: root.colors.blue
                            border.width: 1
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                              id: subAheadBadgeText
                              anchors.centerIn: parent
                              text: "↑ 待 push " + (modelData.ahead || 0)
                              color: root.colors.blue
                              font.pixelSize: Style.font.caption * 0.8
                            }
                          }
                        }

                        // 终端打开按钮
                        Rectangle {
                          id: openTermBtnRect
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          height: Style.space(20)
                          width: openTermBtnRow.implicitWidth + Style.space(10)
                          radius: Style.space(3)
                          color: openTermBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                          MouseArea {
                            id: openTermBtnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              var fullPath = (root.inputProjectPath || root.projectPath) + "/" + (root.gitLibsDirName || "libs_source") + "/" + modelData.name
                              Quickshell.execDetached([
                                "sh", "-c",
                                "command -v omarchy-launch-terminal >/dev/null && omarchy-launch-terminal bash -c \x27cd \x22" + fullPath + "\x22 && git status; echo; read -p \x22按回车键退出...\x22\x27 || xdg-terminal-exec bash -c \x27cd \x22" + fullPath + "\x22 && git status; echo; read -p \x22按回车键退出...\x22\x27"
                              ])
                            }
                          }

                          Row {
                            id: openTermBtnRow
                            anchors.centerIn: parent
                            spacing: Style.space(4)
                            Text {
                              text: "\uf120"
                              color: root.colors.subtext0
                              font.family: "JetBrainsMono Nerd Font, monospace"
                              font.pixelSize: Style.font.caption * 0.75
                              anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                              text: "终端打开"
                              color: root.colors.text
                              font.pixelSize: Style.font.caption * 0.75
                              anchors.verticalCenter: parent.verticalCenter
                            }
                          }
                        }
                      }

                      // 分隔线
                      Rectangle {
                        width: parent.width
                        height: 1
                        color: root.colors.surface1
                        visible: repoCardItem.isExpanded && Boolean(modelData.files && modelData.files.length > 0)
                      }

                      // 具体修改的文件列表
                      Column {
                        width: parent.width
                        spacing: Style.space(3)
                        visible: repoCardItem.isExpanded && Boolean(modelData.files && modelData.files.length > 0)

                        Repeater {
                          model: modelData.files || []
                          delegate: Rectangle {
                            required property var modelData
                            required property int index

                            width: parent.width
                            height: Style.space(22)
                            radius: Style.space(3)
                            color: fileRowArea.containsMouse ? root.colors.surface1 : root.colors.surface0

                            MouseArea {
                              id: fileRowArea
                              anchors.fill: parent
                              hoverEnabled: true
                            }

                            Row {
                              anchors.fill: parent
                              anchors.leftMargin: Style.space(6)
                              anchors.rightMargin: Style.space(6)
                              spacing: Style.space(6)

                              Rectangle {
                                height: Style.space(14)
                                width: Style.space(22)
                                radius: Style.space(2)
                                color: (modelData.status === "M") ? root.colors.peach : ((modelData.status === "??") ? root.colors.blue : root.colors.red)
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                  anchors.centerIn: parent
                                  text: modelData.status || "M"
                                  color: root.colors.crust
                                  font.family: "JetBrainsMono Nerd Font, monospace"
                                  font.pixelSize: Style.font.caption * 0.7
                                  font.bold: true
                                }
                              }

                              Text {
                                text: modelData.path || ""
                                color: root.colors.text
                                font.family: "JetBrainsMono Nerd Font, monospace"
                                font.pixelSize: Style.font.caption * 0.8
                                elide: Text.ElideMiddle
                                anchors.verticalCenter: parent.verticalCenter
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }

              // 其余干净子仓折叠栏
              Rectangle {
                visible: root.gitLibsCleanRepos.length > 0
                width: parent.width
                implicitHeight: cleanReposCol.implicitHeight + Style.space(12)
                radius: Style.space(4)
                color: root.colors.mantle
                border.color: root.colors.surface1
                border.width: 1

                Column {
                  id: cleanReposCol
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(6)

                  // 折叠栏标题
                  Item {
                    width: parent.width
                    height: Style.space(24)

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.showCleanRepos = !root.showCleanRepos
                    }

                    Row {
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)

                      Text {
                        text: root.showCleanRepos ? "\uf078" : "\uf054"
                        color: root.colors.blue
                        font.family: "JetBrainsMono Nerd Font, monospace"
                        font.pixelSize: Style.font.caption * 0.8
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        text: "其余 " + root.gitLibsCleanRepos.length + " 个干净子仓 (分支已与远端同步)"
                        color: root.colors.subtext0
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    Text {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.showCleanRepos ? "点击收起 ▲" : "点击展开查看分支 ▼"
                      color: root.colors.overlay0
                      font.pixelSize: Style.font.caption * 0.8
                    }
                  }

                  // 展开后的网格/流式列表
                  Flow {
                    visible: root.showCleanRepos
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                      model: root.gitLibsCleanRepos
                      delegate: Rectangle {
                        required property var modelData
                        required property int index

                        height: Style.space(22)
                        width: cleanChipRow.implicitWidth + Style.space(10)
                        radius: Style.space(3)
                        color: cleanChipArea.containsMouse ? root.colors.surface2 : root.colors.surface0

                        MouseArea {
                          id: cleanChipArea
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            var fullPath = (root.inputProjectPath || root.projectPath) + "/" + (root.gitLibsDirName || "libs_source") + "/" + modelData.name
                            Quickshell.execDetached([
                              "sh", "-c",
                              "command -v omarchy-launch-terminal >/dev/null && omarchy-launch-terminal bash -c \x27cd \x22" + fullPath + "\x22 && git status; echo; read -p \x22按回车键退出...\x22\x27 || xdg-terminal-exec bash -c \x27cd \x22" + fullPath + "\x22 && git status; echo; read -p \x22按回车键退出...\x22\x27"
                            ])
                          }
                        }

                        Row {
                          id: cleanChipRow
                          anchors.centerIn: parent
                          spacing: Style.space(4)

                          Text {
                            text: "\ue725"
                            color: root.colors.green
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.caption * 0.75
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          Text {
                            text: modelData.name
                            color: root.colors.text
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.caption * 0.8
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          Text {
                            text: modelData.branch ? ("(" + modelData.branch + ")") : ""
                            color: root.colors.subtext0
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.caption * 0.75
                            anchors.verticalCenter: parent.verticalCenter
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        }
      }
    }
  }
}
