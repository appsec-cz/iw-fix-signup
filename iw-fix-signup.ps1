<#
.SYNOPSIS
    Mitigation for the IceWarp WebClient signup / path-traversal issue (Windows).

.DESCRIPTION
    Performs two changes:
      1) XML  config\_webmail\settings.xml
           <restrictions>:    disable_signup=1, disable_signup_ip=1
           <layout_settings>: disable_signup=1
      2) PHP  html\_shared\tools\filesystem.php
           Injects a path-traversal guard into downloadFile():
             if (preg_match('/\.\./',$path)) { throw new Exc('invalid_path'); }

    - Auto-detects the install dir from the registry
      (HKLM\SOFTWARE\WOW6432Node\IceWarp\IceWarp Server\InstallDir), the
      IceWarp service, or common paths.
    - Load-balanced (LB) clusters: reads path.dat for the shared config folder.
    - Read-only shared config in LB: warns and continues with the PHP hotfix.
    - Timestamped backups, idempotent, verification, optional service restart.

.PARAMETER Path        Explicit IceWarp installation folder.
.PARAMETER Config      Explicit webmail config root (folder containing _webmail).
.PARAMETER NoRestart   Do not restart the IceWarp service.
.PARAMETER DryRun      Show changes, write nothing.

.EXAMPLE
    .\iw-fix-signup.ps1                  # run elevated (Administrator)
.EXAMPLE
    .\iw-fix-signup.ps1 -Path "D:\IceWarp" -NoRestart
.NOTES
    Run as Administrator. Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$Config,
    [switch]$NoRestart,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
# Never die silently: surface any unhandled error and exit with a clear message.
trap { Write-Host "[x] ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$script:LB = $false
$script:RC = 0

function Write-Info { param($m) Write-Host "[*] $m" }
function Write-Ok   { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Die { param($m,[int]$code=1) Write-Host "[x] ERROR: $m" -ForegroundColor Red; exit $code }

#---------------------------------------------------------------- detection
function Test-IwRoot { param([string]$Dir)
    return ($Dir -and (Test-Path -LiteralPath $Dir -PathType Container) -and
            ((Test-Path -LiteralPath (Join-Path $Dir 'html') -PathType Container) -or
             (Test-Path -LiteralPath (Join-Path $Dir 'config') -PathType Container)))
}
function Resolve-IwRoot { param([string]$Dir)
    $d = $Dir
    for ($i=0; $i -lt 4 -and $d; $i++) {
        if (Test-IwRoot $d) { return $d.TrimEnd('\') }
        $p = Split-Path -Parent $d; if ($p -eq $d) { break }; $d = $p
    }
    return $null
}
function Get-IwInstallDir {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($Path) { $cands.Add($Path) }

    # Registry InstallDir (authoritative)
    foreach ($rk in @('HKLM:\SOFTWARE\WOW6432Node\IceWarp\IceWarp Server',
                      'HKLM:\SOFTWARE\IceWarp\IceWarp Server')) {
        try {
            $v = (Get-ItemProperty -Path $rk -Name InstallDir -ErrorAction Stop).InstallDir
            if ($v) { $cands.Add(([string]$v).TrimEnd('\')) }
        } catch { }
    }
    # IceWarp service -> exe path -> root
    try {
        Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*icewarp*' -or $_.DisplayName -like '*IceWarp*' } |
            ForEach-Object {
                if ($_.PathName) {
                    $exe = $_.PathName.Trim()
                    if ($exe.StartsWith('"')) { $exe = ($exe -split '"')[1] } else { $exe = ($exe -split '\s+')[0] }
                    if ($exe) { $cands.Add((Split-Path -Parent $exe)) }
                }
            }
    } catch { }
    # NOTE: no `Get-ChildItem -Recurse` over the registry here. IceWarp keeps a
    # very deep registry tree and recursing it can raise an UNCATCHABLE
    # StackOverflowException (kills the process; trap/try-catch cannot stop it).
    # The direct InstallDir reads above + the common paths below are enough.
    foreach ($b in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) { if ($b) { $cands.Add((Join-Path $b 'IceWarp')) } }
    $cands.Add('C:\Program Files\IceWarp'); $cands.Add('C:\Program Files (x86)\IceWarp'); $cands.Add('C:\IceWarp')

    foreach ($c in $cands) { if ($c) { $r = Resolve-IwRoot $c; if ($r) { return $r } } }
    return $null
}
function Resolve-ConfigRoot { param([string]$Root)
    if ($Config) { return $Config.TrimEnd('\') }
    $pd = Join-Path $Root 'path.dat'
    if (Test-Path -LiteralPath $pd -PathType Leaf) {
        $script:LB = $true
        $shared = (Get-Content -LiteralPath $pd -TotalCount 1).Trim()
        if ($shared -and (Test-Path -LiteralPath (Join-Path $shared '_webmail\settings.xml') -PathType Leaf)) {
            return $shared.TrimEnd('\')
        }
        Write-Warn "path.dat found (LB environment) but shared settings.xml not found under: $shared\_webmail"
        Write-Warn "Falling back to the local config folder."
    }
    return (Join-Path $Root 'config')
}

#---------------------------------------------------------------- XML edit
function Add-AfterNode { param($Xml,$Item,$NewNode,$RefNode)
    $indent = "`n            "; $p = $RefNode.PreviousSibling
    if ($p -and $p.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) { $indent = $p.Value }
    $ins = $Item.InsertAfter($NewNode,$RefNode); [void]$Item.InsertBefore($Xml.CreateWhitespace($indent),$ins)
}
function Add-FirstChild { param($Xml,$Item,$NewNode)
    $a = $Item.SelectSingleNode('*')
    if ($a) { $indent = "`n            "; $p = $a.PreviousSibling
        if ($p -and $p.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) { $indent = $p.Value }
        [void]$Item.InsertBefore($NewNode,$a); [void]$Item.InsertBefore($Xml.CreateWhitespace($indent),$a)
    } else {
        [void]$Item.AppendChild($Xml.CreateWhitespace("`n            ")); [void]$Item.AppendChild($NewNode)
        [void]$Item.AppendChild($Xml.CreateWhitespace("`n        "))
    }
}
function Update-SignupXml { param([string]$File)
    $xml = New-Object System.Xml.XmlDocument; $xml.PreserveWhitespace = $true; $xml.Load($File)
    $status = @{}
    foreach ($sec in @('restrictions','layout_settings')) {
        $section = $xml.SelectSingleNode("//$sec")
        if (-not $section) {
            $section = $xml.CreateElement($sec)
            [void]$xml.DocumentElement.AppendChild($xml.CreateWhitespace("`n    "))
            [void]$xml.DocumentElement.AppendChild($section)
            [void]$xml.DocumentElement.AppendChild($xml.CreateWhitespace("`n"))
        }
        $item = $section.SelectSingleNode('item')
        if (-not $item) {
            $item = $xml.CreateElement('item')
            [void]$section.AppendChild($xml.CreateWhitespace("`n        "))
            [void]$section.AppendChild($item)
            [void]$section.AppendChild($xml.CreateWhitespace("`n    "))
        }
        $node = $item.SelectSingleNode('disable_signup')
        if ($node) { $node.InnerText='1'; $node.SetAttribute('useraccess','view'); $node.SetAttribute('domainadminaccess','view'); $status["$sec/disable_signup"]='set' }
        else {
            $new = $xml.CreateElement('disable_signup'); $new.SetAttribute('useraccess','view'); $new.SetAttribute('domainadminaccess','view'); $new.InnerText='1'
            Add-FirstChild -Xml $xml -Item $item -NewNode $new; $status["$sec/disable_signup"]='inserted'
        }
        if ($sec -eq 'restrictions') {
            $n2 = $item.SelectSingleNode('disable_signup_ip')
            if ($n2) { $n2.InnerText='1'; $status["$sec/disable_signup_ip"]='set' }
            else {
                $new2 = $xml.CreateElement('disable_signup_ip'); $new2.InnerText='1'
                $ref = $item.SelectSingleNode('disable_signup')
                if ($ref) { Add-AfterNode -Xml $xml -Item $item -NewNode $new2 -RefNode $ref } else { Add-FirstChild -Xml $xml -Item $item -NewNode $new2 }
                $status["$sec/disable_signup_ip"]='inserted'
            }
        }
    }
    return @{ status=$status; doc=$xml }
}
function Save-Xml { param([System.Xml.XmlDocument]$Doc,[string]$File)
    $ws = New-Object System.Xml.XmlWriterSettings
    $ws.Encoding = New-Object System.Text.UTF8Encoding($false); $ws.Indent = $false; $ws.OmitXmlDeclaration = (-not ($Doc.FirstChild -is [System.Xml.XmlDeclaration]))
    $w = [System.Xml.XmlWriter]::Create($File,$ws); try { $Doc.Save($w) } finally { $w.Dispose() }
}
function Test-SignupOk { param([string]$File)
    $xml = New-Object System.Xml.XmlDocument; $xml.PreserveWhitespace=$true; $xml.Load($File); $ok=$true
    foreach ($c in @(@('restrictions','disable_signup'),@('restrictions','disable_signup_ip'),@('layout_settings','disable_signup'))) {
        $n = $xml.SelectSingleNode("//$($c[0])/item/$($c[1])")
        if (-not $n) { Write-Warn "  $($c[0])/$($c[1]): missing"; $ok=$false }
        elseif ($n.InnerText.Trim() -ne '1') { Write-Warn "  $($c[0])/$($c[1]): value='$($n.InnerText.Trim())' (expected 1)"; $ok=$false }
    }
    return $ok
}

#---------------------------------------------------------------- helpers
function Test-Writable { param([string]$File)
    try { $fs=[System.IO.File]::Open($File,'Open','ReadWrite'); $fs.Close(); return $true } catch { return $false }
}
function Test-DirWritable { param([string]$Dir)
    try { $t = Join-Path $Dir ([System.IO.Path]::GetRandomFileName()); [System.IO.File]::WriteAllText($t,'x'); Remove-Item -LiteralPath $t -Force; return $true } catch { return $false }
}
function Backup-File { param([string]$File)
    $bdir = Join-Path $script:Root 'iw-fix-signup-backup'   # outside the web root (not servable)
    if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
    $bak = Join-Path $bdir ((Split-Path -Leaf $File) + ".bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')")
    Copy-Item -LiteralPath $File -Destination $bak -Force; Write-Ok "Backup: $bak"; return $bak
}

#---------------------------------------------------------------- start
Write-Info 'Detecting IceWarp installation...'
$root = Get-IwInstallDir
if (-not $root) {
    Write-Warn 'Could not auto-detect the IceWarp installation (checked registry InstallDir, the IceWarp service, and common paths).'
    Die "Re-run with the path explicitly, e.g.:  powershell -ExecutionPolicy Bypass -File .\iw-fix-signup.ps1 -Path 'C:\Program Files\IceWarp'" 3
}
$root = $root.TrimEnd('\')
$script:Root = $root
$cfg  = Resolve-ConfigRoot $root
$settings = Join-Path $cfg '_webmail\settings.xml'
$phpFile  = Join-Path $root 'html\_shared\tools\filesystem.php'
Write-Ok   "Install dir : $root"
Write-Info "Config root : $cfg"
Write-Info ("LB cluster  : " + $(if ($script:LB) {'yes'} else {'no'}))
Write-Info "Settings XML: $settings"
Write-Info "Filesystem  : $phpFile"
Write-Host "------------------------------------------------"

$Skeleton = @'
<settings>
<restrictions><item><disable_signup useraccess="view" domainadminaccess="view">1</disable_signup></item></restrictions>
<layout_settings><item><disable_signup useraccess="view" domainadminaccess="view">1</disable_signup></item></layout_settings>
</settings>
'@

#========================= 1) XML =========================
if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) {
    # settings.xml does not exist -> create it from the skeleton (same transform).
    $tmpSkel = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmpSkel, $Skeleton, (New-Object System.Text.UTF8Encoding($false)))
    try { $res = Update-SignupXml -File $tmpSkel } catch { Die "Failed to build skeleton XML: $($_.Exception.Message)" 3 }
    Remove-Item -LiteralPath $tmpSkel -ErrorAction SilentlyContinue
    $xmldir = Split-Path -Parent $settings
    if ($DryRun) {
        $t2 = [System.IO.Path]::GetTempFileName(); Save-Xml -Doc $res.doc -File $t2
        Write-Info "XML DRY-RUN: $settings does not exist - would CREATE it with:"
        Get-Content -LiteralPath $t2 | ForEach-Object { Write-Host "    | $_" }
        Remove-Item -LiteralPath $t2 -ErrorAction SilentlyContinue
    } else {
        if (-not (Test-Path -LiteralPath $xmldir)) { try { New-Item -ItemType Directory -Path $xmldir -Force | Out-Null } catch {} }
        if ((Test-Path -LiteralPath $xmldir) -and (Test-DirWritable $xmldir)) {
            try { Save-Xml -Doc $res.doc -File $settings } catch { Die "Cannot create settings.xml: $($_.Exception.Message) (run as Administrator)" 4 }
            [System.IO.File]::AppendAllText($settings, "`n", (New-Object System.Text.UTF8Encoding($false)))  # trailing newline (match bash)
            if (Test-SignupOk $settings) { Write-Ok "XML: created ($settings) and verified." } else { Die "XML create verification failed." 5 }
        } else {
            if ($script:LB) { Write-Warn "XML: config dir not writable (LB): $xmldir. Continuing with the local PHP hotfix." }
            else { Die "Config directory not writable: $xmldir (run as Administrator)" 4 }
        }
    }
} else {
    try { $res = Update-SignupXml -File $settings } catch { Die "Failed to parse XML: $($_.Exception.Message)" 3 }
    foreach ($k in $res.status.Keys) {
        if ($res.status[$k] -eq 'no-section') { Die "Section for '$k' not found. XML unchanged." 3 }
        if ($res.status[$k] -eq 'no-item')    { Die "Section for '$k' has no <item>. XML unchanged." 3 }
    }
    $tmp = [System.IO.Path]::GetTempFileName(); Save-Xml -Doc $res.doc -File $tmp
    $changed = -not ([System.IO.File]::ReadAllText($tmp) -ceq [System.IO.File]::ReadAllText($settings))
    if (-not $changed) { Write-Ok 'XML: already set (no change).' }
    elseif ($DryRun) {
        Write-Info 'XML DRY-RUN diff:'
        (Compare-Object (Get-Content $settings) (Get-Content $tmp)) | ForEach-Object {
            $s = if ($_.SideIndicator -eq '=>'){'+ '}else{'- '}; Write-Host ($s + $_.InputObject) }
    }
    elseif (Test-Writable $settings) {
        $bak = Backup-File $settings
        try { Copy-Item -LiteralPath $tmp -Destination $settings -Force } catch { Die "XML write failed: $($_.Exception.Message)" 4 }
        if (Test-SignupOk $settings) { Write-Ok 'XML: updated and verified.' } else { Die "XML verification failed. Restore $bak" 5 }
    }
    else {
        if ($script:LB) { Write-Warn 'XML: settings.xml is read-only (LB shared config). Update it on the writable/master node.'; Write-Warn 'Continuing with the local PHP hotfix.' }
        else { Die "settings.xml is not writable: $settings (run as Administrator)" 4 }
    }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
Write-Host "------------------------------------------------"

#========================= 2) PHP =========================
if (-not (Test-Path -LiteralPath $phpFile -PathType Leaf)) {
    Write-Warn "filesystem.php not found - PHP hotfix NOT applied ($phpFile)"
    Write-Warn "The path-traversal mitigation is incomplete on this node."
    $script:RC = 3
} else {
    $php = Get-Content -LiteralPath $phpFile -Raw
    if ($php -match 'invalid_path') { Write-Ok 'PHP: guard already present (no change).' }
    else {
        $rx = '((?:(?:public|private|protected|static)\s+)*function\s+downloadFile\s*\([^)]*\)\s*\{)'
        if ($php -notmatch $rx) { Write-Warn 'PHP: downloadFile() not found - left unchanged. Apply the guard manually.'; $script:RC = 3 }
        else {
            $m = $Matches[1]
            $nl = if ($php -match "`r`n") { "`r`n" } else { "`n" }
            $inj = "        if (preg_match('/\.\./',`$path)) { throw new Exc('invalid_path'); }"
            $newPhp = $php.Replace($m, "$m$nl$inj")
            if ($DryRun) {
                Write-Info 'PHP DRY-RUN - line to insert after downloadFile() {:'
                Write-Host ("+ " + $inj)
            }
            elseif (Test-Writable $phpFile) {
                $bak = Backup-File $phpFile
                try { Set-Content -LiteralPath $phpFile -Value $newPhp -NoNewline } catch { Die "PHP write failed: $($_.Exception.Message)" 4 }
                $chk = Get-Content -LiteralPath $phpFile -Raw
                if ($chk.Contains('invalid_path') -and $chk.Contains("preg_match('/\.\./'")) { Write-Ok 'PHP: guard injected and verified.' }
                else { Die "PHP verification failed. Restore $bak" 5 }
            }
            else {
                if ($script:LB) { Write-Warn 'PHP: filesystem.php is read-only. Apply on the writable node.'; $script:RC = 3 }
                else { Die "filesystem.php is not writable: $phpFile (run as Administrator)" 4 }
            }
        }
    }
}
Write-Host "------------------------------------------------"

#========================= 3) restart =========================
if ($DryRun) { Write-Info 'DRY-RUN complete - nothing was written.'; exit 0 }
if (-not $NoRestart) {
    $svc = Get-Service -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*icewarp*' -or $_.DisplayName -like '*IceWarp*' } |
           Sort-Object { $_.DisplayName -ne 'IceWarp Server' } | Select-Object -First 1
    if ($svc) {
        Write-Warn "Restarting service '$($svc.DisplayName)' - this briefly restarts ALL IceWarp modules."
        try { Restart-Service -Name $svc.Name -Force; Write-Ok "Service '$($svc.DisplayName)' restarted." }
        catch { Write-Warn "Service restart failed: $($_.Exception.Message). Restart via Remote Console (System > Services)." }
    } else { Write-Warn 'IceWarp service not found. Restart via Remote Console (System > Services > Restart All Modules).' }
} else { Write-Info 'Restart skipped (-NoRestart). Restart modules via Remote Console (System > Services).' }

Write-Host "------------------------------------------------"
if ($script:RC -eq 0) { Write-Ok 'Done. Mitigation applied successfully.' }
else { Write-Warn 'Done with warnings - review the messages above; mitigation may be incomplete.' }
Write-Host 'Note: this is a mitigation. Upgrade to a fixed IceWarp build when available.'
exit $script:RC
