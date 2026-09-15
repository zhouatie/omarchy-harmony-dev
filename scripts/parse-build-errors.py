#!/usr/bin/env python3
"""
HarmonyOS Build Error Parser & AI Diagnostic Formatter
Extracts ArkTS, Hvigor, CMake, C++, and ohpm errors from HarmonyOS remote build logs.
Converts remote paths to local workspace paths, formats clean Markdown for AI,
and provides one-click clipboard copying.
"""

import sys
import os
import re
import json
import argparse
import subprocess

def strip_ansi_and_controls(text: str) -> str:
    """Strip ANSI escape sequences, carriage returns, and null bytes."""
    clean = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
    clean = clean.replace("\r", "").replace("\x00", "")
    return clean

def parse_log_file(log_path: str, local_root: str = "", proj_name: str = ""):
    if not os.path.isfile(log_path):
        return {
            "ok": False,
            "error": f"Log file not found: {log_path}",
            "errors": [],
            "compile_result": "",
            "total": 0
        }

    with open(log_path, "rb") as f:
        raw = f.read().decode("utf-8", errors="replace")

    clean = strip_ansi_and_controls(raw)
    lines = clean.split("\n")

    arkts_re = re.compile(r"^(\d+)\s+ERROR:\s*(\d+)?\s*(ArkTS Compiler Error.*)?")
    error_msg_re = re.compile(r"^Error Message:\s*(.*)", re.I)
    at_file_re = re.compile(r"At File:\s*(.*):(\d+):(\d+)")
    general_error_re = re.compile(r"^(>\s*hvigor\s+ERROR:|ohpm\s+ERROR:|CMake\s+Error|clang\+\+:\s*error:|ld:\s*error:)(.*)", re.I)
    compile_fail_re = re.compile(r"COMPILE RESULT:\s*FAIL\s*(\{.*\})?", re.I)

    errors = []
    compile_result = ""
    build_failed_line = ""

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue

        if compile_fail_re.search(line):
            compile_result = line
            i += 1
            continue

        if "BUILD FAILED" in line and not build_failed_line:
            build_failed_line = line
            i += 1
            continue

        # Check ArkTS error
        m_ark = arkts_re.match(line)
        if m_ark:
            err_num = m_ark.group(1)
            err_code = m_ark.group(2) or ""
            msg_parts = []
            file_path = ""
            line_num = ""
            col_num = ""
            i += 1
            while i < len(lines):
                sub = lines[i].strip()
                if not sub:
                    i += 1
                    continue
                if arkts_re.match(sub) or compile_fail_re.search(sub) or sub.startswith("> hvigor") or "BUILD FAILED" in sub:
                    break

                m_file = at_file_re.search(sub)
                if m_file:
                    file_path = m_file.group(1).strip()
                    line_num = m_file.group(2).strip()
                    col_num = m_file.group(3).strip()
                    cleaned_sub = at_file_re.sub("", sub).strip()
                    if cleaned_sub:
                        m_m = error_msg_re.match(cleaned_sub)
                        msg_parts.append(m_m.group(1).strip() if m_m else cleaned_sub)
                    i += 1
                    break
                else:
                    m_msg = error_msg_re.match(sub)
                    if m_msg:
                        msg_parts.append(m_msg.group(1).strip())
                    else:
                        msg_parts.append(sub)
                i += 1

            full_msg = " ".join(msg_parts).strip()
            # Remote to local path translation
            rel_path = file_path
            local_path = file_path
            if proj_name and f"/{proj_name}/" in file_path:
                idx = file_path.find(f"/{proj_name}/")
                rel_path = file_path[idx + len(proj_name) + 2:]
                local_path = os.path.join(local_root, rel_path) if local_root else rel_path

            errors.append({
                "type": "ArkTS",
                "index": int(err_num) if err_num.isdigit() else len(errors) + 1,
                "code": err_code,
                "message": full_msg,
                "file": local_path,
                "rel_file": rel_path,
                "line": line_num,
                "col": col_num
            })
            continue

        # Check General build errors
        m_gen = general_error_re.match(line)
        if m_gen and "BUILD FAILED in" not in line:
            # Skip hvigor wrapper notices if ArkTS errors follow
            if "Failed :entry:default@CompileArkTS" in line or "ArkTS Compiler Error" in line:
                i += 1
                continue

            err_text = line
            detail_lines = []
            j = i + 1
            while j < min(len(lines), i + 4):
                next_text = lines[j].strip()
                if next_text.startswith("> hvigor") or "BUILD FAILED" in next_text:
                    break
                if next_text:
                    detail_lines.append(next_text)
                j += 1
            errors.append({
                "type": "Build",
                "index": len(errors) + 1,
                "code": "",
                "message": err_text + (" - " + " ".join(detail_lines) if detail_lines else ""),
                "file": "",
                "rel_file": "",
                "line": "",
                "col": ""
            })

        i += 1

    # Fallback if no specific errors matched but build failed
    if not errors and build_failed_line:
        tail_context = []
        for l in lines[-60:]:
            s = l.strip()
            if s and "Save generated file" not in s and "Connection to" not in s:
                tail_context.append(s)
        errors.append({
            "type": "Fatal",
            "index": 1,
            "code": "",
            "message": build_failed_line + "\n" + "\n".join(tail_context[-20:]),
            "file": "",
            "rel_file": "",
            "line": "",
            "col": ""
        })

    return {
        "ok": True,
        "errors": errors,
        "compile_result": compile_result,
        "build_failed": build_failed_line,
        "total": len(errors)
    }

def format_markdown_report(result: dict, project_name: str, local_root: str) -> str:
    """Format structured error results into an AI-ready Markdown report."""
    total = result.get("total", 0)
    errors = result.get("errors", [])
    compile_result = result.get("compile_result", "")
    build_failed = result.get("build_failed", "")

    lines = [
        "### 鸿蒙工程构建失败诊断报告 (HarmonyOS Build Diagnostic)",
        f"- **工程名称**: {project_name or 'HarmonyOS Project'}",
        f"- **本地根目录**: `{local_root or '未指定'}`",
        f"- **构建结果**: `{compile_result or build_failed or 'BUILD FAILED'}`",
        f"- **错误总数**: {total} 处错误",
        ""
    ]

    # Group by file
    by_file = {}
    general_errors = []
    for err in errors:
        f = err.get("rel_file") or err.get("file")
        if f:
            by_file.setdefault(f, []).append(err)
        else:
            general_errors.append(err)

    if by_file:
        lines.append("#### 详细错误清单 (按源文件与行号排查):")
        for f, err_list in by_file.items():
            lines.append(f"\n[文件] **`{f}`** ({len(err_list)} 处错误):")
            for e in err_list:
                loc = f"L{e['line']}:{e['col']}" if e.get("line") else ""
                code_tag = f"[{e['type']} {e['code']}]" if e.get("code") else f"[{e['type']}]"
                full_loc = f"`{e['file']}:{e['line']}:{e['col']}`" if (e.get('file') and e.get('line')) else ""
                lines.append(f"  - **{loc}** {code_tag} {e['message']}")
                if full_loc:
                    lines.append(f"    跳转定位: {full_loc}")

    if general_errors:
        lines.append("\n#### 通用构建任务错误:")
        for e in general_errors:
            lines.append(f"  - {e['message']}")

    lines.append("\n#### AI 排查建议方向:")
    msgs = " ".join([e.get("message", "") for e in errors])
    if "Cannot find module" in msgs:
        lines.append("- [ ] **缺失模块/依赖**: 存在未找到的模块声明，请检查对应子模块是否已在 `oh-package.json5` 中声明，或 `libs_source` 中对应仓库未拉取/未配置别名路径。")
    if "has no exported member" in msgs:
        lines.append("- [ ] **导出成员不匹配**: 引用的接口或常量未导出，请核对引用仓库分支是否与主工程版本对齐。")
    if "arkts-no-any-unknown" in msgs or "Use explicit types" in msgs:
        lines.append("- [ ] **ArkTS 严格类型检查**: 启用了 ArkTS 强类型约束，禁止隐式 `any` / `unknown`，需补全明确类型注解或接口定义。")
    if "does not meet UI component syntax" in msgs:
        lines.append("- [ ] **UI 组件语法规范**: 自定义组件传参格式不正确，或属性方法调用未按照 ArkUI 声明式规范书写。")

    return "\n".join(lines)

def format_terminal_summary(result: dict) -> str:
    """Format a compact terminal block for hm-build stdout and QML."""
    total = result.get("total", 0)
    errors = result.get("errors", [])

    lines = [
        "================================================================================",
        f"❌ 构建失败！自动提取出 {total} 处关键编译/构建错误：",
        "--------------------------------------------------------------------------------"
    ]

    shown = errors[:15]
    for e in shown:
        f = e.get("rel_file") or e.get("file")
        loc = f" ({f}:{e['line']}:{e['col']})" if f and e.get("line") else (f" ({f})" if f else "")
        code = f"[{e['code']}] " if e.get("code") else ""
        lines.append(f" • {code}{e['message']}{loc}")

    if total > 15:
        lines.append(f" ... 剩余 {total - 15} 处错误已被省略，请查看完整错误报告。")

    lines.append("================================================================================")
    return "\n".join(lines)

def copy_to_clipboard(content: str) -> bool:
    """Copy text to system clipboard using wl-copy or xclip."""
    for cmd in [["wl-copy"], ["xclip", "-selection", "clipboard"]]:
        try:
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
            p.communicate(input=content.encode("utf-8"))
            if p.returncode == 0:
                return True
        except FileNotFoundError:
            continue
    return False

def main():
    parser = argparse.ArgumentParser(description="HarmonyOS Build Error Parser")
    parser.add_argument("--log", default=os.path.expanduser("~/.cache/harmony/remote-build.log"), help="Path to remote-build.log")
    parser.add_argument("--local", default="", help="Local project root")
    parser.add_argument("--remote", default="", help="Remote project root")
    parser.add_argument("--out-dir", default=os.path.expanduser("~/.cache/harmony"), help="Output directory")
    parser.add_argument("--print-summary", action="store_true", help="Print summary block to stdout")
    parser.add_argument("--copy", action="store_true", help="Copy report to clipboard")
    parser.add_argument("--json", action="store_true", help="Output JSON")

    args = parser.parse_args()

    # Load config fallback if local root not supplied
    config_file = os.path.expanduser("~/.config/harmony/config.json")
    if not args.local and os.path.isfile(config_file):
        try:
            with open(config_file, "r") as cf:
                cfg = json.load(cf)
                if cfg.get("projectPath"):
                    args.local = cfg["projectPath"]
        except Exception:
            pass

    proj_name = os.path.basename(args.local.rstrip("/")) if args.local else ""

    # Parse
    parsed = parse_log_file(args.log, args.local, proj_name)

    # Format reports
    md_report = format_markdown_report(parsed, proj_name, args.local)
    term_summary = format_terminal_summary(parsed)

    # Save to out-dir
    os.makedirs(args.out_dir, exist_ok=True)
    out_error_log = os.path.join(args.out_dir, "last-error.log")
    out_error_json = os.path.join(args.out_dir, "last-error.json")

    with open(out_error_log, "w", encoding="utf-8") as f:
        f.write(md_report + "\n")

    with open(out_error_json, "w", encoding="utf-8") as f:
        json.dump(parsed, f, ensure_ascii=False, indent=2)

    if args.copy:
        success = copy_to_clipboard(md_report)
        if success:
            print("✓ 错误报告已成功复制到剪贴板！")
        else:
            print("✗ 复制到剪贴板失败，请手动查看: " + out_error_log)

    if args.print_summary:
        print(term_summary)

    if args.json:
        print(json.dumps(parsed, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
