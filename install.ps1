# hn-commander installer (Windows 10/11, Windows PowerShell 5.1 or PowerShell 7)
#   install:   iex (irm https://raw.githubusercontent.com/pwdks/hn-commander/main/install.ps1)
#   uninstall: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/pwdks/hn-commander/main/install.ps1))) -Uninstall
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$Repo   = 'pwdks/hn-commander'
$Branch = if ($env:HN_BRANCH) { $env:HN_BRANCH } else { 'main' }
$HnHome = if ($env:HN_HOME) { $env:HN_HOME } else { Join-Path $env:USERPROFILE '.hn-commander' }
$Skills = @('hn-setup', 'hn-mod-role')
$SkillDirs = @((Join-Path $env:USERPROFILE '.claude\skills'), (Join-Path $env:USERPROFILE '.agents\skills'))  # Claude Code, Codex

if ($Uninstall) {
  foreach ($d in $SkillDirs) { foreach ($s in $Skills) { $p = Join-Path $d $s; if (Test-Path $p) { Remove-Item $p -Recurse -Force } } }
  if (Test-Path $HnHome) { Remove-Item $HnHome -Recurse -Force }
  Write-Host 'hn-commander removed. (Project files such as .harness\ were not touched.)'
  return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('hn-commander-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
try {
  Write-Host "Downloading $Repo ($Branch)..."
  $zip = Join-Path $tmp 'src.zip'
  Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
  if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'harness\bin\hn.sh'))) { throw 'unexpected archive layout' }

  if (Test-Path $HnHome) { Remove-Item $HnHome -Recurse -Force }
  New-Item -ItemType Directory (Split-Path $HnHome -Parent) -Force | Out-Null
  Move-Item $src.FullName $HnHome

  foreach ($d in $SkillDirs) {
    foreach ($s in $Skills) {
      $dest = Join-Path $d $s
      New-Item -ItemType Directory $dest -Force | Out-Null
      Copy-Item (Join-Path $HnHome "skills\$s\SKILL.md") (Join-Path $dest 'SKILL.md') -Force
    }
  }
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$ver = (Get-Content (Join-Path $HnHome 'VERSION') -Raw).Trim()
Write-Host ''
Write-Host "hn-commander $ver installed -> $HnHome"
Write-Host '  Claude Code : /hn-setup , /hn-mod-role'
Write-Host '  Codex       : $hn-setup , $hn-mod-role'
Write-Host ''
$gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
if (Test-Path $gitBash) { Write-Host '  [ok]      Git Bash' } else { Write-Host '  [missing] Git Bash  (required: install Git for Windows)' }
foreach ($c in @('claude', 'codex')) {
  if (Get-Command $c -ErrorAction SilentlyContinue) { Write-Host "  [ok]      $c" } else { Write-Host "  [missing] $c  (needed only if you use it)" }
}
Write-Host ''
Write-Host 'Restart Claude Code / Codex, open your project folder, and run /hn-setup (Codex: $hn-setup).'
