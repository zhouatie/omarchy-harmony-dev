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
    parser.add_argument("--pull", action="store_true", help="Pull latest for repos that are behind remote (--ff-only)")
    parser.add_argument("--pull-repo", type=str, default="", help="Pull specific repo by name or path (--ff-only)")
    parser.add_argument("--sync-deps", action="store_true", help="Sync all subrepos with dep-switch.json5 (clone missing, align branch, ff-only pull)")
    parser.add_argument("--sync-dep-repo", type=str, default="", help="Sync specific subrepo with dep-switch.json5 by name")
    return parser.parse_args()

def strip_json5(text):
    pattern = re.compile(
        r'(/\*[\s\S]*?\*/|//[^\r\n]*)|("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')'
    )
    def repl(m):
        if m.group(1):
            return ""
        s = m.group(2)
        if s and s.startswith("'"):
            inner = s[1:-1].replace('"', '\\"').replace("\\'", "'")
            return f'"{inner}"'
        return s
    cleaned = pattern.sub(repl, text)
    cleaned = re.sub(r'([{\s,])([a-zA-Z_][a-zA-Z0-9_]*)\s*:', r'\1"\2":', cleaned)
    return re.sub(r",(\s*[}\]])", r"\1", cleaned)

def parse_dep_switch(proj_path):
    dep_switch = os.path.join(proj_path, "dep-switch.json5")
    if not os.path.isfile(dep_switch):
        return None
    try:
        with open(dep_switch, "r", encoding="utf-8") as f:
            raw = f.read()
        cleaned = strip_json5(raw)
        data = json.loads(cleaned)
        return data if isinstance(data, dict) else None
    except Exception:
        return None

def get_default_git_host(proj_path):
    try:
        res = subprocess.run(["git", "-C", proj_path, "remote", "get-url", "origin"], capture_output=True, text=True, timeout=1)
        if res.returncode == 0 and res.stdout.strip():
            url = res.stdout.strip()
            m = re.match(r"^(ssh://[^/]+(?::\d+)?)", url)
            if m:
                return m.group(1)
    except Exception:
        pass
    return "ssh://git@g.hz.netease.com:22222"

def extract_git_dependencies(proj_path, dep_data):
    if not dep_data or not isinstance(dep_data, dict):
        return []
    default_host = get_default_git_host(proj_path)
    deps = []
    for d in dep_data.get("dependencies", []):
        if not isinstance(d, dict):
            continue
        if d.get("source") == "npm":
            continue
        project = d.get("project", "").strip()
        if not project:
            continue
        git_host = d.get("gitHost") or default_host
        git_group = d.get("gitGroup") or "cloudmusic-harmony-lib"
        git_name = d.get("gitName") or project
        git_url = d.get("gitUrl") or f"{git_host}/{git_group}/{git_name}.git"
        git_branch = d.get("gitBranch", "").strip()
        deps.append({
            "project": project,
            "gitBranch": git_branch,
            "gitUrl": git_url,
            "gitGroup": git_group,
            "gitName": git_name,
            "gitHost": git_host
        })
    return deps

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
    dep_data = parse_dep_switch(proj_path)
    if dep_data:
        git_deps = extract_git_dependencies(proj_path, dep_data)
        branches = [d["gitBranch"] for d in git_deps if d.get("gitBranch")]
        if branches:
            for b, _ in Counter(branches).most_common():
                if not b.startswith("feat/") and not b.startswith("fix/"):
                    return b
            return Counter(branches).most_common(1)[0][0]

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

def pull_single_repo(repo_path, name=""):
    repo_name = name or os.path.basename(repo_path)
    git_dir = os.path.join(repo_path, ".git")
    if not os.path.exists(git_dir):
        return {"name": repo_name, "path": repo_path, "ok": False, "msg": "非 Git 仓库"}
    try:
        res = subprocess.run(
            ["git", "-C", repo_path, "pull", "--ff-only"],
            capture_output=True, text=True, timeout=25
        )
        ok = (res.returncode == 0)
        msg = res.stdout.strip() if ok else (res.stderr.strip() or res.stdout.strip())
        return {"name": repo_name, "path": repo_path, "ok": ok, "msg": msg}
    except subprocess.TimeoutExpired:
        return {"name": repo_name, "path": repo_path, "ok": False, "msg": "拉取超时 (25s)"}
    except Exception as e:
        return {"name": repo_name, "path": repo_path, "ok": False, "msg": str(e)}

def sync_single_dep_repo(dep_info, target_lib_dir):
    name = dep_info["project"]
    target_branch = dep_info.get("gitBranch", "").strip()
    git_url = dep_info.get("gitUrl", "").strip()
    repo_path = os.path.join(target_lib_dir, name)

    if not os.path.exists(repo_path):
        # Missing repo: clone it
        if not git_url:
            return {"name": name, "ok": False, "skipped": False, "msg": "未配置 gitUrl，无法克隆"}
        try:
            os.makedirs(target_lib_dir, exist_ok=True)
            cmd = ["git", "clone"]
            if target_branch:
                cmd.extend(["-b", target_branch])
            cmd.extend([git_url, repo_path])
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            if res.returncode == 0:
                return {"name": name, "ok": True, "skipped": False, "msg": f"克隆成功 ({target_branch or 'default'})"}
            else:
                err = res.stderr.strip() or res.stdout.strip()
                return {"name": name, "ok": False, "skipped": False, "msg": f"克隆失败: {err}"}
        except subprocess.TimeoutExpired:
            return {"name": name, "ok": False, "skipped": False, "msg": "克隆超时 (60s)"}
        except Exception as e:
            return {"name": name, "ok": False, "skipped": False, "msg": f"克隆异常: {str(e)}"}

    git_dir = os.path.join(repo_path, ".git")
    if not os.path.exists(git_dir):
        return {"name": name, "ok": False, "skipped": True, "msg": "非 Git 仓库，跳过"}

    # Check if dirty
    try:
        st_res = subprocess.run(["git", "-C", repo_path, "status", "--porcelain"], capture_output=True, text=True, timeout=5)
        if st_res.returncode != 0:
            return {"name": name, "ok": False, "skipped": False, "msg": "git status 失败"}
        is_dirty = bool(st_res.stdout.strip())
        if is_dirty:
            return {"name": name, "ok": False, "skipped": True, "msg": "存在本地修改，已安全跳过切换"}

        # Get current branch
        br_res = subprocess.run(["git", "-C", repo_path, "branch", "--show-current"], capture_output=True, text=True, timeout=5)
        cur_branch = br_res.stdout.strip()

        # If target_branch is specified and different from current branch
        if target_branch and cur_branch != target_branch:
            ck_local = subprocess.run(["git", "-C", repo_path, "rev-parse", "--verify", f"refs/heads/{target_branch}"], capture_output=True, timeout=3)
            if ck_local.returncode == 0:
                sw_res = subprocess.run(["git", "-C", repo_path, "checkout", target_branch], capture_output=True, text=True, timeout=10)
                if sw_res.returncode != 0:
                    return {"name": name, "ok": False, "skipped": False, "msg": f"切换分支失败: {sw_res.stderr.strip() or sw_res.stdout.strip()}"}
            else:
                subprocess.run(["git", "-C", repo_path, "fetch", "origin", target_branch], capture_output=True, timeout=15)
                sw_res = subprocess.run(["git", "-C", repo_path, "checkout", "-b", target_branch, f"origin/{target_branch}"], capture_output=True, text=True, timeout=10)
                if sw_res.returncode != 0:
                    sw_res = subprocess.run(["git", "-C", repo_path, "checkout", target_branch], capture_output=True, text=True, timeout=10)
                    if sw_res.returncode != 0:
                        return {"name": name, "ok": False, "skipped": False, "msg": f"检出目标分支 {target_branch} 失败: {sw_res.stderr.strip() or sw_res.stdout.strip()}"}

        # Pull fast-forward
        pull_res = subprocess.run(["git", "-C", repo_path, "pull", "--ff-only"], capture_output=True, text=True, timeout=25)
        if pull_res.returncode == 0:
            msg = f"已对齐 {target_branch}" if target_branch else "已拉取最新"
            return {"name": name, "ok": True, "skipped": False, "msg": msg}
        else:
            err = pull_res.stderr.strip() or pull_res.stdout.strip()
            return {"name": name, "ok": False, "skipped": False, "msg": f"pull 失败: {err}"}
    except subprocess.TimeoutExpired:
        return {"name": name, "ok": False, "skipped": False, "msg": "操作超时 (25s)"}
    except Exception as e:
        return {"name": name, "ok": False, "skipped": False, "msg": str(e)}

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

    dep_data = parse_dep_switch(proj_path)
    git_deps = extract_git_dependencies(proj_path, dep_data) if dep_data else []
    dep_deps_map = {d["project"]: d for d in git_deps}

    # Sub-libraries (libs_source / lib_source)
    target_lib_dir = ""
    dir_name = ""
    for candidate in ["libs_source", "lib_source"]:
        p = os.path.join(proj_path, candidate)
        if os.path.isdir(p):
            target_lib_dir = p
            dir_name = candidate
            break
    if not target_lib_dir:
        target_lib_dir = os.path.join(proj_path, "libs_source")
        dir_name = "libs_source"

    # Execute sync if requested
    sync_results = []
    if args.sync_dep_repo:
        target_name = args.sync_dep_repo.strip()
        matched_dep = None
        for d in git_deps:
            if d["project"].lower() == target_name.lower():
                matched_dep = d
                break
        if matched_dep:
            sync_results.append(sync_single_dep_repo(matched_dep, target_lib_dir))
        else:
            sync_results.append({
                "name": target_name,
                "ok": False,
                "skipped": False,
                "msg": f"dep-switch.json5 中未找到依赖 {target_name}"
            })
    elif args.sync_deps:
        if git_deps:
            with ThreadPoolExecutor(max_workers=8) as sync_exec:
                sync_results = list(sync_exec.map(lambda d: sync_single_dep_repo(d, target_lib_dir), git_deps))

    subdirs = []
    if os.path.isdir(target_lib_dir):
        try:
            for entry in sorted(os.listdir(target_lib_dir)):
                full_p = os.path.join(target_lib_dir, entry)
                if os.path.isdir(full_p) and os.path.exists(os.path.join(full_p, ".git")):
                    subdirs.append((entry, full_p))
        except Exception:
            pass

    existing_repo_names = {entry for entry, _ in subdirs}
    missing_repos = [d for d in git_deps if d["project"] not in existing_repo_names]

    # Execute pull if requested
    pull_results = []
    if args.pull_repo:
        target_name = args.pull_repo.strip()
        matched_path = None
        matched_name = target_name
        if target_name.lower() in ["shell", os.path.basename(proj_path).lower(), proj_path.lower()]:
            matched_path = proj_path
            matched_name = os.path.basename(proj_path)
        elif target_lib_dir:
            for entry, full_p in subdirs:
                if entry == target_name or full_p == target_name:
                    matched_path = full_p
                    matched_name = entry
                    break
        if matched_path:
            pull_results.append(pull_single_repo(matched_path, matched_name))
        else:
            pull_results.append({"name": target_name, "ok": False, "msg": "未找到匹配的仓库"})
    elif args.pull:
        repos_to_pull = []
        sh_check = check_single_repo(proj_path, do_fetch=args.fetch, trunk_branch=trunk_branch)
        if sh_check and sh_check.get("behind", 0) > 0:
            repos_to_pull.append((os.path.basename(proj_path), proj_path))
        if subdirs:
            def scan_behind(item):
                name, p = item
                res = check_single_repo(p, do_fetch=args.fetch, trunk_branch=trunk_branch)
                if res and res.get("behind", 0) > 0:
                    return (name, p)
                return None
            with ThreadPoolExecutor(max_workers=24) as scan_exec:
                repos_to_pull.extend(filter(None, scan_exec.map(scan_behind, subdirs)))
        if repos_to_pull:
            with ThreadPoolExecutor(max_workers=8) as pull_exec:
                pull_results = list(pull_exec.map(lambda it: pull_single_repo(it[1], it[0]), repos_to_pull))

    # 1. Shell Repo
    post_fetch = args.fetch if not (args.pull or args.pull_repo or args.sync_deps or args.sync_dep_repo) else False
    shell_info = check_single_repo(proj_path, do_fetch=post_fetch, trunk_branch=trunk_branch)
    if not shell_info or shell_info.get("error"):
        shell_info = {"is_git": False}
    else:
        shell_info["is_git"] = True

    libs_info = {
        "exists": os.path.isdir(target_lib_dir),
        "dir_name": dir_name,
        "total": len(subdirs),
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

    if target_lib_dir and os.path.isdir(target_lib_dir):
        def worker(item):
            name, path = item
            res = check_single_repo(path, do_fetch=post_fetch, trunk_branch=trunk_branch)
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

            dep_info = dep_deps_map.get(r["name"])
            dep_branch = dep_info.get("gitBranch", "") if dep_info else ""
            branch_mismatch = bool(dep_branch and r.get("branch") and r.get("branch") != dep_branch)

            r["dep_branch"] = dep_branch
            r["branch_mismatch"] = branch_mismatch
            r["is_missing"] = False

            if is_dirty:
                dirty_count += 1
            if behind > 0:
                behind_count += 1
            if ahead > 0:
                ahead_count += 1

            if is_dirty or behind > 0 or ahead > 0 or branch_mismatch:
                changed_repos.append({
                    "name": r["name"],
                    "branch": r["branch"],
                    "dep_branch": dep_branch,
                    "branch_mismatch": branch_mismatch,
                    "is_missing": False,
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
                    "dep_branch": dep_branch,
                    "branch_mismatch": False,
                    "is_missing": False,
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

        for m in missing_repos:
            changed_repos.append({
                "name": m["project"],
                "branch": "",
                "dep_branch": m.get("gitBranch", ""),
                "branch_mismatch": True,
                "is_missing": True,
                "upstream": "",
                "dirty": False,
                "modified": 0,
                "untracked": 0,
                "ahead": 0,
                "behind": 0,
                "files": []
            })

        libs_info["dirty_count"] = dirty_count
        libs_info["behind_count"] = behind_count
        libs_info["ahead_count"] = ahead_count
        libs_info["clean"] = (dirty_count == 0 and behind_count == 0 and ahead_count == 0 and len(missing_repos) == 0 and not any(r.get("branch_mismatch") for r in changed_repos))
        libs_info["changed_repos"] = changed_repos
        libs_info["clean_repos"] = clean_repos

    mismatched_repos_list = [
        {
            "name": r["name"],
            "current_branch": r.get("branch", ""),
            "target_branch": r.get("dep_branch", ""),
            "dirty": r.get("dirty", False)
        }
        for r in libs_info["changed_repos"] if r.get("branch_mismatch") and not r.get("is_missing")
    ]
    missing_repos_list = [
        {
            "name": m["project"],
            "target_branch": m.get("gitBranch", ""),
            "url": m.get("gitUrl", "")
        }
        for m in missing_repos
    ]
    aligned_count = len([r for r in all_res if not r.get("branch_mismatch") and r.get("clean")]) if target_lib_dir and os.path.isdir(target_lib_dir) else 0

    dep_switch_summary = {
        "configured": dep_data is not None,
        "total_deps": len(git_deps),
        "mismatch_count": len(mismatched_repos_list),
        "missing_count": len(missing_repos_list),
        "aligned_count": aligned_count,
        "mismatched_repos": mismatched_repos_list,
        "missing_repos": missing_repos_list
    }

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
        "mr_summary": mr_summary,
        "pull_results": pull_results,
        "sync_results": sync_results,
        "dep_switch": dep_switch_summary
    }
    print(json.dumps(output, ensure_ascii=False))

if __name__ == "__main__":
    main()
