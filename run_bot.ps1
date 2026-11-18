# One-click launcher for the MATINO X file-drop bot.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Created .env from .env.example — open it and fill in your token and chat ID." -ForegroundColor Yellow
    notepad .env
    exit 1
}

python -m pip install --quiet requests
python telegram_file_bot.py
