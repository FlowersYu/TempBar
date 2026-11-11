#!/usr/bin/env python3
"""把本地提交推到 GitHub —— 走 api.github.com，不走 git:// 或 HTTPS。

为什么不用 git push：这台机器上 github.com 走本地代理（解析到 127.0.0.1），
`git push` 会卡在 HTTP2 framing / Empty reply。但 api.github.com 是通的，
gh 本身也登录着，所以改成用 Git Data API 手动建 blob → tree → commit → ref。
好处是不动用户账号（不加 SSH key），坏处是只能整棵树一次性提交。
"""
import base64
import json
import subprocess
import sys

REPO = "FlowersYu/TempBar"
BRANCH = "main"


def gh(args, payload=None):
    cmd = ["gh"] + args
    if payload is not None:
        cmd += ["--input", "-"]
        p = subprocess.run(cmd, input=json.dumps(payload).encode(),
                           capture_output=True)
    else:
        p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        sys.exit(f"gh {' '.join(args)} 失败：\n{p.stderr.decode()}")
    out = p.stdout.decode().strip()
    return json.loads(out) if out.startswith(("{", "[")) else out


files = subprocess.run(["git", "ls-files"], capture_output=True,
                       text=True).stdout.split()
print(f"共 {len(files)} 个文件")

# 空仓库上 /git/blobs 会直接 409「Git Repository is empty」，
# 得先用 Contents API 落一个文件把仓库初始化，拿到第一个 commit 当父节点。
parent = None
try:
    branches = gh(["api", f"repos/{REPO}/branches"])
except SystemExit:
    branches = []
if not any(b["name"] == BRANCH for b in branches):
    seed = gh(["api", "-X", "PUT", f"repos/{REPO}/contents/.gitignore"], {
        "message": "init",
        "content": base64.b64encode(b".DS_Store\n").decode(),
    })
    parent = seed["commit"]["sha"]
    print("初始化仓库 ->", parent)
    branches = gh(["api", f"repos/{REPO}/branches"])
else:
    # 分支已存在就拿它当前的 head 当父节点，保证历史是线性的，
    # 不然每推一次都是一个新的无父 commit，github 上会显示成两条无关历史。
    ref = gh(["api", f"repos/{REPO}/git/ref/heads/{BRANCH}"])
    parent = ref["object"]["sha"]
    print("父节点 ->", parent)

tree = []
for f in files:
    with open(f, "rb") as fh:
        raw = fh.read()
    blob = gh(["api", f"repos/{REPO}/git/blobs"], {
        "content": base64.b64encode(raw).decode(),
        "encoding": "base64",
    })
    tree.append({"path": f, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print(f"  blob {f}  {len(raw) // 1024}K")

new_tree = gh(["api", f"repos/{REPO}/git/trees"], {"tree": tree})
msg = subprocess.run(["git", "log", "-1", "--pretty=%B"], capture_output=True,
                     text=True).stdout.strip()
commit = gh(["api", f"repos/{REPO}/git/commits"], {
    "message": msg,
    "tree": new_tree["sha"],
    "parents": [parent] if parent else [],
})
print("commit", commit["sha"])

branches = gh(["api", f"repos/{REPO}/branches"])
if any(b["name"] == BRANCH for b in branches):
    gh(["api", "-X", "PATCH", f"repos/{REPO}/git/refs/heads/{BRANCH}"],
       {"sha": commit["sha"], "force": True})
else:
    gh(["api", "-X", "POST", f"repos/{REPO}/git/refs"],
       {"ref": f"refs/heads/{BRANCH}", "sha": commit["sha"]})

info = gh(["api", f"repos/{REPO}/commits/{BRANCH}"])
print("远端 HEAD:", info["sha"], "|", info["commit"]["message"].splitlines()[0])
