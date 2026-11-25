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
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
  $codexAgents = Join-Path $codexHome 'AGENTS.md'
  if (Test-Path $codexAgents) {  # remove only the language block that hn-commander added
    $t = [IO.File]::ReadAllText($codexAgents)
    $t2 = [regex]::Replace($t, '(\r?\n)*<!-- hn-commander:lang -->[\s\S]*?<!-- hn-commander:lang-end -->\r?\n?', [Environment]::NewLine)
    if ($t2 -ne $t) { [IO.File]::WriteAllText($codexAgents, $t2.TrimStart()) }
  }
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

  $registry = Join-Path $HnHome 'projects.txt'   # projects set up with hn-commander (kept across updates)
  $projects = if (Test-Path $registry) { [IO.File]::ReadAllText($registry) } else { $null }
  if (Test-Path $HnHome) { Remove-Item $HnHome -Recurse -Force }
  New-Item -ItemType Directory (Split-Path $HnHome -Parent) -Force | Out-Null
  Move-Item $src.FullName $HnHome
  if ($projects) { [IO.File]::WriteAllText($registry, $projects) }

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
if (Test-Path $gitBash) {
  Write-Host 'Updating projects:'
  & (Join-Path $HnHome 'harness\bin\hn.cmd') update-all
  Write-Host ''
}
Write-Host 'Restart Claude Code / Codex. New project: open its folder and run /hn-setup (Codex: $hn-setup).'
