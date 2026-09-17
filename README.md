# HarmonyOS Remote Build Plugin for Omarchy (`harmony.dev`)

> 鸿蒙（HarmonyOS）远程满速构建与本地真机自动安装 Omarchy 状态栏插件。

完全独立于业务工程仓库，不污染任何业务代码与 Git 记录。支持远程 Mac mini 原生编译、代码双向增量同步、本地 USB 真机一键推送与自动拉起。

---

## ✨ 核心特性

- **直接在插件中配置参数**：
  - **远程主机**：直接在面板输入框填写 Mac IP/主机（如 `chenbolun@10.221.68.124`）。
  - **远程目录**：支持自定义 Mac 上的远程工作区基础路径（如 `~/Dev/harmony`）。
  - **本地工程路径**：可手动指定工程绝对路径，留空时**智能自动探测**当前活跃终端/工作目录下的鸿蒙工程（识别 `build-profile.json5`）。
  - **一键持久化保存**：点击「保存配置」即持久化写入 `~/.config/harmony/config.json`，面板与终端命令行（`hm-build`）全局共享。
- **环境实时感知卡片**：
  - 🖥️ **Mac 连通性**：毫秒级 SSH 状态监测与状态灯。
  - 📱 **USB 真机检测**：本地 `hdc` 连接状态与在线设备识别。
  - 📁 **本地工程识别**：实时识别当前工程名称与 `bundleName`。
- **主仓与子仓待提 MR / 未合并主干智能检测**：
  - **全量感知**：一网打尽主仓（壳工程）及几十个依赖子仓（`libs_source`）的开发子分支。
  - **精准比对**：自动识别迭代主干基线（如 `release-20260921`、`master` 等），支持自定义与快速切换比对目标。
  - **防漏提提醒**：在状态栏 Tooltip、主面板及 Git 面板多级高亮展示未合入主干的提交清单、分支流向及待提 MR 仓库数。
  - **一键辅助**：支持一键复制分支名、一键终端查看提交差异与状态。
- **一键快捷操作矩阵**：
  - 🚀 **一键全流程**：增量同步 -> Mac 原生满速构建 -> 回传产物 -> 本地 USB 真机安装 -> 自动拉起 App。
  - 🔨 **仅远程构建**：完成构建并拉取 HAP 安装包，不执行真机安装。
  - 📲 **仅真机安装**：跳过同步与远程构建，直接将本地已有 HAP 推送至真机。
  - 🔄 **仅同步代码**：仅通过 rsync 增量同步本地代码至 Mac mini。
  - 🧹 **深度清理 (Clean)**：远程清理 `.hvigor`、`build` 缓存与执行 clean。
  - 📦 **安装依赖 (--all)**：在本地与远程环境递归执行 `ohpm install --all`，安装主工程及全部子包依赖，并刷新 Hvigor 映射。
  - 🖥 **终端中运行**：在独立终端中拉起交互式构建进程。
  - ⏹ **安全中止**：构建过程中支持一键 kill 中止当前编译。
- **内置安全熔断机制**：
  - **防串路/防覆盖身份强校验**：同步前检查远程工程目录，比对 `bundleName`，一旦发现远程目录属于其他项目，立即安全熔断，绝不发生误覆盖。
  - **排除规则优化**：自动过滤 `build`、`.hvigor`、`.cxx` 等本地缓存，保留增量加速。
- **实时输出日志控制台**：
  - 插件内置暗色终端视窗，高亮关键步骤（`===>`、`[INFO]`、`[WARN]`、`[ERROR]`），支持实时滚屏与一键清空/打开完整日志文件。
- **桌面原生通知**：
  - 构建成功与失败通过 `omarchy-notification-send` 触发原生桌面弹窗提醒。

---

## 📁 目录结构

```text
harmony-dev/
├── manifest.json         # Omarchy 插件清单文件 (遵循 schemaVersion 1)
├── BarWidget.qml         # 顶栏图标按钮与下拉交互控制面板
├── scripts/
│   ├── hm-build.sh       # 鸿蒙远程构建核心引擎 (带配置自适应与桌面通知)
│   ├── check-status.sh   # 极速环境探测 (SSH / HDC / 工程检测)
│   └── config.sh         # 配置读取与合并写入工具 (~/.config/harmony/config.json)
├── .gitignore
└── README.md
```

---

## 🚀 安装与启用方法

### 方法 1: 软链接到本地 Omarchy 插件目录（推荐开发调试）

```bash
# 1. 链接到 omarchy 插件目录
mkdir -p ~/.config/omarchy/plugins
ln -s "$(pwd)" ~/.config/omarchy/plugins/harmony.dev

# 2. 重新扫描并启用插件
omarchy-shell shell rescanPlugins
omarchy plugin enable harmony.dev
```

### 方法 2: 通过 CLI 校验

```bash
omarchy plugin validate .
```

---

## ⚙️ 参数与配置文件

插件配置持久化保存在 `~/.config/harmony/config.json`，格式如下：

```json
{
  "macHost": "chenbolun@10.221.68.124",
  "remoteDir": "~/Dev/harmony",
  "projectPath": "/home/zhouatie/Work/harmony/CloudMusicHarmony",
  "trunkBranch": "release-20260921",
  "deviceIp": "192.168.1.100",
  "autoInstall": true,
  "autoLaunch": true
}
```

- **macHost**：远程编译机 SSH 地址。
- **remoteDir**：Mac 远程基础目录，每个工程会自动归纳在 `<remoteDir>/<工程名>` 下，互不冲突。
- **projectPath**：本地工程根目录（包含 `build-profile.json5`）。留空时将按当前打开的终端目录自动向上探测。
- **trunkBranch**：比对的目标主干分支名称（如 `release-20260921` 或 `master`）。留空时智能自动探测工程基线。
- **deviceIp**：真机无线调试 IP（如 `192.168.1.100` 或 `192.168.1.100:5555`）。配置后支持真机掉线时自动静默重连与面板一键重连。
- **autoInstall**：是否在构建完成后通过 USB / 无线网络自动安装到真机。
- **autoLaunch**：是否在安装完成后通过 HDC 自动拉起 `EntryAbility`。

---

## ⌨️ IPC 命令支持

支持通过终端或快捷键直接触发插件动作：

```bash
omarchy-shell harmony.dev open      # 打开控制面板
omarchy-shell harmony.dev close     # 关闭控制面板
omarchy-shell harmony.dev toggle    # 切换打开/关闭
omarchy-shell harmony.dev refresh   # 刷新当前环境与设备
omarchy-shell harmony.dev mr        # 打开未合主干 (MR) 清单面板
omarchy-shell harmony.dev build     # 直接触发全流程构建
omarchy-shell harmony.dev sync      # 触发增量同步
omarchy-shell harmony.dev install   # 触发真机安装
```
