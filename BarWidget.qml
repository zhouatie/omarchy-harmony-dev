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
  property string currentBuildMode: ""
  property var buildLogs: []
  property int buildElapsedSeconds: 0
  property string logFeedback: ""
  property int buildErrorCount: 0
  readonly property string errorParserScriptPath: pluginDir + "/scripts/parse-build-errors.py"

  Timer {
    id: logFeedbackTimer
    interval: 2500
    repeat: false
    onTriggered: root.logFeedback = ""
  }

  function copyLastErrorForAi() {
    root.logFeedback = "已复制报错报告 (可直接发给 AI) ✓"
    logFeedbackTimer.restart()
    Quickshell.execDetached([
      "sh", "-c",
      "python3 \"" + root.errorParserScriptPath + "\" --copy 2>/dev/null || (cat \"$HOME/.cache/harmony/last-error.log\" 2>/dev/null | (wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null))"
    ])
  }

  function copyAllLogs() {
    root.logFeedback = "已复制当前日志 ✓"
    logFeedbackTimer.restart()
    var text = root.buildLogs.join("\n")
    Quickshell.execDetached([
      "sh", "-c",
      "printf '%s' " + JSON.stringify(text) + " | (wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null)"
    ])
  }

  // 环境检测状态
  property bool sshOk: false
  property string macHost: "chenbolun@10.221.68.124"
  property bool deviceOnline: false
  property string deviceName: "离线"
  property string deviceIp: ""
  property string inputDeviceIp: ""
  property bool isWirelessDevice: false
  property bool deviceConnecting: false
  property bool projectOk: false
  property string projectPath: ""
  property string projectName: ""
  property string bundleName: ""

  // Git 状态属性
  property bool gitChecking: false
  property bool gitPulling: false
  property string pullingRepoName: ""
  property bool gitSyncingDeps: false
  property string syncingRepoName: ""
  property int depSwitchMismatchCount: 0
  property int depSwitchMissingCount: 0
  property string gitFeedback: ""
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

  // 视图切换: "main" (构建管理控制台) | "git" (Git 仓库与改动详情面板) | "mr" (未合并主干分支清单)
  property string currentView: "main"

  // 主干分支与待提 MR 状态
  property string trunkBranch: ""
  property string inputTrunkBranch: ""
  property int gitUnmergedCount: 0
  property var gitMrUnmergedList: []
  property var gitMrMergedList: []
  property string copyFeedback: ""

  Timer {
    id: copyFeedbackTimer
    interval: 2000
    onTriggered: root.copyFeedback = ""
  }
  function copyBranchName(branchName) {
    root.copyFeedback = "已复制: " + branchName
    copyFeedbackTimer.restart()
    Quickshell.execDetached([
      "sh", "-c",
      "printf '%s' '" + branchName + "' | (wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null)"
    ])
  }

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
    lines.push("• 本地设备: " + (root.deviceOnline ? (root.deviceName + (root.isWirelessDevice ? " (无线)" : " (USB)")) : "离线"))
    if (root.projectOk) {
      lines.push("• 当前工程: " + root.projectName + (root.bundleName ? (" (" + root.bundleName + ")") : ""))
      if (root.gitShellBranch) {
        var tags = []
        if (root.gitShellClean) tags.push("工作区干净")
        else tags.push("有未提交改动")
        if (root.gitShellBehind > 0) tags.push("需 pull " + root.gitShellBehind)
        if (root.gitLibsDirtyCount > 0) tags.push(root.gitLibsDirtyCount + " 子仓改动")
        if (root.gitLibsBehindCount > 0) tags.push(root.gitLibsBehindCount + " 子仓需 pull")
        if (root.depSwitchMismatchCount > 0) tags.push(root.depSwitchMismatchCount + " 子仓分支未对齐")
        if (root.depSwitchMissingCount > 0) tags.push(root.depSwitchMissingCount + " 子仓未克隆")
        if (root.gitUnmergedCount > 0) tags.push("待提MR " + root.gitUnmergedCount + " 仓")
        lines.push("• Git 状态: " + root.gitShellBranch + " (" + tags.join(" · ") + ")")
      }
    } else {
      lines.push("• 当前工程: 未检测到 (可在面板中指定)")
    }
    if (root.gitUnmergedCount > 0) {
      lines.push("• 待提 MR: " + root.gitUnmergedCount + " 个仓库包含未合并到主干的代码")
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
    function mr(): void { root.open(); root.currentView = "mr"; }
    function build(): void { root.startBuild("all") }
    function sync(): void { root.startBuild("sync-only") }
    function install(): void { root.startBuild("install-only") }
    function copyError(): void { root.copyLastErrorForAi() }
    function copyLog(): void { root.copyAllLogs() }
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

  // Git 操作提示倒计时
  Timer {
    id: gitFeedbackTimer
    interval: 3500
    repeat: false
    onTriggered: root.gitFeedback = ""
  }

  // 追加日志
  function appendLog(line) {
    if (!line) return
    var clean = line.replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, "").replace(/\r/g, "").trim()
    if (!clean) return

    // 过滤掉淹没真正报错的高频冗余插件消息
    if (clean.indexOf("Save generated file is true, skip deleting temporary files") !== -1) return

    if (clean.indexOf("===>") !== -1) {
      root.buildStage = clean.replace(/={3,}>\s*/, "").trim()
    }
    if (clean.indexOf("ArkTS Compiler Error") !== -1 || clean.indexOf("COMPILE RESULT:FAIL") !== -1 || clean.indexOf("BUILD FAILED") !== -1) {
      root.buildErrorCount += 1
    }
    var logs = root.buildLogs.slice()
    logs.push(clean)
    if (logs.length > 1200) logs.shift()
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
      trunkBranch: root.inputTrunkBranch,
      deviceIp: root.inputDeviceIp,
      autoInstall: root.autoInstall,
      autoLaunch: root.autoLaunch
    })
    saveConfigProc.command = [root.configScriptPath, "set", payload]
    saveConfigProc.running = true
  }

  // 刷新环境状态
  function refreshStatus() {
    if (statusProc.running) return
    var args = [
      root.statusScriptPath,
      "--host", root.inputMacHost,
      "--path", root.inputProjectPath
    ]
    if (root.inputDeviceIp) {
      args.push("--device-ip", root.inputDeviceIp)
    }
    statusProc.command = args
    statusProc.running = true
  }

  // 手动重连无线真机
  function reconnectDevice() {
    if (connectDeviceProc.running) return
    var ip = (root.inputDeviceIp || root.deviceIp || "").trim()
    if (!ip) {
      root.refreshStatus()
      return
    }
    root.deviceConnecting = true
    connectDeviceProc.command = [
      "sh", "-c",
      "export PATH=\"$HOME/.local/harmonyos/command-line-tools/bin:$PATH\"; hdc start >/dev/null 2>&1 || true; ip=\"" + ip + "\"; [[ \"$ip\" != *:* ]] && ip=\"$ip:5555\"; timeout 3 hdc tconn \"$ip\" >/dev/null 2>&1 || true"
    ]
    connectDeviceProc.running = true
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
    if (root.inputTrunkBranch) {
      args.push("--trunk", root.inputTrunkBranch)
    }
    if (doFetch) {
      args.push("--fetch")
    }
    gitStatusProc.command = args
    gitStatusProc.running = true
  }

  // 拉取更新 (repoName 为空时批量拉取所有落后仓库，非空时拉取指定仓库)
  function pullGitRepos(repoName) {
    if (gitStatusProc.running) return
    root.gitChecking = true
    root.gitPulling = true
    root.pullingRepoName = repoName || ""
    var args = [root.gitScriptPath]
    var path = root.inputProjectPath || root.projectPath
    if (path) {
      args.push("--path", path)
    }
    if (root.inputTrunkBranch) {
      args.push("--trunk", root.inputTrunkBranch)
    }
    if (repoName) {
      args.push("--pull-repo", repoName)
    } else {
      args.push("--pull")
    }
    gitStatusProc.command = args
    gitStatusProc.running = true
  }

  // 对齐 dep-switch 依赖 (repoName 为空时全量对齐，非空时对齐指定仓库)
  function syncDepSwitch(repoName) {
    if (gitStatusProc.running) return
    root.gitChecking = true
    root.gitSyncingDeps = true
    root.syncingRepoName = repoName || ""
    var args = [root.gitScriptPath]
    var path = root.inputProjectPath || root.projectPath
    if (path) {
      args.push("--path", path)
    }
    if (root.inputTrunkBranch) {
      args.push("--trunk", root.inputTrunkBranch)
    }
    if (repoName) {
      args.push("--sync-dep-repo", repoName)
    } else {
      args.push("--sync-deps")
    }
    gitStatusProc.command = args
    gitStatusProc.running = true
  }

  // 启动构建流程
  function startBuild(mode) {
    if (root.building) return
    root.building = true
    root.currentBuildMode = mode
    root.buildElapsedSeconds = 0
    root.buildStage = (mode === "install-only" ? "4. 检测真机并准备安装..." : (mode === "sync-only" ? "1. 同步工程源码..." : (mode === "deps" ? "安装主工程及子包依赖..." : "正在初始化...")))
    root.buildStatus = (mode === "install-only" ? "安装中..." : (mode === "sync-only" ? "同步中..." : (mode === "deps" ? "装依赖中..." : "构建中...")))
    root.buildErrorCount = 0
    root.logFeedback = ""
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
    if (root.inputDeviceIp) {
      args.push("--device-ip", root.inputDeviceIp)
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
      args.push("--deps-only")
    }

    buildProc.command = args
    buildProc.running = true
  }

  // 取消构建
  function cancelBuild() {
    if (buildProc.running) {
      buildProc.kill()
    }
    // 强制清理本地残留的 hm-build 及其子进程
    Quickshell.execDetached([
      "sh", "-c",
      "pkill -TERM -f 'hm-build.sh' 2>/dev/null || true"
    ])
    root.building = false
    root.buildStatus = "已中止"
    root.appendLog("[WARN] 用户手动中止了构建进程。")
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
        if (cfg.trunkBranch !== undefined) {
          root.inputTrunkBranch = cfg.trunkBranch
          root.trunkBranch = cfg.trunkBranch
        }
        if (cfg.deviceIp !== undefined) {
          root.inputDeviceIp = cfg.deviceIp
          root.deviceIp = cfg.deviceIp
        }
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
        root.isWirelessDevice = res.is_wireless === true
        if (res.device_ip && !root.inputDeviceIp) {
          root.inputDeviceIp = res.device_ip
          root.deviceIp = res.device_ip
        }
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

  // 进程：无线设备手动重连
  Process {
    id: connectDeviceProc
    running: false
    command: []
    onExited: function(code) {
      root.deviceConnecting = false
      root.refreshStatus()
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
      var wasPulling = root.gitPulling
      var pulledTarget = root.pullingRepoName
      var wasSyncingDeps = root.gitSyncingDeps
      var syncingTarget = root.syncingRepoName
      root.gitPulling = false
      root.pullingRepoName = ""
      root.gitSyncingDeps = false
      root.syncingRepoName = ""
      if (code !== 0) return
      var text = gitStatusCollector.text.trim()
      if (!text) return
      try {
        var res = JSON.parse(text)
        root.gitOk = (res.ok === true)
        if (res.ok) {
          if (wasPulling && res.pull_results && res.pull_results.length > 0) {
            var successCount = 0
            var failCount = 0
            for (var i = 0; i < res.pull_results.length; i++) {
              if (res.pull_results[i].ok) successCount++
              else failCount++
            }
            var msg = ""
            if (failCount === 0) {
              msg = successCount === 1 ? "已拉取最新 ✓" : ("已拉取 " + successCount + " 仓 ✓")
            } else {
              msg = successCount + " 成功，" + failCount + " 失败"
            }
            root.gitFeedback = msg
            gitFeedbackTimer.restart()
            Quickshell.execDetached([
              "sh", "-c",
              "command -v omarchy-notification-send >/dev/null && omarchy-notification-send -g '\uf126' 'Git' '" + msg + "' || true"
            ])
          }
          if (wasSyncingDeps && res.sync_results && res.sync_results.length > 0) {
            var syncSuccess = 0
            var syncSkipped = 0
            var syncFailed = 0
            for (var si = 0; si < res.sync_results.length; si++) {
              var sr = res.sync_results[si]
              if (sr.ok) syncSuccess++
              else if (sr.skipped) syncSkipped++
              else syncFailed++
            }
            var sMsg = ""
            if (syncFailed === 0 && syncSkipped === 0) {
              var suffix = res.subpkg_deps_installed ? " (含子包依赖) ✓" : " ✓"
              sMsg = (syncSuccess === 1 ? ("依赖已对齐" + suffix) : ("已对齐 " + syncSuccess + " 仓" + suffix))
            } else if (syncFailed === 0) {
              sMsg = "对齐 " + syncSuccess + " 仓，" + syncSkipped + " 仓跳过(有修改)"
            } else {
              sMsg = syncSuccess + " 成功，" + syncSkipped + " 跳过，" + syncFailed + " 失败"
            }
            root.gitFeedback = sMsg
            gitFeedbackTimer.restart()
            Quickshell.execDetached([
              "sh", "-c",
              "command -v omarchy-notification-send >/dev/null && omarchy-notification-send -g '\uf126' 'Git 依赖对齐' '" + sMsg + "' || true"
            ])
          }
          if (res.dep_switch) {
            root.depSwitchMismatchCount = res.dep_switch.mismatch_count || 0
            root.depSwitchMissingCount = res.dep_switch.missing_count || 0
          } else {
            root.depSwitchMismatchCount = 0
            root.depSwitchMissingCount = 0
          }
          if (res.trunk_branch) {
            root.trunkBranch = res.trunk_branch
            if (!root.inputTrunkBranch) {
              root.inputTrunkBranch = res.trunk_branch
            }
          }
          if (res.mr_summary) {
            root.gitUnmergedCount = res.mr_summary.total_unmerged_repos || 0
            root.gitMrUnmergedList = res.mr_summary.unmerged_list || []
            root.gitMrMergedList = res.mr_summary.merged_feature_list || []
          }
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
                  text: {
                    if (!root.building) return root.buildStatus
                    var modeText = "构建中"
                    if (root.currentBuildMode === "install-only") modeText = "安装中"
                    else if (root.currentBuildMode === "sync-only") modeText = "同步中"
                    else if (root.currentBuildMode === "clean") modeText = "清理中"
                    else if (root.currentBuildMode === "deps") modeText = "装依赖"
                    return modeText + " " + root.buildElapsedSeconds + "s"
                  }
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

            // Tab 3: 待合主干 (MR)
            Rectangle {
              height: Style.space(30)
              width: tab3Row.implicitWidth + Style.space(24)
              radius: Style.space(6)
              color: root.currentView === "mr" ? root.colors.surface1 : root.colors.surface0
              border.color: root.currentView === "mr" ? root.colors.peach : root.colors.surface1
              border.width: 1

              MouseArea {
                id: tab3Area
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentView = "mr"
              }

              Row {
                id: tab3Row
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  text: "\uf126"
                  color: root.currentView === "mr" ? root.colors.peach : root.colors.subtext0
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "待合主干 (MR)"
                  color: root.currentView === "mr" ? root.colors.text : root.colors.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: root.currentView === "mr"
                  anchors.verticalCenter: parent.verticalCenter
                }

                // 待提 MR 计数徽章
                Rectangle {
                  visible: root.gitUnmergedCount > 0
                  height: Style.space(16)
                  width: mrBadgeCountText.implicitWidth + Style.space(8)
                  radius: Style.space(8)
                  color: root.colors.peach
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: mrBadgeCountText
                    anchors.centerIn: parent
                    text: "" + root.gitUnmergedCount
                    color: root.colors.crust
                    font.family: "JetBrainsMono Nerd Font, monospace"
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

            // 待提 MR 提醒横幅 (点击快速跳转 MR 面板)
            Rectangle {
              visible: root.gitUnmergedCount > 0
              width: parent.width
              height: Style.space(34)
              radius: Style.space(6)
              color: Qt.rgba(250/255, 179/255, 135/255, 0.12)
              border.color: root.colors.peach
              border.width: 1

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentView = "mr"
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                Text {
                  text: "\uf126"
                  color: root.colors.peach
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "待提 MR 提醒：检测到 " + root.gitUnmergedCount + " 个仓库有代码未合入主干 [" + (root.trunkBranch || "trunk") + "]"
                  color: root.colors.peach
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                  width: Style.space(1)
                  height: Style.space(1)
                }

                Text {
                  text: "点击查看待合并主干清单 →"
                  color: root.colors.blue
                  font.pixelSize: Style.font.caption * 0.9
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

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

            // 卡片 2: 真机设备
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
                    text: root.isWirelessDevice ? "\uf1eb" : "\uf10b"
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
                    text: root.deviceOnline ? (root.isWirelessDevice ? "无线真机在线" : "USB 真机在线") : "真机未连接"
                    color: root.colors.text
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  text: root.deviceOnline ? root.deviceName : (root.inputDeviceIp ? ("目标: " + root.inputDeviceIp) : "未连接")
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption * 0.9
                  elide: Text.ElideRight
                  width: parent.width - (root.inputDeviceIp ? Style.space(18) : 0)
                }
              }

              // 右上角无线重连微型按钮 (配置了无线 IP 时展示)
              Rectangle {
                visible: Boolean(root.inputDeviceIp)
                width: Style.space(20)
                height: Style.space(20)
                radius: Style.space(4)
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(6)
                color: reconnectBtnArea.containsMouse ? root.colors.surface2 : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: "\uf021"
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption * 0.9
                  color: root.deviceConnecting ? root.colors.blue : (reconnectBtnArea.containsMouse ? root.colors.text : root.colors.subtext0)
                  rotation: root.deviceConnecting ? 180 : 0
                  Behavior on rotation {
                    NumberAnimation { duration: 300 }
                  }
                }

                MouseArea {
                  id: reconnectBtnArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.reconnectDevice()
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

              // 输入项 4: 目标主干分支
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(90)
                  text: "目标主干分支:"
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                TextField {
                  id: trunkBranchInput
                  width: parent.width - Style.space(98)
                  height: Style.space(28)
                  text: root.inputTrunkBranch
                  onTextEdited: root.inputTrunkBranch = text
                  placeholderText: "如 " + (root.trunkBranch || "release-20260921 或 master") + " (留空将自动智能识别)"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.colors.text
                  selectionColor: root.colors.surface2
                  selectedTextColor: root.colors.text
                  placeholderTextColor: root.colors.overlay0
                  background: Rectangle {
                    radius: Style.space(4)
                    color: root.colors.mantle
                    border.color: trunkBranchInput.activeFocus ? root.colors.peach : root.colors.surface1
                    border.width: 1
                  }
                }
              }

              // 输入项 5: 设备无线 IP
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(90)
                  text: "设备无线 IP:"
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                TextField {
                  id: deviceIpInput
                  width: parent.width - Style.space(98)
                  height: Style.space(28)
                  text: root.inputDeviceIp
                  onTextEdited: root.inputDeviceIp = text
                  placeholderText: "如 192.168.1.100 (可选，支持自动静默重连)"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.colors.text
                  selectionColor: root.colors.surface2
                  selectedTextColor: root.colors.text
                  placeholderTextColor: root.colors.overlay0
                  background: Rectangle {
                    radius: Style.space(4)
                    color: root.colors.mantle
                    border.color: deviceIpInput.activeFocus ? root.colors.blue : root.colors.surface1
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
                  text: {
                    if (!root.building) return "一键全流程构建并真机安装"
                    if (root.buildStage) return root.buildStage + " (" + root.buildElapsedSeconds + "s)"
                    if (root.currentBuildMode === "install-only") return "正在真机安装... (" + root.buildElapsedSeconds + "s)"
                    if (root.currentBuildMode === "sync-only") return "正在同步代码... (" + root.buildElapsedSeconds + "s)"
                    return "正在构建中... (" + root.buildElapsedSeconds + "s)"
                  }
                  color: root.colors.crust
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideMiddle
                  maximumLineCount: 1
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
                    text: "安装依赖 (--all)"
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

            // 构建失败高亮诊断条 (带有一键复制报错给 AI)
            Rectangle {
              visible: root.buildStatus === "失败"
              width: parent.width
              height: Style.space(34)
              radius: Style.space(6)
              color: Qt.rgba(243/255, 139/255, 168/255, 0.12)
              border.color: root.colors.red
              border.width: 1

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                Text {
                  text: "\uf06a"
                  color: root.colors.red
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "构建未通过！已提取编译错误与排查信息"
                  color: root.colors.red
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                  width: Style.space(1)
                  height: Style.space(1)
                }

                Rectangle {
                  height: Style.space(24)
                  width: aiBannerBtnRow.implicitWidth + Style.space(14)
                  radius: Style.space(4)
                  color: aiBannerArea.containsMouse ? root.colors.red : root.colors.surface1
                  anchors.verticalCenter: parent.verticalCenter

                  MouseArea {
                    id: aiBannerArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.copyLastErrorForAi()
                  }

                  Row {
                    id: aiBannerBtnRow
                    anchors.centerIn: parent
                    spacing: Style.space(4)

                    Text {
                      text: "\uf0c5"
                      color: aiBannerArea.containsMouse ? root.colors.crust : root.colors.text
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: "复制报错给 AI"
                      color: aiBannerArea.containsMouse ? root.colors.crust : root.colors.text
                      font.pixelSize: Style.font.caption * 0.85
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            Item {
              width: parent.width
              height: Style.space(22)

              Row {
                anchors.left: parent.left
                anchors.right: logBtns.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Text {
                  text: "\uf120"
                  color: root.logFeedback ? root.colors.green : root.colors.subtext0
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.logFeedback ? root.logFeedback : ("构建日志" + (root.buildStage ? (" — " + root.buildStage) : ""))
                  color: root.logFeedback ? root.colors.green : root.colors.subtext1
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

                // 复制报错 (AI)
                Rectangle {
                  width: Style.space(96)
                  height: Style.space(22)
                  radius: Style.space(3)
                  color: copyAiArea.containsMouse
                    ? (root.buildStatus === "失败" ? root.colors.red : root.colors.surface2)
                    : (root.buildStatus === "失败" ? Qt.rgba(243/255, 139/255, 168/255, 0.22) : root.colors.surface0)
                  border.color: root.buildStatus === "失败" ? root.colors.red : root.colors.surface1
                  border.width: 1

                  MouseArea {
                    id: copyAiArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.copyLastErrorForAi()
                  }

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)

                    Text {
                      text: "\uf0c5"
                      color: copyAiArea.containsMouse
                        ? (root.buildStatus === "失败" ? root.colors.crust : root.colors.text)
                        : (root.buildStatus === "失败" ? root.colors.red : root.colors.subtext0)
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: "复制报错(AI)"
                      color: copyAiArea.containsMouse
                        ? (root.buildStatus === "失败" ? root.colors.crust : root.colors.text)
                        : (root.buildStatus === "失败" ? root.colors.red : root.colors.subtext0)
                      font.pixelSize: Style.font.caption * 0.85
                      font.bold: root.buildStatus === "失败"
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                // 复制日志
                Rectangle {
                  width: Style.space(68)
                  height: Style.space(22)
                  radius: Style.space(3)
                  color: copyLogArea.containsMouse ? root.colors.surface2 : root.colors.surface0

                  MouseArea {
                    id: copyLogArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.copyAllLogs()
                  }

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)

                    Text {
                      text: "\uf0ea"
                      color: root.colors.subtext0
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: "复制日志"
                      color: root.colors.subtext0
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                // 完整日志
                Rectangle {
                  width: Style.space(78)
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

          // 待提 MR 提醒条
          Rectangle {
            visible: root.gitUnmergedCount > 0
            width: parent.width
            height: Style.space(34)
            radius: Style.space(6)
            color: Qt.rgba(250/255, 179/255, 135/255, 0.12)
            border.color: root.colors.peach
            border.width: 1

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.currentView = "mr"
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: "\uf126"
                color: root.colors.peach
                font.family: "JetBrainsMono Nerd Font, monospace"
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: "待合主干：发现 " + root.gitUnmergedCount + " 个仓库包含未合入主干 [" + (root.trunkBranch || "trunk") + "] 的代码，请注意提 MR"
                color: root.colors.peach
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Item {
                width: Style.space(1)
                height: Style.space(1)
              }

              Text {
                text: "查看待提 MR 清单 →"
                color: root.colors.blue
                font.pixelSize: Style.font.caption * 0.9
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

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

              // 右侧：检查远端 (Fetch)、批量拉取 与 刷新
              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                // 提示信息
                Text {
                  visible: root.gitFeedback !== ""
                  text: root.gitFeedback
                  color: root.colors.green
                  font.pixelSize: Style.font.caption * 0.85
                  anchors.verticalCenter: parent.verticalCenter
                }

                // 检查远端
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
                      text: "检查远端"
                      color: root.colors.text
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                // 对齐依赖 (在配置了 dep-switch 时显示，若有未对齐或缺失则高亮)
                Rectangle {
                  visible: root.depSwitchMismatchCount > 0 || root.depSwitchMissingCount > 0 || (root.gitLibsExists && root.gitLibsTotal > 0)
                  height: Style.space(26)
                  width: gitViewSyncDepsText.implicitWidth + Style.space(14)
                  radius: Style.space(4)
                  color: gitViewSyncDepsArea.containsMouse ? root.colors.surface2 : root.colors.surface1
                  border.color: (root.depSwitchMismatchCount > 0 || root.depSwitchMissingCount > 0) ? root.colors.peach : root.colors.surface2
                  border.width: 1

                  MouseArea {
                    id: gitViewSyncDepsArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !root.gitChecking
                    onClicked: root.syncDepSwitch("")
                  }

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Text {
                      text: (root.gitSyncingDeps && !root.syncingRepoName) ? "\uf021" : "\uf0ec"
                      color: (root.depSwitchMismatchCount > 0 || root.depSwitchMissingCount > 0) ? root.colors.peach : root.colors.blue
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      id: gitViewSyncDepsText
                      text: (root.gitSyncingDeps && !root.syncingRepoName) ? "对齐中" : "对齐依赖"
                      color: root.colors.text
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                // 批量拉取 (仅在有仓库落后时显示)
                Rectangle {
                  visible: (root.gitLibsBehindCount > 0 || root.gitShellBehind > 0)
                  height: Style.space(26)
                  width: gitViewPullText.implicitWidth + Style.space(14)
                  radius: Style.space(4)
                  color: gitViewPullArea.containsMouse ? root.colors.surface2 : root.colors.surface1
                  border.color: root.colors.yellow
                  border.width: 1

                  MouseArea {
                    id: gitViewPullArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !root.gitChecking
                    onClicked: root.pullGitRepos("")
                  }

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Text {
                      text: "\uf019"
                      color: root.colors.yellow
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption * 0.85
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      id: gitViewPullText
                      text: (root.gitPulling && !root.pullingRepoName) ? "拉取中" : "批量拉取"
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
                  anchors.rightMargin: shellActionBtns.width + Style.space(12)
                  hoverEnabled: true
                  cursorShape: (!root.gitShellClean && root.gitShellFiles.length > 0) ? Qt.PointingHandCursor : Qt.ArrowCursor
                  enabled: !root.gitShellClean && root.gitShellFiles.length > 0
                  onClicked: shellCardItem.isExpanded = !shellCardItem.isExpanded
                }

                Row {
                  anchors.left: parent.left
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

                // 壳工程操作按钮
                Row {
                  id: shellActionBtns
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  // 拉取按钮
                  Rectangle {
                    visible: root.gitShellBehind > 0
                    height: Style.space(22)
                    width: shellPullBtnRow.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: shellPullBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1
                    border.color: root.colors.yellow
                    border.width: 1

                    MouseArea {
                      id: shellPullBtnArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      enabled: !root.gitChecking
                      onClicked: root.pullGitRepos("shell")
                    }

                    Row {
                      id: shellPullBtnRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Text {
                        text: "\uf019"
                        color: root.colors.yellow
                        font.family: "JetBrainsMono Nerd Font, monospace"
                        font.pixelSize: Style.font.caption * 0.75
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      Text {
                        text: (root.gitPulling && root.pullingRepoName === "shell") ? "拉取中" : "拉取"
                        color: root.colors.text
                        font.pixelSize: Style.font.caption * 0.75
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }
                  }

                  // 终端按钮
                  Rectangle {
                    id: shellTermBtnRect
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

                  Rectangle {
                    visible: root.depSwitchMismatchCount > 0
                    height: Style.space(20)
                    width: depMismatchBadgeText.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: Qt.rgba(249/255, 226/255, 175/255, 0.15)
                    border.color: root.colors.yellow
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: depMismatchBadgeText
                      anchors.centerIn: parent
                      text: "! " + root.depSwitchMismatchCount + " 仓分支未对齐"
                      color: root.colors.yellow
                      font.pixelSize: Style.font.caption * 0.85
                      font.bold: true
                    }
                  }

                  Rectangle {
                    visible: root.depSwitchMissingCount > 0
                    height: Style.space(20)
                    width: depMissingBadgeText.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: Qt.rgba(243/255, 139/255, 168/255, 0.15)
                    border.color: root.colors.red
                    border.width: 1
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: depMissingBadgeText
                      anchors.centerIn: parent
                      text: "! " + root.depSwitchMissingCount + " 仓未克隆"
                      color: root.colors.red
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
                          anchors.rightMargin: subActionBtnsRow.width + Style.space(12)
                          hoverEnabled: true
                          cursorShape: Boolean(modelData.files && modelData.files.length > 0) ? Qt.PointingHandCursor : Qt.ArrowCursor
                          enabled: Boolean(modelData.files && modelData.files.length > 0)
                          onClicked: repoCardItem.isExpanded = !repoCardItem.isExpanded
                        }

                        Row {
                          anchors.left: parent.left
                          anchors.right: subActionBtnsRow.left
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
                            color: Boolean(modelData.branch_mismatch) ? Qt.rgba(249/255, 226/255, 175/255, 0.15) : root.colors.surface1
                            border.color: Boolean(modelData.branch_mismatch) ? root.colors.yellow : "transparent"
                            border.width: Boolean(modelData.branch_mismatch) ? 1 : 0
                            anchors.verticalCenter: parent.verticalCenter

                            Row {
                              id: subBranchBadgeRow
                              anchors.centerIn: parent
                              spacing: Style.space(3)

                              Text {
                                text: "\ue725"
                                color: Boolean(modelData.branch_mismatch) ? root.colors.yellow : root.colors.blue
                                font.family: "JetBrainsMono Nerd Font, monospace"
                                font.pixelSize: Style.font.caption * 0.75
                                anchors.verticalCenter: parent.verticalCenter
                              }

                              Text {
                                text: modelData.is_missing ? ("未克隆 → " + (modelData.dep_branch || "未知")) : (modelData.branch_mismatch ? ((modelData.branch || "unknown") + " → " + modelData.dep_branch) : (modelData.branch || "unknown"))
                                color: Boolean(modelData.branch_mismatch) ? root.colors.yellow : root.colors.subtext1
                                font.family: "JetBrainsMono Nerd Font, monospace"
                                font.pixelSize: Style.font.caption * 0.8
                                font.bold: Boolean(modelData.branch_mismatch)
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

                        // 子仓操作按钮
                        Row {
                          id: subActionBtnsRow
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(6)

                          // 单仓对齐按钮 (在分支不一致或未克隆时显示)
                          Rectangle {
                            visible: Boolean(modelData.branch_mismatch || modelData.is_missing)
                            height: Style.space(20)
                            width: subSyncBtnRow.implicitWidth + Style.space(10)
                            radius: Style.space(3)
                            color: subSyncBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1
                            border.color: root.colors.yellow
                            border.width: 1

                            MouseArea {
                              id: subSyncBtnArea
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              enabled: !root.gitChecking
                              onClicked: root.syncDepSwitch(modelData.name)
                            }

                            Row {
                              id: subSyncBtnRow
                              anchors.centerIn: parent
                              spacing: Style.space(4)
                              Text {
                                text: (root.gitSyncingDeps && root.syncingRepoName === modelData.name) ? "\uf021" : "\uf0ec"
                                color: root.colors.yellow
                                font.family: "JetBrainsMono Nerd Font, monospace"
                                font.pixelSize: Style.font.caption * 0.75
                                anchors.verticalCenter: parent.verticalCenter
                              }
                              Text {
                                text: (root.gitSyncingDeps && root.syncingRepoName === modelData.name) ? "对齐中" : "对齐"
                                color: root.colors.text
                                font.pixelSize: Style.font.caption * 0.75
                                anchors.verticalCenter: parent.verticalCenter
                              }
                            }
                          }

                          // 单仓拉取按钮 (仅在 behind > 0 时显示)
                          Rectangle {
                            visible: Boolean(modelData.behind > 0)
                            height: Style.space(20)
                            width: subPullBtnRow.implicitWidth + Style.space(10)
                            radius: Style.space(3)
                            color: subPullBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1
                            border.color: root.colors.yellow
                            border.width: 1

                            MouseArea {
                              id: subPullBtnArea
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              enabled: !root.gitChecking
                              onClicked: root.pullGitRepos(modelData.name)
                            }

                            Row {
                              id: subPullBtnRow
                              anchors.centerIn: parent
                              spacing: Style.space(4)
                              Text {
                                text: "\uf019"
                                color: root.colors.yellow
                                font.family: "JetBrainsMono Nerd Font, monospace"
                                font.pixelSize: Style.font.caption * 0.75
                                anchors.verticalCenter: parent.verticalCenter
                              }
                              Text {
                                text: (root.gitPulling && root.pullingRepoName === modelData.name) ? "拉取中" : "拉取"
                                color: root.colors.text
                                font.pixelSize: Style.font.caption * 0.75
                                anchors.verticalCenter: parent.verticalCenter
                              }
                            }
                          }

                          // 终端打开按钮
                          Rectangle {
                            id: openTermBtnRect
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
        } // 关闭 gitViewCol

        // -------------------------------------------------------------------
        // 视图 3: 主仓与子仓未合并主干分支清单视图 (当 currentView === "mr")
        // -------------------------------------------------------------------
        Column {
          id: mrViewCol
          width: parent.width
          spacing: Style.space(12)
          visible: root.currentView === "mr"

          // 1. 顶部操作与主干分支配置条
          Rectangle {
            width: parent.width
            implicitHeight: mrTopItemCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: root.colors.surface0
            border.color: root.colors.surface1
            border.width: 1

            Column {
              id: mrTopItemCol
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              // 第一行：返回按钮、反馈与右侧刷新操作
              Item {
                width: parent.width
                height: Style.space(26)

                // 返回控制台按钮
                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(26)
                  width: mrBackBtnRow.implicitWidth + Style.space(16)
                  radius: Style.space(4)
                  color: mrBackBtnArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                  MouseArea {
                    id: mrBackBtnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.currentView = "main"
                  }

                  Row {
                    id: mrBackBtnRow
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

                // 复制成功提示
                Text {
                  anchors.centerIn: parent
                  visible: root.copyFeedback !== ""
                  text: root.copyFeedback
                  color: root.colors.green
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                // 右侧：检查远端 (Fetch) 与 刷新
                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Rectangle {
                    height: Style.space(26)
                    width: mrViewFetchText.implicitWidth + Style.space(14)
                    radius: Style.space(4)
                    color: mrViewFetchArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                    MouseArea {
                      id: mrViewFetchArea
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
                        id: mrViewFetchText
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
                    color: mrViewRefreshArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                    MouseArea {
                      id: mrViewRefreshArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      enabled: !root.gitChecking
                      onClicked: root.refreshGitStatus(false)
                    }

                    Text {
                      id: mrViewRefreshIcon
                      anchors.centerIn: parent
                      text: "\uf021"
                      color: root.colors.text
                      font.family: "JetBrainsMono Nerd Font, monospace"
                      font.pixelSize: Style.font.caption
                    }

                    RotationAnimator {
                      target: mrViewRefreshIcon
                      from: 0
                      to: 360
                      duration: 800
                      loops: Animation.Infinite
                      running: root.gitChecking
                    }
                  }
                }
              }

              // 第二行：目标主干分支设置与快捷切换
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  text: "对比目标主干:"
                  color: root.colors.subtext0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                TextField {
                  id: mrTrunkInput
                  width: Style.space(160)
                  height: Style.space(24)
                  text: root.inputTrunkBranch
                  onTextEdited: root.inputTrunkBranch = text
                  onAccepted: root.refreshGitStatus(false)
                  placeholderText: root.trunkBranch || "主干分支名"
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.caption * 0.9
                  color: root.colors.text
                  background: Rectangle {
                    radius: Style.space(3)
                    color: root.colors.mantle
                    border.color: mrTrunkInput.activeFocus ? root.colors.peach : root.colors.surface1
                    border.width: 1
                  }
                  anchors.verticalCenter: parent.verticalCenter
                }

                // 比对按钮
                Rectangle {
                  height: Style.space(24)
                  width: mrApplyText.implicitWidth + Style.space(12)
                  radius: Style.space(3)
                  color: mrApplyArea.containsMouse ? root.colors.peach : root.colors.surface2
                  anchors.verticalCenter: parent.verticalCenter

                  MouseArea {
                    id: mrApplyArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.refreshGitStatus(false)
                  }

                  Text {
                    id: mrApplyText
                    anchors.centerIn: parent
                    text: "比对"
                    color: mrApplyArea.containsMouse ? root.colors.crust : root.colors.text
                    font.pixelSize: Style.font.caption * 0.85
                    font.bold: true
                  }
                }

                // 快捷主干候选切换标签
                Row {
                  spacing: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter

                  Repeater {
                    model: ["release-20260921", "master", "main"]
                    delegate: Rectangle {
                      required property var modelData
                      required property int index

                      visible: Boolean(modelData !== root.inputTrunkBranch)
                      height: Style.space(20)
                      width: chipText.implicitWidth + Style.space(8)
                      radius: Style.space(3)
                      color: chipArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                      MouseArea {
                        id: chipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.inputTrunkBranch = modelData
                          root.refreshGitStatus(false)
                        }
                      }

                      Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: modelData
                        color: root.colors.subtext0
                        font.family: "JetBrainsMono Nerd Font, monospace"
                        font.pixelSize: Style.font.caption * 0.75
                      }
                    }
                  }
                }
              }
            }
          }

          // 2. 状态概要卡片
          Rectangle {
            width: parent.width
            height: Style.space(48)
            radius: Style.space(6)
            color: root.colors.surface0
            border.color: (root.gitUnmergedCount > 0) ? root.colors.peach : root.colors.green
            border.width: 1

            Row {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              Rectangle {
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.space(4)
                color: (root.gitUnmergedCount > 0) ? Qt.rgba(250/255, 179/255, 135/255, 0.18) : Qt.rgba(166/255, 227/255, 161/255, 0.18)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  text: (root.gitUnmergedCount > 0) ? "\uf126" : "\uf00c"
                  color: (root.gitUnmergedCount > 0) ? root.colors.peach : root.colors.green
                  font.family: "JetBrainsMono Nerd Font, monospace"
                  font.pixelSize: Style.font.body
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: (root.gitUnmergedCount > 0)
                    ? ("共 " + root.gitUnmergedCount + " 个仓库有未合入主干 [" + (root.trunkBranch || "trunk") + "] 的代码")
                    : ("太棒了！主仓及所有子仓均已合并到主干分支 [" + (root.trunkBranch || "trunk") + "]")
                  color: root.colors.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  text: (root.gitUnmergedCount > 0)
                    ? "基于主干分支拉取的开发分支代码尚未合并，请在上线前及时提交 MR，避免漏提。"
                    : "所有分支修改均已顺利合入主干，无遗漏的 Merge Request。"
                  color: root.colors.subtext0
                  font.pixelSize: Style.font.caption * 0.85
                }
              }
            }
          }

          // 3. 待提 MR 仓库清单 (每个仓库独立卡片)
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.gitMrUnmergedList.length > 0

            Repeater {
              model: root.gitMrUnmergedList
              delegate: Rectangle {
                id: mrRepoCard
                required property var modelData
                required property int index

                width: parent.width
                implicitHeight: mrRepoCardCol.implicitHeight + Style.space(16)
                radius: Style.space(6)
                color: root.colors.mantle
                border.color: root.colors.peach
                border.width: 1

                Column {
                  id: mrRepoCardCol
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(8)

                  // 第一行：仓库标识、待合入提交徽章与操作按钮
                  Item {
                    width: parent.width
                    height: Style.space(26)

                    Row {
                      anchors.left: parent.left
                      anchors.right: mrCardActionsRow.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(8)

                      // 仓库类型标签 (壳工程 vs 子仓)
                      Rectangle {
                        height: Style.space(20)
                        width: repoTypeTagText.implicitWidth + Style.space(10)
                        radius: Style.space(3)
                        color: modelData.is_shell ? Qt.rgba(137/255, 180/255, 250/255, 0.2) : Qt.rgba(249/255, 226/255, 175/255, 0.2)
                        border.color: modelData.is_shell ? root.colors.blue : root.colors.yellow
                        border.width: 1
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                          id: repoTypeTagText
                          anchors.centerIn: parent
                          text: modelData.is_shell ? "壳工程" : "子仓"
                          color: modelData.is_shell ? root.colors.blue : root.colors.yellow
                          font.pixelSize: Style.font.caption * 0.8
                          font.bold: true
                        }
                      }

                      // 仓库名称
                      Text {
                        text: modelData.name
                        color: root.colors.text
                        font.family: "JetBrainsMono Nerd Font, monospace"
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      // 未合入提交数徽章
                      Rectangle {
                        height: Style.space(20)
                        width: unmergedBadgeText.implicitWidth + Style.space(10)
                        radius: Style.space(3)
                        color: Qt.rgba(250/255, 179/255, 135/255, 0.2)
                        border.color: root.colors.peach
                        border.width: 1
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                          id: unmergedBadgeText
                          anchors.centerIn: parent
                          text: modelData.unmerged_count > 0 ? (modelData.unmerged_count + " 个待合提交") : "分支待合入"
                          color: root.colors.peach
                          font.pixelSize: Style.font.caption * 0.8
                          font.bold: true
                        }
                      }
                    }

                    // 右侧操作：复制分支名 + 终端打开
                    Row {
                      id: mrCardActionsRow
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)

                      // 复制分支名按钮
                      Rectangle {
                        height: Style.space(22)
                        width: copyBranchBtnRow.implicitWidth + Style.space(12)
                        radius: Style.space(3)
                        color: copyBranchArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                        MouseArea {
                          id: copyBranchArea
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.copyBranchName(modelData.branch)
                        }

                        Row {
                          id: copyBranchBtnRow
                          anchors.centerIn: parent
                          spacing: Style.space(4)
                          Text {
                            text: (root.copyFeedback.indexOf(modelData.branch) !== -1) ? "\uf00c" : "\uf0c5"
                            color: (root.copyFeedback.indexOf(modelData.branch) !== -1) ? root.colors.green : root.colors.subtext0
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.caption * 0.75
                            anchors.verticalCenter: parent.verticalCenter
                          }
                          Text {
                            text: (root.copyFeedback.indexOf(modelData.branch) !== -1) ? "已复制!" : "复制分支名"
                            color: (root.copyFeedback.indexOf(modelData.branch) !== -1) ? root.colors.green : root.colors.text
                            font.pixelSize: Style.font.caption * 0.75
                            anchors.verticalCenter: parent.verticalCenter
                          }
                        }
                      }

                      // 终端打开
                      Rectangle {
                        height: Style.space(22)
                        width: mrTermBtnRow.implicitWidth + Style.space(12)
                        radius: Style.space(3)
                        color: mrTermArea.containsMouse ? root.colors.surface2 : root.colors.surface1

                        MouseArea {
                          id: mrTermArea
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            var p = modelData.path
                            var t = root.trunkBranch || "master"
                            Quickshell.execDetached([
                              "sh", "-c",
                              "command -v omarchy-launch-terminal >/dev/null && omarchy-launch-terminal bash -c \x27cd \x22" + p + "\x22 && echo \x22=== " + modelData.name + " 未合入 " + t + " 的提交 ===\x22 && git log origin/" + t + "..HEAD --oneline -n 20 2>/dev/null || git log " + t + "..HEAD --oneline -n 20; echo; git status; echo; read -p \x22按回车键退出...\x22\x27 || xdg-terminal-exec bash -c \x27cd \x22" + p + "\x22 && git status; echo; read -p \x22按回车键退出...\x22\x27"
                            ])
                          }
                        }

                        Row {
                          id: mrTermBtnRow
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
                            text: "终端查看"
                            color: root.colors.text
                            font.pixelSize: Style.font.caption * 0.75
                            anchors.verticalCenter: parent.verticalCenter
                          }
                        }
                      }
                    }
                  }

                  // 第二行：分支流向与状态徽章
                  Flow {
                    width: parent.width
                    spacing: Style.space(6)

                    // 分支流向徽章 (feat/xxx -> trunk)
                    Rectangle {
                      height: Style.space(22)
                      width: branchFlowRow.implicitWidth + Style.space(12)
                      radius: Style.space(3)
                      color: root.colors.surface0
                      border.color: root.colors.surface1
                      border.width: 1

                      Row {
                        id: branchFlowRow
                        anchors.centerIn: parent
                        spacing: Style.space(6)

                        Text {
                          text: "\ue725"
                          color: root.colors.blue
                          font.family: "JetBrainsMono Nerd Font, monospace"
                          font.pixelSize: Style.font.caption * 0.8
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          text: modelData.branch
                          color: root.colors.text
                          font.family: "JetBrainsMono Nerd Font, monospace"
                          font.pixelSize: Style.font.caption * 0.85
                          font.bold: true
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          text: "➔"
                          color: root.colors.peach
                          font.pixelSize: Style.font.caption * 0.85
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          text: root.trunkBranch || "trunk"
                          color: root.colors.peach
                          font.family: "JetBrainsMono Nerd Font, monospace"
                          font.pixelSize: Style.font.caption * 0.85
                          font.bold: true
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }

                    // 待 push 徽章
                    Rectangle {
                      visible: Boolean(modelData.ahead > 0)
                      height: Style.space(22)
                      width: mrAheadText.implicitWidth + Style.space(10)
                      radius: Style.space(3)
                      color: Qt.rgba(137/255, 180/255, 250/255, 0.15)
                      border.color: root.colors.blue
                      border.width: 1

                      Text {
                        id: mrAheadText
                        anchors.centerIn: parent
                        text: "↑ 待 push " + (modelData.ahead || 0)
                        color: root.colors.blue
                        font.pixelSize: Style.font.caption * 0.8
                      }
                    }

                    // 未提交改动徽章
                    Rectangle {
                      visible: Boolean(modelData.dirty)
                      height: Style.space(22)
                      width: mrDirtyText.implicitWidth + Style.space(10)
                      radius: Style.space(3)
                      color: Qt.rgba(249/255, 226/255, 175/255, 0.15)
                      border.color: root.colors.yellow
                      border.width: 1

                      Text {
                        id: mrDirtyText
                        anchors.centerIn: parent
                        text: "! 有未提交变更"
                        color: root.colors.yellow
                        font.pixelSize: Style.font.caption * 0.8
                      }
                    }
                  }

                  // 第三行：提交列表 (直接展示需要合入的 commits)
                  Column {
                    width: parent.width
                    spacing: Style.space(4)
                    visible: Boolean(modelData.commits && modelData.commits.length > 0)

                    Repeater {
                      model: modelData.commits || []
                      delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: parent.width
                        height: Style.space(24)
                        radius: Style.space(3)
                        color: mrCommitRowArea.containsMouse ? root.colors.surface1 : root.colors.surface0

                        MouseArea {
                          id: mrCommitRowArea
                          anchors.fill: parent
                          hoverEnabled: true
                        }

                        Row {
                          anchors.fill: parent
                          anchors.leftMargin: Style.space(8)
                          anchors.rightMargin: Style.space(8)
                          spacing: Style.space(6)

                          Text {
                            text: "•"
                            color: root.colors.peach
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          Text {
                            id: commitHashText
                            text: {
                              var idx = modelData.indexOf(" ")
                              return idx > 0 ? modelData.substring(0, idx) : modelData
                            }
                            color: root.colors.peach
                            font.family: "JetBrainsMono Nerd Font, monospace"
                            font.pixelSize: Style.font.caption * 0.85
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          Text {
                            text: {
                              var idx = modelData.indexOf(" ")
                              return idx > 0 ? modelData.substring(idx + 1) : ""
                            }
                            color: root.colors.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption * 0.85
                            elide: Text.ElideRight
                            width: Math.max(10, parent.width - commitHashText.implicitWidth - Style.space(32))
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

          // 4. 已合入主干的开发分支仓库 (可折叠展示)
          Rectangle {
            visible: root.gitMrMergedList.length > 0
            width: parent.width
            implicitHeight: mrMergedCol.implicitHeight + Style.space(12)
            radius: Style.space(6)
            color: root.colors.mantle
            border.color: root.colors.surface1
            border.width: 1

            property bool isExpanded: false

            Column {
              id: mrMergedCol
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              Item {
                width: parent.width
                height: Style.space(24)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: parent.parent.parent.isExpanded = !parent.parent.parent.isExpanded
                }

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    text: parent.parent.parent.parent.isExpanded ? "\uf078" : "\uf054"
                    color: root.colors.green
                    font.family: "JetBrainsMono Nerd Font, monospace"
                    font.pixelSize: Style.font.caption * 0.8
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "已合并到主干的子分支仓库 (" + root.gitMrMergedList.length + " 个)"
                    color: root.colors.subtext0
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.parent.parent.parent.isExpanded ? "收起 ▲" : "展开查看已合入仓库 ▼"
                  color: root.colors.overlay0
                  font.pixelSize: Style.font.caption * 0.8
                }
              }

              Flow {
                visible: parent.parent.isExpanded
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: root.gitMrMergedList
                  delegate: Rectangle {
                    required property var modelData
                    required property int index

                    height: Style.space(22)
                    width: mergedChipRow.implicitWidth + Style.space(10)
                    radius: Style.space(3)
                    color: root.colors.surface0

                    Row {
                      id: mergedChipRow
                      anchors.centerIn: parent
                      spacing: Style.space(4)

                      Text {
                        text: "✓"
                        color: root.colors.green
                        font.pixelSize: Style.font.caption * 0.75
                        font.bold: true
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
                        text: "(" + modelData.branch + ")"
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

          // 5. 底部说明栏
          Rectangle {
            width: parent.width
            height: Style.space(30)
            radius: Style.space(4)
            color: "transparent"

            Text {
              anchors.centerIn: parent
              text: "其余 " + (root.gitLibsTotal + 1 - root.gitMrUnmergedList.length - root.gitMrMergedList.length) + " 个仓库直接处于主干分支 [" + (root.trunkBranch || "trunk") + "]，无需提 MR"
              color: root.colors.overlay0
              font.pixelSize: Style.font.caption * 0.8
            }
          }
        } // 关闭 mrViewCol
        }
      }
    }
  }
}
