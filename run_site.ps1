# One-click launcher for the MATINO X file-drop site.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

python -m pip install --quiet -r site/requirements.txt

Write-Host "Site running at http://127.0.0.1:5000" -ForegroundColor Green
python site/app.py
