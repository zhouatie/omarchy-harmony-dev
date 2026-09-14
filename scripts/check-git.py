#!/usr/bin/env python3
# ==============================================================================
# HarmonyOS Dev Plugin - Git Status Checker
# Single-pass porcelain=v2 checker (<100ms for 80+ repos), zero network overhead.
# ==============================================================================

import os
import sys
import json
import re
import argparse
import subprocess
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

def parse_args():
    parser = argparse.ArgumentParser(description="HarmonyOS Project Git Status Checker")
    parser.add_argument("--path", type=str, default="", help="Project root directory")
    parser.add_argument("--fetch", action="store_true", help="Fetch remote refs before checking")
    parser.add_argument("--trunk", type=str, default="", help="Target trunk branch for MR comparison")
    return parser.parse_args()

def resolve_trunk_branch(proj_path, specified_trunk):
    if specified_trunk:
        return specified_trunk

    # Read from config.json
    config_file = os.path.expanduser("~/.config/harmony/config.json")
    if os.path.isfile(config_file):
        try:
            with open(config_file, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                t = cfg.get("trunkBranch", "").strip()
                if t:
                    return t
        except Exception:
            pass

    # Auto-detect from dep-switch.json5
    dep_switch = os.path.join(proj_path, "dep-switch.json5")
    if os.path.isfile(dep_switch):
        try:
            with open(dep_switch, "r", encoding="utf-8") as f:
                branches = re.findall(r"\"gitBranch\"\s*:\s*\"([^\"]+)\"", f.read())
                if branches:
                    for b, _ in Counter(branches).most_common():
                        if not b.startswith("feat/") and not b.startswith("fix/"):
                            return b
                    return Counter(branches).most_common(1)[0][0]
        except Exception:
            pass

    # Auto-detect from subrepos
    for c in ["libs_source", "lib_source"]:
        p = os.path.join(proj_path, c)
        if os.path.isdir(p):
            sub_b = []
            try:
                for d in os.listdir(p):
                    rp = os.path.join(p, d)
                    if os.path.isdir(os.path.join(rp, ".git")):
                        res = subprocess.run(["git", "-C", rp, "branch", "--show-current"], capture_output=True, text=True, timeout=1)
                        b = res.stdout.strip()
                        if b and not b.startswith("feat/") and not b.startswith("fix/"):
                            sub_b.append(b)
                if sub_b:
                    return Counter(sub_b).most_common(1)[0][0]
            except Exception:
                pass

    # Try shell origin/HEAD
    try:
        res = subprocess.run(["git", "-C", proj_path, "symbolic-ref", "refs/remotes/origin/HEAD"], capture_output=True, text=True, timeout=1)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip().split("/")[-1]
    except Exception:
        pass

    return "master"

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

def check_single_repo(repo_path, do_fetch=False, trunk_branch=""):
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

        # Trunk branch MR comparison
        is_on_trunk = (branch == trunk_branch)
        unmerged_to_trunk = 0
        unmerged_commits = []

        if branch and not is_on_trunk and trunk_branch:
            ref = f"origin/{trunk_branch}"
            r = subprocess.run(["git", "-C", repo_path, "rev-parse", "--verify", ref], capture_output=True)
            if r.returncode != 0:
                ref = trunk_branch
                r = subprocess.run(["git", "-C", repo_path, "rev-parse", "--verify", ref], capture_output=True)
                if r.returncode != 0:
                    for cand in [f"origin/master", "master", f"origin/main", "main"]:
                        if subprocess.run(["git", "-C", repo_path, "rev-parse", "--verify", cand], capture_output=True).returncode == 0:
                            ref = cand
                            break
                    else:
                        ref = ""

            if ref:
                rev_res = subprocess.run(["git", "-C", repo_path, "rev-list", "--count", f"{ref}..HEAD"], capture_output=True, text=True)
                if rev_res.returncode == 0:
                    try:
                        unmerged_to_trunk = int(rev_res.stdout.strip())
                    except ValueError:
                        unmerged_to_trunk = 0
                if unmerged_to_trunk > 0:
                    log_res = subprocess.run(["git", "-C", repo_path, "log", f"{ref}..HEAD", "--oneline", "-n", "8"], capture_output=True, text=True)
                    if log_res.returncode == 0:
                        unmerged_commits = [c.strip() for c in log_res.stdout.splitlines() if c.strip()]

        needs_mr = (not is_on_trunk) and (unmerged_to_trunk > 0 or (dirty and branch != ""))
        merged_to_trunk = (not is_on_trunk) and (unmerged_to_trunk == 0) and (not dirty) and (branch != "")

        return {
            "branch": branch,
            "upstream": upstream,
            "clean": clean,
            "dirty": dirty,
            "modified": modified,
            "untracked": untracked,
            "ahead": ahead,
            "behind": behind,
            "files": changed_files,
            "is_on_trunk": is_on_trunk,
            "unmerged_to_trunk": unmerged_to_trunk,
            "unmerged_commits": unmerged_commits,
            "needs_mr": needs_mr,
            "merged_to_trunk": merged_to_trunk
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

    trunk_branch = resolve_trunk_branch(proj_path, args.trunk)

    # 1. Shell Repo
    shell_info = check_single_repo(proj_path, do_fetch=args.fetch, trunk_branch=trunk_branch)
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

    unmerged_list = []
    merged_feature_list = []

    if shell_info.get("is_git"):
        if shell_info.get("needs_mr"):
            unmerged_list.append({
                "is_shell": True,
                "name": os.path.basename(proj_path),
                "path": proj_path,
                "branch": shell_info.get("branch", ""),
                "unmerged_count": shell_info.get("unmerged_to_trunk", 0),
                "commits": shell_info.get("unmerged_commits", []),
                "dirty": shell_info.get("dirty", False),
                "modified": shell_info.get("modified", 0),
                "untracked": shell_info.get("untracked", 0),
                "ahead": shell_info.get("ahead", 0)
            })
        elif shell_info.get("merged_to_trunk"):
            merged_feature_list.append({
                "is_shell": True,
                "name": os.path.basename(proj_path),
                "path": proj_path,
                "branch": shell_info.get("branch", "")
            })

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
            res = check_single_repo(path, do_fetch=args.fetch, trunk_branch=trunk_branch)
            if res and not res.get("error"):
                res["name"] = name
                res["path"] = path
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

            if r.get("needs_mr"):
                unmerged_list.append({
                    "is_shell": False,
                    "name": r["name"],
                    "path": r["path"],
                    "branch": r.get("branch", ""),
                    "unmerged_count": r.get("unmerged_to_trunk", 0),
                    "commits": r.get("unmerged_commits", []),
                    "dirty": is_dirty,
                    "modified": r.get("modified", 0),
                    "untracked": r.get("untracked", 0),
                    "ahead": ahead
                })
            elif r.get("merged_to_trunk"):
                merged_feature_list.append({
                    "is_shell": False,
                    "name": r["name"],
                    "path": r["path"],
                    "branch": r.get("branch", "")
                })

        libs_info["dirty_count"] = dirty_count
        libs_info["behind_count"] = behind_count
        libs_info["ahead_count"] = ahead_count
        libs_info["clean"] = (dirty_count == 0 and behind_count == 0 and ahead_count == 0)
        libs_info["changed_repos"] = changed_repos
        libs_info["clean_repos"] = clean_repos

    mr_summary = {
        "trunk_branch": trunk_branch,
        "total_unmerged_repos": len(unmerged_list),
        "shell_needs_mr": shell_info.get("needs_mr", False),
        "libs_needs_mr_count": len([r for r in unmerged_list if not r["is_shell"]]),
        "unmerged_list": unmerged_list,
        "merged_feature_list": merged_feature_list
    }

    output = {
        "ok": True,
        "project_path": proj_path,
        "trunk_branch": trunk_branch,
        "shell": shell_info,
        "libs": libs_info,
        "mr_summary": mr_summary
    }
    print(json.dumps(output, ensure_ascii=False))

if __name__ == "__main__":
    main()
