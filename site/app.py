#!/usr/bin/env python3
"""MATINO X file-drop site.

Upload a file -> saved into BundledFiles/ -> git push -> GitHub Actions
rebuilds the IPA with the file inside Payload/MATINO X.app/.

Protected by a single password stored in .env (SITE_PASSWORD).
"""
from __future__ import annotations

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
REPO_SLUG = "tff68484-lab/matino-x"


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


def safe_name(name: str) -> str:
    name = Path(name.replace("\\", "/")).name
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    name = "".join(c if c in allowed else "_" for c in name).lstrip(".") or "file"
    return name[:120]


def latest_release() -> dict | None:
    import json
    import urllib.request

    try:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{REPO_SLUG}/releases/latest",
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
        "index.html", files=files, release=latest_release()
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
    DROP_DIR.mkdir(parents=True, exist_ok=True)
    target = DROP_DIR / name
    target.write_bytes(incoming.read())

    try:
        subprocess.run(["git", "add", "--", f"BundledFiles/{name}"], cwd=REPO, check=True)
        staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=REPO).returncode
        if staged == 0:
            flash(f"{name}: unchanged, no rebuild needed.")
        else:
            subprocess.run(
                ["git", "commit", "-m", f"Bundle file: {name}"], cwd=REPO, check=True
            )
            push = subprocess.run(
                ["git", "push"], cwd=REPO, capture_output=True, text=True, timeout=120
            )
            if push.returncode == 0:
                flash(f"{name} uploaded. GitHub Actions is rebuilding the IPA (~1 min).")
            else:
                flash(f"{name} committed locally but push failed: {push.stderr[-500:]}")
    except Exception as exc:
        flash(f"Git error: {exc}")

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
