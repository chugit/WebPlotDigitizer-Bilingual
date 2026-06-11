$ErrorActionPreference = "Stop"

function Step($text) {
    Write-Host ""
    Write-Host "==== $text ===="
}

function Run-NpmInstall() {
    npm install --no-audit
    if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
}

function Run-PyBabelExtract() {
    & pybabel extract -F .\templates\babel.config -o .\locale\messages.pot .\templates
    if ($LASTEXITCODE -eq 0) { return }

    Write-Host "pybabel command failed. Trying python module form..."
    & py -m babel.messages.frontend extract -F .\templates\babel.config -o .\locale\messages.pot .\templates
    if ($LASTEXITCODE -ne 0) { throw "pybabel extract failed." }
}

function Repair-Electron() {
    Step "Repair Electron"

    $ElectronPkgPath = Join-Path (Get-Location) "node_modules\electron\package.json"
    if (!(Test-Path $ElectronPkgPath)) {
        throw "node_modules/electron/package.json not found. Run npm install in desktop first."
    }

    $ElectronVersion = (Get-Content $ElectronPkgPath -Raw | ConvertFrom-Json).version
    if ([string]::IsNullOrWhiteSpace($ElectronVersion)) {
        throw "Cannot read Electron version."
    }

    Write-Host "Electron version: $ElectronVersion"

    $ElectronDir = Join-Path (Get-Location) "node_modules\electron"
    $DistDir = Join-Path $ElectronDir "dist"
    $PathTxt = Join-Path $ElectronDir "path.txt"
    $ZipFile = Join-Path $env:TEMP "electron-v$ElectronVersion-win32-x64.zip"

    Remove-Item $DistDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $PathTxt -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:LOCALAPPDATA "electron\Cache") -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $DistDir | Out-Null

    $urls = @(
        "https://npmmirror.com/mirrors/electron/$ElectronVersion/electron-v$ElectronVersion-win32-x64.zip",
        "https://github.com/electron/electron/releases/download/v$ElectronVersion/electron-v$ElectronVersion-win32-x64.zip"
    )

    Remove-Item $ZipFile -Force -ErrorAction SilentlyContinue

    foreach ($u in $urls) {
        try {
            Write-Host "Downloading: $u"
            Invoke-WebRequest -Uri $u -OutFile $ZipFile -UseBasicParsing -TimeoutSec 300
            if ((Test-Path $ZipFile) -and ((Get-Item $ZipFile).Length -gt 50000000)) {
                Write-Host "Download OK."
                break
            }
        } catch {
            Write-Host "Download failed. Trying next URL."
        }
    }

    if (!(Test-Path $ZipFile) -or ((Get-Item $ZipFile).Length -lt 50000000)) {
        throw "Electron zip download failed."
    }

    Expand-Archive $ZipFile -DestinationPath $DistDir -Force

    if (!(Test-Path (Join-Path $DistDir "electron.exe"))) {
        throw "electron.exe not found after unzip."
    }

    "electron.exe" | Set-Content $PathTxt -Encoding ASCII -NoNewline

    $ElectronCmd = Join-Path (Get-Location) "node_modules\.bin\electron.cmd"
    & $ElectronCmd --version
    if ($LASTEXITCODE -ne 0) {
        throw "Electron repair failed."
    }
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptRoot

$env:ELECTRON_MIRROR = "https://npmmirror.com/mirrors/electron/"
$env:ELECTRON_CUSTOM_DIR = "{{ version }}"

Step "Check tools"
& git --version
if ($LASTEXITCODE -ne 0) { throw "Git is not available." }
& node -v
if ($LASTEXITCODE -ne 0) { throw "Node.js is not available." }
& npm -v
if ($LASTEXITCODE -ne 0) { throw "npm is not available." }
& py --version
if ($LASTEXITCODE -ne 0) { throw "Python launcher py is not available." }

Step "Create work directory"
$Work = Join-Path $env:USERPROFILE "Desktop\WPD-bilingual-build"
$Repo = Join-Path $Work "WebPlotDigitizer"

if (Test-Path $Work) {
    Remove-Item $Work -Recurse -Force
}
New-Item -ItemType Directory -Force $Work | Out-Null
Set-Location $Work

Step "Clone WebPlotDigitizer"
git clone --depth 1 https://github.com/automeris-io/WebPlotDigitizer.git
if ($LASTEXITCODE -ne 0) { throw "git clone failed." }

Set-Location $Repo

$RootPkg = Get-Content ".\package.json" -Raw | ConvertFrom-Json
$WpdVersion = $RootPkg.version
if ([string]::IsNullOrWhiteSpace($WpdVersion)) {
    throw "Cannot read version from package.json."
}
Write-Host "WebPlotDigitizer version: $WpdVersion"

Step "Install Python and npm dependencies"
& py -m pip install -U pip
if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed." }
& py -m pip install Jinja2 Babel polib
if ($LASTEXITCODE -ne 0) { throw "Python dependency install failed." }
Run-NpmInstall

Step "Extract translation template"
Run-PyBabelExtract
if (!(Test-Path ".\locale\messages.pot")) { throw "messages.pot was not generated." }

Step "Write helper scripts"
New-Item -ItemType Directory -Force ".\build_tools" | Out-Null

$mergePy = @'
from pathlib import Path
import csv
import datetime
import sys
import polib

root = Path.cwd()
pot_path = root / "locale" / "messages.pot"
csv_path = Path(sys.argv[1]).resolve()
po_path = root / "locale" / "zh_CN" / "LC_MESSAGES" / "messages.po"
mo_path = root / "locale" / "zh_CN" / "LC_MESSAGES" / "messages.mo"
template_csv_path = Path(sys.argv[2]).resolve()
version = sys.argv[3]

pot = polib.pofile(str(pot_path))
entries = [e for e in pot if not e.obsolete and e.msgid]

def write_csv(path, rows):
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["source", "msgid", "msgstr", "note"])
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

def source_of(entry):
    return "; ".join(f"{p}:{line}" for p, line in entry.occurrences)

if not csv_path.exists():
    rows = []
    for entry in entries:
        rows.append({"source": source_of(entry), "msgid": entry.msgid, "msgstr": "", "note": ""})
    write_csv(template_csv_path, rows)
    print(f"Translation CSV not found: {csv_path}")
    print(f"A template CSV has been created: {template_csv_path}")
    print("Fill the msgstr column, rename/copy it to translations.zh_CN.csv, then run again.")
    sys.exit(3)

translations = {}
with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
    reader = csv.DictReader(f)
    required = {"msgid", "msgstr"}
    if not reader.fieldnames or not required.issubset(set(reader.fieldnames)):
        raise SystemExit("CSV must contain at least msgid and msgstr columns.")
    for row in reader:
        msgid = (row.get("msgid") or "").replace("\r\n", "\n")
        msgstr = (row.get("msgstr") or "").replace("\r\n", "\n").strip()
        if not msgid:
            continue
        if msgid in translations:
            raise SystemExit(f"Duplicate msgid in CSV: {msgid[:80]}")
        translations[msgid] = msgstr

review_rows = []
missing_count = 0
for entry in entries:
    msgstr = translations.get(entry.msgid, "").strip()
    if not msgstr:
        missing_count += 1
    review_rows.append({
        "source": source_of(entry),
        "msgid": entry.msgid,
        "msgstr": msgstr,
        "note": "MISSING" if not msgstr else ""
    })

if missing_count:
    write_csv(template_csv_path, review_rows)
    print(f"Missing translations: {missing_count}")
    print(f"Review CSV created: {template_csv_path}")
    print("Fill missing msgstr values, save as translations.zh_CN.csv, then run again.")
    sys.exit(4)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M+0000")
po = polib.POFile()
po.metadata = {
    "Project-Id-Version": f"WebPlotDigitizer {version}",
    "Report-Msgid-Bugs-To": "",
    "POT-Creation-Date": now,
    "PO-Revision-Date": now,
    "Last-Translator": "",
    "Language": "zh_CN",
    "Language-Team": "zh_CN",
    "Plural-Forms": "nplurals=1; plural=0;",
    "MIME-Version": "1.0",
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Transfer-Encoding": "8bit",
    "Generated-By": "WebPlotDigitizer bilingual build workflow",
}

for entry in entries:
    if entry.msgid_plural:
        new_entry = polib.POEntry(
            msgid=entry.msgid,
            msgid_plural=entry.msgid_plural,
            msgstr_plural={0: translations[entry.msgid]}
        )
    else:
        new_entry = polib.POEntry(msgid=entry.msgid, msgstr=translations[entry.msgid])
    new_entry.occurrences = entry.occurrences
    new_entry.comment = entry.comment
    new_entry.tcomment = entry.tcomment
    po.append(new_entry)

po_path.parent.mkdir(parents=True, exist_ok=True)
po.save(str(po_path))
po.save_as_mofile(str(mo_path))
print(f"PO saved: {po_path}")
print(f"MO saved: {mo_path}")
print(f"Entries: {len(entries)}")
'@
Set-Content ".\build_tools\merge_translation.py" $mergePy -Encoding UTF8

$renderPy = @'
from pathlib import Path
import gettext
from jinja2 import Environment, FileSystemLoader

root = Path.cwd()
env = Environment(
    loader=FileSystemLoader(str(root / "templates")),
    extensions=["jinja2.ext.i18n"]
)
template = env.get_template("offline.html")

def render(lang, outfile):
    if lang == "en_US":
        translation = gettext.NullTranslations()
    else:
        translation = gettext.translation(
            "messages",
            localedir=str(root / "locale"),
            languages=[lang],
            fallback=False
        )
    env.install_gettext_translations(translation)
    html = template.render()
    (root / outfile).write_text(html, encoding="utf-8")
    print(f"Generated: {outfile}")

render("en_US", "offline.html")
render("zh_CN", "offline.zh_CN.html")
'@
Set-Content ".\build_tools\render_offline_bilingual.py" $renderPy -Encoding UTF8

Step "Merge Chinese translation"
$CsvCandidate1 = Join-Path $ScriptRoot "translations.zh_CN.csv"
$CsvCandidate2 = Join-Path $ScriptRoot "translations.zh_CN.completed.csv"
if (Test-Path $CsvCandidate1) {
    $TranslationCsv = $CsvCandidate1
} elseif (Test-Path $CsvCandidate2) {
    $TranslationCsv = $CsvCandidate2
} else {
    $TranslationCsv = $CsvCandidate1
}
$ReviewCsv = Join-Path $ScriptRoot "translations.zh_CN.to_review.csv"
& py ".\build_tools\merge_translation.py" $TranslationCsv $ReviewCsv $WpdVersion
$mergeExit = $LASTEXITCODE
if ($mergeExit -eq 3 -or $mergeExit -eq 4) {
    throw "Translation CSV is missing or incomplete. Fill the generated review CSV and run again."
}
if ($mergeExit -ne 0) {
    throw "Translation merge failed."
}

Step "Build wpd.min.js"
$jsFiles = @()
$jsFiles += Get-ChildItem ".\javascript\core\*.js" | Sort-Object Name
$jsFiles += Get-ChildItem ".\javascript\core\curve_detection\*.js" | Sort-Object Name
$jsFiles += Get-Item ".\javascript\core\point_detection\templateMatcherAlgo.js"
$jsFiles += Get-ChildItem ".\javascript\core\axes\*.js" | Sort-Object Name
$jsFiles += Get-ChildItem ".\javascript\widgets\*.js" | Sort-Object Name
$jsFiles += Get-ChildItem ".\javascript\tools\base\*.js" | Sort-Object Name
$jsFiles += Get-ChildItem ".\javascript\tools\*.js" | Sort-Object Name
$jsFiles += Get-ChildItem ".\javascript\controllers\*.js" | Sort-Object Name
$jsFiles += Get-ChildItem ".\javascript\services\*.js" | Sort-Object Name
$jsFiles += Get-ChildItem ".\javascript\*.js" | Sort-Object Name

$content = foreach ($f in $jsFiles) {
    Get-Content $f.FullName -Raw -Encoding UTF8
    "`n"
}
$content | Set-Content ".\combined.js" -Encoding UTF8

npx uglify-js ".\combined.js" -cm -o ".\wpd.min.js"
if ($LASTEXITCODE -ne 0) { throw "uglify-js failed." }
if (!(Test-Path ".\wpd.min.js")) { throw "wpd.min.js was not generated." }

Step "Render bilingual offline HTML"
& py ".\build_tools\render_offline_bilingual.py"
if ($LASTEXITCODE -ne 0) { throw "HTML rendering failed." }
if (!(Test-Path ".\offline.html")) { throw "offline.html was not generated." }
if (!(Test-Path ".\offline.zh_CN.html")) { throw "offline.zh_CN.html was not generated." }

Step "Prepare desktop app"
Copy-Item ".\wpd.min.js" ".\desktop\wpd.min.js" -Force
Copy-Item ".\offline.html" ".\desktop\offline.html" -Force
Copy-Item ".\offline.zh_CN.html" ".\desktop\offline.zh_CN.html" -Force
if (Test-Path ".\start.png") { Copy-Item ".\start.png" ".\desktop\start.png" -Force }
if (Test-Path ".\images") { Copy-Item ".\images" ".\desktop\images" -Recurse -Force }
if (Test-Path ".\styles") { Copy-Item ".\styles" ".\desktop\styles" -Recurse -Force }
New-Item -ItemType Directory ".\desktop\javascript\core\point_detection" -Force | Out-Null
Copy-Item ".\javascript\core\point_detection\templateMatcherWorker.js" ".\desktop\javascript\core\point_detection\templateMatcherWorker.js" -Force

Step "Write desktop package and Electron main file"
Set-Location ".\desktop"

$desktopPkg = [ordered]@{
    name = "webplotdigitizer-bilingual"
    version = $WpdVersion
    description = "WebPlotDigitizer bilingual offline desktop app"
    main = "index.js"
    scripts = [ordered]@{
        start = "electron ."
    }
    author = "Ankit Rohatgi"
    license = "AGPL-3.0"
    devDependencies = [ordered]@{
        electron = "31.7.7"
    }
    dependencies = [ordered]@{
        "bootstrap-icons" = "^1.11.3"
        "pdfjs-dist" = "^4.2.67"
        "tarballjs" = "https://github.com/ankitrohatgi/tarballjs.git#v1.0"
    }
}
$desktopPkg | ConvertTo-Json -Depth 20 | Set-Content ".\package.json" -Encoding ASCII

$indexJsTemplate = @'
const fs = require('fs');
const path = require('path');
const { app, BrowserWindow, dialog, ipcMain, shell, screen, Menu } = require('electron');

const WPD_VERSION = '__WPD_VERSION__';
let win = null;
let allowQuit = false;

const LANGS = {
    zh_CN: {
        title: 'WebPlotDigitizer ' + WPD_VERSION + ' \u4e2d\u6587\u79bb\u7ebf\u7248',
        file: 'offline.zh_CN.html',
        quitTitle: '\u786e\u8ba4',
        quitMessage: '\u786e\u5b9a\u8981\u9000\u51fa\u5417\uff1f',
        yes: '\u662f',
        no: '\u5426'
    },
    en_US: {
        title: 'WebPlotDigitizer ' + WPD_VERSION + ' Offline',
        file: 'offline.html',
        quitTitle: 'Confirm',
        quitMessage: 'Are you sure you want to quit?',
        yes: 'Yes',
        no: 'No'
    }
};

function normalizeLang(lang) {
    if (lang === 'zh' || lang === 'zh-CN' || lang === 'zh_CN') return 'zh_CN';
    if (lang === 'en' || lang === 'en-US' || lang === 'en_US') return 'en_US';
    return null;
}

function getArgLang() {
    for (const arg of process.argv) {
        if (arg.startsWith('--lang=')) return normalizeLang(arg.substring('--lang='.length));
    }
    return null;
}

function settingsPath() {
    return path.join(app.getPath('userData'), 'settings.json');
}

function readSavedLang() {
    try {
        const p = settingsPath();
        if (!fs.existsSync(p)) return null;
        const data = JSON.parse(fs.readFileSync(p, 'utf8'));
        return normalizeLang(data.language);
    } catch {
        return null;
    }
}

function saveLang(lang) {
    try {
        fs.mkdirSync(app.getPath('userData'), { recursive: true });
        fs.writeFileSync(settingsPath(), JSON.stringify({ language: lang }, null, 2), 'utf8');
    } catch {
    }
}

let currentLang = getArgLang() || readSavedLang() || 'zh_CN';

function htmlPath(lang) {
    const safeLang = LANGS[lang] ? lang : 'zh_CN';
    const p = path.join(__dirname, LANGS[safeLang].file);
    if (fs.existsSync(p)) return p;
    return path.join(__dirname, 'offline.html');
}

function buildMenu() {
    const template = [
        {
            label: 'Language / \u8bed\u8a00',
            submenu: [
                { label: '\u4e2d\u6587', type: 'radio', checked: currentLang === 'zh_CN', click: () => switchLanguage('zh_CN') },
                { label: 'English', type: 'radio', checked: currentLang === 'en_US', click: () => switchLanguage('en_US') }
            ]
        },
        {
            label: 'View',
            submenu: [
                { role: 'reload', label: 'Reload' },
                { role: 'toggleDevTools', label: 'Developer Tools' },
                { type: 'separator' },
                { role: 'resetZoom' },
                { role: 'zoomIn' },
                { role: 'zoomOut' },
                { role: 'togglefullscreen' }
            ]
        },
        {
            label: 'Window',
            submenu: [
                { role: 'minimize' },
                { role: 'close' }
            ]
        }
    ];
    Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function switchLanguage(lang) {
    if (!LANGS[lang] || !win) return;
    currentLang = lang;
    saveLang(currentLang);
    win.setTitle(LANGS[currentLang].title);
    win.loadFile(htmlPath(currentLang));
    buildMenu();
}

function createWindow() {
    const screenSize = screen.getPrimaryDisplay().workAreaSize;
    win = new BrowserWindow({
        title: LANGS[currentLang].title,
        width: parseInt(screenSize.width * 0.75),
        height: parseInt(screenSize.height * 0.75),
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false
        }
    });

    win.webContents.setWindowOpenHandler(({ url }) => {
        shell.openExternal(url);
        return { action: 'deny' };
    });

    buildMenu();
    win.loadFile(htmlPath(currentLang));

    win.on('close', async function (e) {
        if (!allowQuit) {
            e.preventDefault();
            const t = LANGS[currentLang];
            const choice = await dialog.showMessageBox(win, {
                type: 'question',
                buttons: [t.yes, t.no],
                title: t.quitTitle,
                message: t.quitMessage
            });
            if (choice.response === 0) {
                allowQuit = true;
                app.quit();
            }
        }
    });
}

app.on('window-all-closed', () => app.quit());
app.whenReady().then(() => {
    createWindow();
    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
});
ipcMain.on('app_exit', () => {
    allowQuit = true;
    app.quit();
});
'@
$indexJs = $indexJsTemplate.Replace("__WPD_VERSION__", $WpdVersion)
Set-Content ".\index.js" $indexJs -Encoding ASCII

Step "Install desktop dependencies"
Run-NpmInstall

Step "Check Electron"
$ElectronCmd = Join-Path (Get-Location) "node_modules\.bin\electron.cmd"
$ElectronOk = $false
if (Test-Path $ElectronCmd) {
    & $ElectronCmd --version
    if ($LASTEXITCODE -eq 0) { $ElectronOk = $true }
}
if (-not $ElectronOk) {
    Repair-Electron
}

Step "Create portable app"
$ElectronDist = Join-Path (Get-Location) "node_modules\electron\dist"
if (!(Test-Path (Join-Path $ElectronDist "electron.exe"))) {
    Repair-Electron
}
if (!(Test-Path (Join-Path $ElectronDist "electron.exe"))) {
    throw "electron.exe not found."
}

$Out = Join-Path $env:USERPROFILE "Desktop\WebPlotDigitizer-$WpdVersion-bilingual-offline"
$App = Join-Path $Out "resources\app"
Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Out | Out-Null
robocopy $ElectronDist $Out /E /NFL /NDL /NJH /NJS /NP | Out-Null
New-Item -ItemType Directory -Force $App | Out-Null

Copy-Item ".\index.js" $App -Force
Copy-Item ".\package.json" $App -Force
Copy-Item ".\offline.html" $App -Force
Copy-Item ".\offline.zh_CN.html" $App -Force
Copy-Item ".\wpd.min.js" $App -Force
if (Test-Path ".\start.png") { Copy-Item ".\start.png" $App -Force }

foreach ($dir in @("images", "styles", "javascript")) {
    if (Test-Path ".\$dir") {
        robocopy ".\$dir" (Join-Path $App $dir) /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }
}

New-Item -ItemType Directory -Force (Join-Path $App "node_modules") | Out-Null
foreach ($mod in @("bootstrap-icons", "pdfjs-dist", "tarballjs")) {
    $from = Join-Path (Get-Location) "node_modules\$mod"
    $to = Join-Path $App "node_modules\$mod"
    if (Test-Path $from) {
        robocopy $from $to /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }
}

Rename-Item (Join-Path $Out "electron.exe") "WebPlotDigitizer-Bilingual.exe" -Force
$Exe = Join-Path $Out "WebPlotDigitizer-Bilingual.exe"
if (!(Test-Path $Exe)) { throw "Final exe not found." }

Step "Create shortcuts"
$Wsh = New-Object -ComObject WScript.Shell
$ShortcutCN = Join-Path $env:USERPROFILE "Desktop\WebPlotDigitizer $WpdVersion Chinese.lnk"
$S = $Wsh.CreateShortcut($ShortcutCN)
$S.TargetPath = $Exe
$S.Arguments = "--lang=zh_CN"
$S.WorkingDirectory = Split-Path $Exe
$S.Save()

$ShortcutEN = Join-Path $env:USERPROFILE "Desktop\WebPlotDigitizer $WpdVersion English.lnk"
$S = $Wsh.CreateShortcut($ShortcutEN)
$S.TargetPath = $Exe
$S.Arguments = "--lang=en_US"
$S.WorkingDirectory = Split-Path $Exe
$S.Save()

Step "Done"
Write-Host "Portable folder: $Out"
Write-Host "Executable: $Exe"
Write-Host "Chinese shortcut: $ShortcutCN"
Write-Host "English shortcut: $ShortcutEN"
