#!/usr/bin/env python3
"""MATINO X file-drop site.

Upload a file -> saved into BundledFiles/ -> git push -> GitHub Actions
rebuilds the IPA with the file inside Payload/MATINO X.app/.

Protected by a single password stored in .env (SITE_PASSWORD).
"""
from __future__ import annotations

import base64
import json
import os
import secrets
import subprocess
import time
from pathlib import Path

from flask import Flask, flash, redirect, render_template, request, session, url_for

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
DROP_DIR = REPO / "BundledFiles"
ENV_FILE = REPO / ".env"
REPO_SLUG = "gminegg150-cell/matino-x"
# MATINO X: git push must target the new account remote, not the stale origin.
PUSH_REMOTE = "new"


def git_push_command() -> list[str]:
    """git push to the new account, authenticating with GH_TOKEN when present.

    The machine's credential helper is bound to the old account, so a plain
    `git push` gets a 403. An explicit Authorization header keeps the site
    independent of the desktop credential helper.
    """
    cmd = ["git"]
    token = os.environ.get("GH_TOKEN", "").strip()
    if token:
        basic = base64.b64encode(
            f"x-access-token:{token}".encode("utf-8")
        ).decode("ascii")
        cmd += ["-c", f"http.extraheader=AUTHORIZATION: basic {basic}"]
    cmd += ["push", PUSH_REMOTE, "main:main"]
    return cmd


def load_env_file() -> None:
    if not ENV_FILE.is_file():
        return
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_env_file()

app = Flask(__name__)
app.secret_key = os.environ.get("SITE_SECRET") or secrets.token_hex(32)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024 * 1024  # 64 MB


def password() -> str:
    return os.environ.get("SITE_PASSWORD", "").strip()


def logged_in() -> bool:
    return session.get("auth") == "ok" and bool(password())


COMMENTS_FILE = DROP_DIR / "comments.json"


def load_comments() -> dict:
    try:
        data = json.loads(COMMENTS_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_comments(comments: dict) -> None:
    DROP_DIR.mkdir(parents=True, exist_ok=True)
    COMMENTS_FILE.write_text(
        json.dumps(comments, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def safe_name(name: str) -> str:
    name = Path(name.replace("\\", "/")).name
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    name = "".join(c if c in allowed else "_" for c in name).lstrip(".") or "file"
    return name[:120]


def latest_release() -> dict | None:
    import json
    import subprocess
    import urllib.request

    repo = REPO_SLUG

    # Prefer the authenticated gh CLI (works for private repos too).
    try:
        result = subprocess.run(
            [
                "gh", "api", f"repos/{repo}/releases/latest",
                "--jq", "{tag:.tag_name, url:(.assets[]|select(.name|endswith(\".ipa\"))|.browser_download_url)}",
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout.strip().splitlines()[0])
            if data.get("url"):
                return {"tag": data.get("tag", ""), "url": data["url"]}
    except Exception:
        pass

    # Fallback: public REST API.
    try:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/releases/latest",
            headers={"User-Agent": "matino-x-file-site"},
        )
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.load(response)
        assets = [
            a for a in data.get("assets", [])
            if a.get("name", "").lower().endswith(".ipa")
        ]
        if not assets:
            return None
        return {"tag": data.get("tag_name", ""), "url": assets[0]["browser_download_url"]}
    except Exception:
        return None


@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "POST" and "login" in request.form:
        if secrets.compare_digest(request.form.get("password", ""), password()):
            session["auth"] = "ok"
            flash("Authenticated.")
        else:
            flash("Wrong password.")
        return redirect(url_for("index"))

    if not logged_in():
        return render_template(
            "login.html", configured=bool(password()), release=latest_release()
        )

    files = []
    if DROP_DIR.is_dir():
        files = sorted(
            f.name for f in DROP_DIR.iterdir()
            if f.is_file() and f.name != ".gitkeep"
        )

    return render_template(
        "index.html", files=files, comments=load_comments(), release=latest_release()
    )


@app.route("/upload", methods=["POST"])
def upload():
    if not logged_in():
        return redirect(url_for("index"))

    incoming = request.files.get("file")
    if incoming is None or not incoming.filename:
        flash("No file selected.")
        return redirect(url_for("index"))

    name = safe_name(incoming.filename)

    # MATINO X: category (AIM / HOLOGRAM / SKIN) and game variant
    # (NORMAL / MAX) are encoded in the file name as prefixes so the read-only
    # filters show it under the chosen tab + variant. No apply/run behaviour.
    import re
    category = request.form.get("category", "").strip().upper()
    variant = request.form.get("variant", "").strip().upper()
    valid_category = category if category in {"AIM", "HOLOGRAM", "SKIN"} else None
    valid_variant = variant if variant in {"NORMAL", "MAX"} else None

    # Strip any previous category/variant prefix so a file sits in exactly one
    # place and re-uploading it with new choices does not stack prefixes.
    clean = re.sub(r"^(AIM|HOLOGRAM|SKIN)_+", "", name, flags=re.IGNORECASE)
    clean = re.sub(r"^MAX_+", "", clean, flags=re.IGNORECASE)
    clean = re.sub(r"^NORMAL_+", "", clean, flags=re.IGNORECASE)
    clean = clean or "file"

    tokens = []
    if valid_category:
        tokens.append(valid_category)
    # Always encode an explicit variant so a MAX file can never leak into the
    # NORMAL tab (and vice versa). Unknown/omitted variant = NORMAL.
    tokens.append(valid_variant or "NORMAL")
    tokens.append(clean)
    name = safe_name("_".join(tokens))

    DROP_DIR.mkdir(parents=True, exist_ok=True)
    target = DROP_DIR / name
    target.write_bytes(incoming.read())

    # MATINO X: optional comment shown under the file name in the app.
    comment = request.form.get("comment", "").strip()
    comments = load_comments()
    # Remove any stale entry for this file under either key form (with or
    # without the extension), then store the full file name as the key so the
    # app can look it up directly.
    stem = name.rsplit(".", 1)[0]
    comments.pop(name, None)
    comments.pop(stem, None)
    if comment:
        comments[name] = comment
    save_comments(comments)

    try:
        subprocess.run(
            ["git", "add", "--", f"BundledFiles/{name}", "BundledFiles/comments.json"],
            cwd=REPO, check=True
        )
        staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=REPO).returncode
        if staged == 0:
            flash(f"{name}: unchanged, no rebuild needed.")
        else:
            subprocess.run(
                ["git", "commit", "-m", f"Bundle file: {name} + comment [skip ci]"], cwd=REPO, check=True
            )
            push = subprocess.run(
                git_push_command(), cwd=REPO, capture_output=True, text=True, timeout=120
            )
            if push.returncode == 0:
                flash(f"{name} uploaded. It will appear in the app within ~2 seconds (no rebuild needed).")
            else:
                flash(f"{name} committed locally but push failed: {push.stderr[-500:]}")
    except Exception as exc:
        flash(f"Git error: {exc}")

    time.sleep(0.2)
    return redirect(url_for("index"))


@app.route("/delete", methods=["POST"])
def delete():
    if not logged_in():
        return redirect(url_for("index"))

    name = safe_name(request.form.get("name", ""))
    target = DROP_DIR / name
    if not target.is_file():
        flash(f"{name}: not found.")
        return redirect(url_for("index"))

    try:
        target.unlink()
        comments = load_comments()
        comments.pop(name, None)
        comments.pop(name.rsplit(".", 1)[0], None)
        save_comments(comments)
        subprocess.run(["git", "add", "-A", "--", "BundledFiles"], cwd=REPO, check=True)
        subprocess.run(
            ["git", "commit", "-m", f"Remove bundled file: {name} [skip ci]"], cwd=REPO, check=True
        )
        push = subprocess.run(
            git_push_command(), cwd=REPO, capture_output=True, text=True, timeout=120
        )
        if push.returncode == 0:
            flash(f"{name} deleted. It will disappear from the app within ~2 seconds (no rebuild needed).")
        else:
            flash(f"{name} removed locally but push failed: {push.stderr[-500:]}")
    except Exception as exc:
        flash(f"Delete error: {exc}")

    time.sleep(0.2)
    return redirect(url_for("index"))


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("index"))


if __name__ == "__main__":
    if not password():
        print("Set SITE_PASSWORD in .env before starting. See .env.example")
    app.run(host="127.0.0.1", port=5000, debug=False)
