#!/usr/bin/env python3
# ==============================================================================
# HarmonyOS Dev Plugin - Git Status Checker
# Single-pass porcelain=v2 checker (<100ms for 80+ repos), zero network overhead.
# ==============================================================================

import os
import sys
import json
import argparse
import subprocess
from concurrent.futures import ThreadPoolExecutor

def parse_args():
    parser = argparse.ArgumentParser(description="HarmonyOS Project Git Status Checker")
    parser.add_argument("--path", type=str, default="", help="Project root directory")
    parser.add_argument("--fetch", action="store_true", help="Fetch remote refs before checking")
    return parser.parse_args()

def resolve_project_path(specified_path):
    if specified_path and os.path.isfile(os.path.join(specified_path, "build-profile.json5")):
        return specified_path

    # Read from config.json
    config_file = os.path.expanduser("~/.config/harmony/config.json")
    if os.path.isfile(config_file):
        try:
            with open(config_file, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                p = cfg.get("projectPath", "")
                if p and os.path.isfile(os.path.join(p, "build-profile.json5")):
                    return p
        except Exception:
            pass

    # Try omarchy-cmd-terminal-cwd
    try:
        res = subprocess.run(["omarchy-cmd-terminal-cwd"], capture_output=True, text=True, timeout=1)
        if res.returncode == 0 and res.stdout.strip():
            cur = res.stdout.strip()
            while cur and cur != "/":
                if os.path.isfile(os.path.join(cur, "build-profile.json5")):
                    return cur
                cur = os.path.dirname(cur)
    except Exception:
        pass

    # Common search paths
    for base in [os.path.expanduser("~/Work/harmony"), os.path.expanduser("~/Dev/harmony")]:
        if os.path.isdir(base):
            for entry in os.listdir(base):
                cand = os.path.join(base, entry)
                if os.path.isdir(cand) and os.path.isfile(os.path.join(cand, "build-profile.json5")):
                    return cand

    return ""

def check_single_repo(repo_path, do_fetch=False):
    git_dir = os.path.join(repo_path, ".git")
    if not os.path.exists(git_dir):
        return None

    if do_fetch:
        try:
            subprocess.run(["git", "-C", repo_path, "fetch", "--quiet"], capture_output=True, timeout=3)
        except Exception:
            pass

    try:
        res = subprocess.run(
            ["git", "-C", repo_path, "status", "--porcelain=v2", "--branch"],
            capture_output=True, text=True, timeout=2
        )
        if res.returncode != 0:
            return {"error": "git status failed"}

        branch = ""
        upstream = ""
        ahead = 0
        behind = 0
        modified = 0
        untracked = 0
        changed_files = []

        for line in res.stdout.splitlines():
            if line.startswith("# branch.head "):
                branch = line[14:].strip()
            elif line.startswith("# branch.upstream "):
                upstream = line[18:].strip()
            elif line.startswith("# branch.ab "):
                parts = line[12:].strip().split()
                if len(parts) == 2:
                    try:
                        ahead = int(parts[0].lstrip("+"))
                        behind = int(parts[1].lstrip("-"))
                    except ValueError:
                        pass
            elif line.startswith("? "):
                untracked += 1
                if len(changed_files) < 50:
                    changed_files.append({
                        "status": "??",
                        "path": line[2:].strip()
                    })
            elif line.startswith("1 ") or line.startswith("2 ") or line.startswith("u "):
                modified += 1
                if len(changed_files) < 50:
                    parts = line.split(maxsplit=8)
                    xy = parts[1] if len(parts) > 1 else "M"
                    path = parts[8] if len(parts) > 8 else ""
                    st = "M"
                    if "A" in xy:
                        st = "A"
                    elif "D" in xy:
                        st = "D"
                    elif "R" in xy:
                        st = "R"
                    elif line.startswith("u "):
                        st = "U"
                    changed_files.append({
                        "status": st,
                        "path": path
                    })

        dirty = (modified > 0 or untracked > 0)
        clean = (not dirty and ahead == 0 and behind == 0)

        return {
            "branch": branch,
            "upstream": upstream,
            "clean": clean,
            "dirty": dirty,
            "modified": modified,
            "untracked": untracked,
            "ahead": ahead,
            "behind": behind,
            "files": changed_files
        }
    except Exception as e:
        return {"error": str(e)}

def main():
    args = parse_args()
    proj_path = resolve_project_path(args.path)

    if not proj_path or not os.path.isdir(proj_path):
        print(json.dumps({
            "ok": False,
            "reason": "未找到有效的鸿蒙工程目录"
        }, ensure_ascii=False))
        sys.exit(0)

    # 1. Shell Repo
    shell_info = check_single_repo(proj_path, do_fetch=args.fetch)
    if not shell_info or shell_info.get("error"):
        shell_info = {"is_git": False}
    else:
        shell_info["is_git"] = True

    # 2. Sub-libraries (libs_source / lib_source)
    target_lib_dir = ""
    dir_name = ""
    for candidate in ["libs_source", "lib_source"]:
        p = os.path.join(proj_path, candidate)
        if os.path.isdir(p):
            target_lib_dir = p
            dir_name = candidate
            break

    libs_info = {
        "exists": False,
        "dir_name": dir_name,
        "total": 0,
        "clean": True,
        "dirty_count": 0,
        "behind_count": 0,
        "ahead_count": 0,
        "changed_repos": []
    }

    if target_lib_dir:
        libs_info["exists"] = True
        subdirs = []
        try:
            for entry in sorted(os.listdir(target_lib_dir)):
                full_p = os.path.join(target_lib_dir, entry)
                if os.path.isdir(full_p) and os.path.exists(os.path.join(full_p, ".git")):
                    subdirs.append((entry, full_p))
        except Exception:
            pass

        libs_info["total"] = len(subdirs)

        def worker(item):
            name, path = item
            res = check_single_repo(path, do_fetch=args.fetch)
            if res and not res.get("error"):
                res["name"] = name
                return res
            return None

        with ThreadPoolExecutor(max_workers=24) as executor:
            all_res = list(filter(None, executor.map(worker, subdirs)))

        changed_repos = []
        clean_repos = []
        dirty_count = 0
        behind_count = 0
        ahead_count = 0

        for r in all_res:
            is_dirty = r.get("dirty", False)
            behind = r.get("behind", 0)
            ahead = r.get("ahead", 0)

            if is_dirty:
                dirty_count += 1
            if behind > 0:
                behind_count += 1
            if ahead > 0:
                ahead_count += 1

            if is_dirty or behind > 0 or ahead > 0:
                changed_repos.append({
                    "name": r["name"],
                    "branch": r["branch"],
                    "upstream": r.get("upstream", ""),
                    "dirty": is_dirty,
                    "modified": r["modified"],
                    "untracked": r["untracked"],
                    "ahead": ahead,
                    "behind": behind,
                    "files": r["files"]
                })
            else:
                clean_repos.append({
                    "name": r["name"],
                    "branch": r["branch"],
                    "upstream": r.get("upstream", "")
                })

        libs_info["dirty_count"] = dirty_count
        libs_info["behind_count"] = behind_count
        libs_info["ahead_count"] = ahead_count
        libs_info["clean"] = (dirty_count == 0 and behind_count == 0 and ahead_count == 0)
        libs_info["changed_repos"] = changed_repos
        libs_info["clean_repos"] = clean_repos

    output = {
        "ok": True,
        "project_path": proj_path,
        "shell": shell_info,
        "libs": libs_info
    }
    print(json.dumps(output, ensure_ascii=False))

if __name__ == "__main__":
    main()
