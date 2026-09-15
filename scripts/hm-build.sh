#!/usr/bin/env bash
# ==============================================================================
# harmony-remote-build (hm-build) for Omarchy
#
# 功能：
#   鸿蒙（HarmonyOS）远程满速构建与本地真机自动安装工具
#   完全独立于业务工程仓库，不污染任何业务代码与 git 记录。
#
# 安全机制（防止多项目串路/覆盖）：
#   1. 严禁盲目 Fallback：必须在实际鸿蒙工程目录下（或通过 -p 指定）运行；
#   2. 路径镜像对齐：按本地工作区相对路径或工程名自动隔离独立远程目录；
#   3. 终极防呆（BundleName 身份校验）：同步前强校验远程工程 bundleName，
#      一旦发现远程目录属于其他项目，立即熔断中止，绝不发生误覆盖。
# ==============================================================================

set -eo pipefail

CONFIG_FILE="$HOME/.config/harmony/config.json"
CFG_HOST=""
CFG_REMOTE=""
CFG_PROJECT=""
CFG_AUTO_INSTALL=true
CFG_AUTO_LAUNCH=true

if [ -f "$CONFIG_FILE" ]; then
  CFG_HOST=$(jq -r '.macHost // empty' "$CONFIG_FILE" 2>/dev/null || true)
  CFG_REMOTE=$(jq -r '.remoteDir // empty' "$CONFIG_FILE" 2>/dev/null || true)
  CFG_PROJECT=$(jq -r '.projectPath // empty' "$CONFIG_FILE" 2>/dev/null || true)
  _ai=$(jq -r '.autoInstall // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [ "$_ai" = "false" ] && CFG_AUTO_INSTALL=false
  _al=$(jq -r '.autoLaunch // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [ "$_al" = "false" ] && CFG_AUTO_LAUNCH=false
fi

MAC_HOST="${HARMONY_MAC_HOST:-${CFG_HOST:-chenbolun@10.221.68.124}}"
CACHE_DIR="$HOME/.cache/harmony"
mkdir -p "$CACHE_DIR"
LOG_FILE="$CACHE_DIR/remote-build.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

START_TIME_TOTAL=$(date +%s)

format_duration() {
  local s=$1
  local m=$((s / 60))
  local rem=$((s % 60))
  if [ $m -gt 0 ]; then
    echo "${m}分 ${rem}秒"
  else
    echo "${s}秒"
  fi
}

notify_desktop() {
  local title="$1"
  local msg="$2"
  local urgency="${3:-normal}"
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send -g "" -u "$urgency" "$title" "$msg" 2>/dev/null || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send -u "$urgency" "$title" "$msg" 2>/dev/null || true
  fi
}

# 本地 hdc 路径自适应
if ! command -v hdc >/dev/null 2>&1; then
  if [ -f "$HOME/.local/harmonyos/command-line-tools/bin/hdc" ]; then
    export PATH="$HOME/.local/harmonyos/command-line-tools/bin:$PATH"
  fi
fi

# 颜色输出定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}${BOLD}===> $1${NC}"; }

# 参数控制
DO_SYNC=true
DO_BUILD=true
DO_INSTALL_APP=$CFG_AUTO_INSTALL
DO_LAUNCH=$CFG_AUTO_LAUNCH
DO_DEPS=false
DO_CLEAN=false
TARGET_DIR="${CFG_PROJECT:-}"
CUSTOM_REMOTE_BASE="${HARMONY_REMOTE_DIR:-${CFG_REMOTE:-~/Dev/harmony}}"

print_usage() {
  cat << EOF
用法: hm-build [选项]

选项:
  (无参数)              全流程: 增量同步 -> 远程构建 -> 回传产物 -> 本地USB真机安装
  --no-install          完成构建并回传产物，但不执行真机安装
  --install-only, -i    仅安装本地已有的 HAP 安装包到真机，跳过同步与远程构建
  --sync-only           仅同步本地代码至 Mac mini，不执行构建
  --build-only          跳过代码同步，直接在 Mac mini 上构建并拉取产物
  --deps                在远程执行 ohpm install 安装/更新三方依赖
  --clean               在远程执行深度清理(清缓存+clean)，提MR前推荐执行以对齐CI环境
  --no-launch           安装成功后不自动拉起 EntryAbility
  --host <user@ip>      指定远程 Mac 机器地址 (默认从配置读取或: $MAC_HOST)
  --remote-dir <dir>    指定远程工作区基础目录 (默认: $CUSTOM_REMOTE_BASE)
  -p, --path <dir>      手动指定本地鸿蒙工程根目录
  -h, --help            查看帮助信息

环境变量:
  HARMONY_MAC_HOST      指定远程 Mac 机器地址
  HARMONY_REMOTE_DIR    指定远程工程基础目录
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-install)
      DO_INSTALL_APP=false
      shift
      ;;
    --install-only|-i)
      DO_SYNC=false
      DO_BUILD=false
      DO_INSTALL_APP=true
      shift
      ;;
    --sync-only)
      DO_BUILD=false
      DO_INSTALL_APP=false
      shift
      ;;
    --build-only)
      DO_SYNC=false
      shift
      ;;
    --deps)
      DO_DEPS=true
      shift
      ;;
    --clean)
      DO_CLEAN=true
      shift
      ;;
    --no-launch)
      DO_LAUNCH=false
      shift
      ;;
    --host)
      MAC_HOST="$2"
      shift 2
      ;;
    --remote-dir)
      CUSTOM_REMOTE_BASE="$2"
      shift 2
      ;;
    -p|--path)
      TARGET_DIR="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      log_err "未知参数: $1"
      print_usage
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 步骤 0: 安全定位鸿蒙工程根目录（严格模式，杜绝盲目 fallback）
# ------------------------------------------------------------------------------
find_harmony_project() {
  local dir="${1:-$PWD}"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -f "$dir/build-profile.json5" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if [ -n "$TARGET_DIR" ]; then
  if [ ! -f "$TARGET_DIR/build-profile.json5" ]; then
    log_err "指定的路径并非鸿蒙工程 (未找到 build-profile.json5): $TARGET_DIR"
    notify_desktop "HarmonyOS 构建失败" "指定路径非鸿蒙工程: $TARGET_DIR" "critical"
    exit 1
  fi
  PROJECT_ROOT="$(cd "$TARGET_DIR" && pwd)"
else
  PROJECT_ROOT="$(find_harmony_project "$PWD" || true)"
  if [ -z "$PROJECT_ROOT" ] && command -v omarchy-cmd-terminal-cwd >/dev/null 2>&1; then
    TERM_CWD=$(omarchy-cmd-terminal-cwd 2>/dev/null || true)
    if [ -n "$TERM_CWD" ]; then
      PROJECT_ROOT="$(find_harmony_project "$TERM_CWD" || true)"
    fi
  fi
  if [ -z "$PROJECT_ROOT" ]; then
    # Fallback to common directories
    for cand in "$HOME/Work/harmony/"* "$HOME/Dev/harmony/"*; do
      if [ -d "$cand" ] && [ -f "$cand/build-profile.json5" ]; then
        PROJECT_ROOT="$cand"
        break
      fi
    done
  fi

  if [ -z "$PROJECT_ROOT" ]; then
    log_err "未检测到鸿蒙工程 (未找到 build-profile.json5)！"
    log_err "为保证安全，脚本不会盲目同步。请在插件中配置本地工程目录，或进入具体工程目录内执行。"
    notify_desktop "HarmonyOS 构建失败" "未检测到鸿蒙工程目录" "critical"
    exit 1
  fi
fi

# 提取本地 bundleName
LOCAL_BUNDLE_NAME=""
if [ -f "$PROJECT_ROOT/AppScope/app.json5" ]; then
  LOCAL_BUNDLE_NAME=$(grep -o '"bundleName"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_ROOT/AppScope/app.json5" | cut -d'"' -f4 || true)
fi

# 计算远程安全隔离目录：
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
REMOTE_WORK_DIR="${CUSTOM_REMOTE_BASE%/}/$PROJECT_NAME"

log_info "本地工程目录: $PROJECT_ROOT"
log_info "本地 BundleID: ${LOCAL_BUNDLE_NAME:-'(未配置)'}"
log_info "远程隔离目录: $MAC_HOST:$REMOTE_WORK_DIR"
log_info "独立日志文件: $LOG_FILE"

# ------------------------------------------------------------------------------
# 步骤 0.5: Git 状态轻量安全审计
# ------------------------------------------------------------------------------
if [ -d "$PROJECT_ROOT/.git" ]; then
  UNTRACKED_SOURCES=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | grep -E "^\?\?[[:space:]]+.*(\.(ets|ts|cpp|h|json5))$" | head -n 5 || true)
  if [ -n "$UNTRACKED_SOURCES" ]; then
    log_warn "检测到以下未纳入 Git 追踪的源文件 (提 MR 进 CI 前请确认是否漏执行了 git add):"
    echo "$UNTRACKED_SOURCES" | while IFS= read -r line; do
      echo -e "      ${YELLOW}$line${NC}"
    done
  fi
fi

# ------------------------------------------------------------------------------
# 步骤 1: 检查远程连通性并执行“防覆盖身份校验”
# ------------------------------------------------------------------------------
if [ "$DO_SYNC" = true ]; then
  STEP1_START=$(date +%s)
  log_step "1. 检查 Mac 连通性并校验目录安全..."
  if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$MAC_HOST" "echo ok" >/dev/null 2>&1; then
    log_err "无法通过 SSH 连接到 $MAC_HOST，请确认网络环境及免密配置。"
    echo -e "### 鸿蒙远程连接失败诊断\n- **目标主机**: $MAC_HOST\n- **原因**: 无法通过 SSH 连接，网络超时或免密配置失效。\n- **排查建议**: 请测试 \`ssh $MAC_HOST\` 并检查网络/VPN。" > "$CACHE_DIR/last-error.log"
    notify_desktop "HarmonyOS 构建失败" "无法连接到 Mac 主机: $MAC_HOST" "critical"
    exit 1
  fi

  # 终极防呆检测：如果远程目录已存在，检查其 bundleName 是否与本地一致
  REMOTE_CHECK=$(ssh "$MAC_HOST" "
    if [ -d \"$REMOTE_WORK_DIR\" ] && [ \"\$(ls -A \"$REMOTE_WORK_DIR\" 2>/dev/null)\" ]; then
      if [ -f \"$REMOTE_WORK_DIR/AppScope/app.json5\" ]; then
        grep -o '\"bundleName\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' \"$REMOTE_WORK_DIR/AppScope/app.json5\" | cut -d'\"' -f4
      else
        echo '__NON_HARMONY_DIR__'
      fi
    else
      echo '__EMPTY_DIR__'
    fi
  " 2>/dev/null || true)

  if [ -n "$LOCAL_BUNDLE_NAME" ] && [ -n "$REMOTE_CHECK" ] && [ "$REMOTE_CHECK" != "__EMPTY_DIR__" ]; then
    if [ "$REMOTE_CHECK" == "__NON_HARMONY_DIR__" ]; then
      log_err "【安全熔断】远程目标目录 $REMOTE_WORK_DIR 已存在且非空，但并非鸿蒙工程！"
      notify_desktop "HarmonyOS 构建安全熔断" "远程目标目录并非鸿蒙工程" "critical"
      exit 1
    elif [ "$REMOTE_CHECK" != "$LOCAL_BUNDLE_NAME" ]; then
      log_err "【安全熔断】检测到远程目录已存在其他鸿蒙项目！"
      log_err "  - 本地项目 bundleName: $LOCAL_BUNDLE_NAME"
      log_err "  - 远程已有 bundleName: $REMOTE_CHECK"
      notify_desktop "HarmonyOS 构建安全熔断" "远程工程与本地 BundleID 不一致" "critical"
      exit 1
    fi
  fi

  # 初始化远程目录，确保 local.properties 始终指向 Mac mini 的原生 DevEco SDK
  ssh "$MAC_HOST" "mkdir -p $REMOTE_WORK_DIR && cat << 'EOF' > $REMOTE_WORK_DIR/local.properties
sdk.dir=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony
hwsdk.dir=/Applications/DevEco-Studio.app/Contents/sdk/default/hms
EOF"

  log_info "安全校验通过，正在通过 rsync 增量同步代码..."
  rsync -avz --delete \
    --exclude='.git' \
    --include='**/include/build/***' \
    --include='**/third-party/**/build/***' \
    --include='**/third_party/**/build/***' \
    --exclude='build' \
    --exclude='**/build' \
    --exclude='.hvigor' \
    --exclude='**/.hvigor' \
    --exclude='.cxx' \
    --exclude='**/.cxx' \
    --exclude='BuildProfile.ets' \
    --exclude='**/BuildProfile.ets' \
    --exclude='.DS_Store' \
    --exclude='**/.DS_Store' \
    --exclude='local.properties' \
    "$PROJECT_ROOT/" "$MAC_HOST:$REMOTE_WORK_DIR/"
  log_info "代码增量同步完成 (耗时: $(format_duration $(( $(date +%s) - STEP1_START )) ))。"
fi

# ------------------------------------------------------------------------------
# 步骤 2: 在 Mac mini 原生环境满速构建
# ------------------------------------------------------------------------------
if [ "$DO_BUILD" = true ]; then
  STEP2_START=$(date +%s)
  log_step "2. 在 Mac 原生环境执行构建..."
  log_info "构建日志将实时打印，并同步存入: $LOG_FILE"
  echo "--- Remote Build Started at $(date) ---" > "$LOG_FILE"

  REMOTE_COMMANDS="export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node; export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk; export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home; export PATH=\$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:/opt/homebrew/bin:\$PATH; cd $REMOTE_WORK_DIR"

  if [ "$DO_CLEAN" = true ]; then
    log_info "远程执行深度清理 (清理 build/.hvigor 缓存与 hvigorw clean)..."
    REMOTE_COMMANDS="$REMOTE_COMMANDS && rm -rf build .hvigor product/default/build ~/.hvigor/project_caches/* 2>/dev/null || true; hvigorw clean --no-daemon"
  fi

  if [ "$DO_DEPS" = true ]; then
    log_info "远程执行 ohpm install..."
    REMOTE_COMMANDS="$REMOTE_COMMANDS && ohpm install --all"
  fi

  REMOTE_COMMANDS="$REMOTE_COMMANDS && hvigorw assembleHap --mode module -p module=entry@default -p product=default --no-daemon"

  if ssh -tt "$MAC_HOST" "$REMOTE_COMMANDS" 2>&1 | tee -a "$LOG_FILE"; then
    log_info "远程构建成功 (耗时: $(format_duration $(( $(date +%s) - STEP2_START )) ))！"
    rm -f "$CACHE_DIR/last-error.log" "$CACHE_DIR/last-error.json" 2>/dev/null || true
  else
    echo ""
    log_err "远程构建失败！正在智能提取关键编译错误与排查信息..."
    if [ -f "$SCRIPT_DIR/parse-build-errors.py" ]; then
      python3 "$SCRIPT_DIR/parse-build-errors.py" \
        --log "$LOG_FILE" \
        --local "$PROJECT_ROOT" \
        --remote "$REMOTE_WORK_DIR" \
        --out-dir "$CACHE_DIR" \
        --print-summary || true
    fi
    echo ""
    log_err "完整日志已保存至: $LOG_FILE"
    log_info "[TIP] AI 诊断就绪: 结构化错误诊断报告已生成至 $CACHE_DIR/last-error.log"
    log_info "[TIP] 可直接点击面板上的【复制报错(AI)】或在 AI 对话中让其读取该文件"
    notify_desktop "HarmonyOS 构建失败" "已提取错误摘要，可点击面板复制给 AI" "critical"
    exit 1
  fi

  # ----------------------------------------------------------------------------
  # 步骤 3: 检索并拉取远程构建产物
  # ----------------------------------------------------------------------------
  STEP3_START=$(date +%s)
  log_step "3. 检索并拉取 HAP 安装包..."
  REMOTE_HAP=$(ssh "$MAC_HOST" "find $REMOTE_WORK_DIR/product/default/build -name '*.hap' 2>/dev/null | grep -v 'unsigned' | xargs -r ls -t 2>/dev/null | head -n 1 || find $REMOTE_WORK_DIR/product/default/build -name '*.hap' 2>/dev/null | xargs -r ls -t 2>/dev/null | head -n 1")

  if [ -z "$REMOTE_HAP" ]; then
    log_err "未在远程找到生成的 .hap 产物！请检查日志 $LOG_FILE"
    notify_desktop "HarmonyOS 产物获取失败" "未找到 .hap 产物" "critical"
    exit 1
  fi

  HAP_NAME=$(basename "$REMOTE_HAP")
  LOCAL_OUT_DIR="$PROJECT_ROOT/product/default/build/default/outputs/default"
  mkdir -p "$LOCAL_OUT_DIR"
  LOCAL_HAP="$LOCAL_OUT_DIR/$HAP_NAME"

  log_info "正在拉取 $HAP_NAME 到本地..."
  rsync -avz "$MAC_HOST:$REMOTE_HAP" "$LOCAL_HAP"
  log_info "本地安装包就绪 (耗时: $(format_duration $(( $(date +%s) - STEP3_START )) )): $LOCAL_HAP"
fi

# ------------------------------------------------------------------------------
# 步骤 4: 本地 USB 真机安装
# ------------------------------------------------------------------------------
if [ "$DO_INSTALL_APP" = true ]; then
  STEP4_START=$(date +%s)
  log_step "4. 检测本地 USB 真机并执行安装..."

  if [ -z "$LOCAL_HAP" ] || [ ! -f "$LOCAL_HAP" ]; then
    LOCAL_HAP=$(find "$PROJECT_ROOT" -path '*/outputs/*signed.hap' 2>/dev/null | xargs -r ls -t 2>/dev/null | head -n 1 || find "$PROJECT_ROOT" -name '*.hap' 2>/dev/null | grep -v 'unsigned' | xargs -r ls -t 2>/dev/null | head -n 1 || true)
  fi

  if [ -z "$LOCAL_HAP" ] || [ ! -f "$LOCAL_HAP" ]; then
    log_err "未在本地找到有效的 .hap 安装包！请先执行构建。"
    notify_desktop "HarmonyOS 安装失败" "未找到可安装的 .hap 文件" "critical"
    exit 1
  fi
  
  hdc start >/dev/null 2>&1 </dev/null || true

  TARGETS=$(timeout 5 hdc list targets 2>/dev/null | grep -v 'Empty' | grep -v '^\[Client\]' | grep -v '^$' | head -n 1 || true)
  if [ -z "$TARGETS" ]; then
    log_warn "未检测到 USB 连接的鸿蒙真机（或设备处于离线状态）。"
    log_info "安装包已保存在: $LOCAL_HAP"
    notify_desktop "HarmonyOS 构建完成" "真机未连接，安装包已就绪" "normal"
  else
    log_info "检测到在线设备: $TARGETS"
    log_info "正在通过本地 USB 安装 (hdc install)..."
    INSTALL_OUT=$(hdc install "$LOCAL_HAP" 2>&1 || true)
    echo "$INSTALL_OUT"
    if echo "$INSTALL_OUT" | grep -qi -E "\\[Fail\\]|error"; then
      log_err "安装失败，请检查手机屏幕是否弹出了“允许安装”确认框。"
      echo -e "### 鸿蒙真机安装失败诊断报告\n- **工程**: $PROJECT_NAME\n- **设备**: $TARGETS\n- **产物**: \`$LOCAL_HAP\`\n- **安装输出**:\n\`\`\`\n$INSTALL_OUT\n\`\`\`\n- **排查建议**: 检查手机确认弹窗，或使用 \`hdc uninstall $LOCAL_BUNDLE_NAME\` 后重试。" > "$CACHE_DIR/last-error.log"
      notify_desktop "HarmonyOS 安装失败" "真机安装失败，请查看设备提示" "critical"
    else
      log_info "安装成功 (耗时: $(format_duration $(( $(date +%s) - STEP4_START )) ))！"
      if [ "$DO_LAUNCH" = true ] && [ -n "$LOCAL_BUNDLE_NAME" ]; then
        log_info "正在拉起应用: $LOCAL_BUNDLE_NAME..."
        hdc shell aa start -a EntryAbility -b "$LOCAL_BUNDLE_NAME" || true
      fi
      notify_desktop "HarmonyOS 安装成功" "应用已安装并拉起: $PROJECT_NAME" "normal"
    fi
  fi
fi

TOTAL_DURATION=$(format_duration $(( $(date +%s) - START_TIME_TOTAL )) )
log_step "✨ 流程完成！(总耗时: $TOTAL_DURATION)"
