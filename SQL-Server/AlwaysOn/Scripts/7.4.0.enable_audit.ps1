<#
.SYNOPSIS
    Configure l'audit serveur SQL (Audit-OPTIMEDIT) sur SQLS01 et SQLS02.

.DESCRIPTION
    Chapitre 7.4 - Audits SQL Server.
    Cree un SERVER AUDIT avec UNE SEULE specification (contrainte SQL Server)
    regroupant 14 groupes d'actions (connexions, DDL, privileges, etc.).
    Execute en une seule commande sur les deux noeuds via $TargetNodes.

.PARAMETER SqlScriptPath
    Chemin du .sql. Defaut : .\Scripts-T-SQL\7.4.0.enable_audit.sql

.PARAMETER TargetNodes
    Noeuds cibles. Defaut : SQLS01 + SQLS02.

.EXAMPLE
    .\7.4.0.enable_audit.ps1 -WhatIf
    .\7.4.0.enable_audit.ps1

.NOTES
    Version : 0.2
    Note importante : SQL Server n'autorise qu'UNE SEULE SERVER AUDIT SPECIFICATION
    par SERVER AUDIT. Tous les groupes d'actions sont donc dans une spec unique.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$SqlScriptPath = ".\Scripts-T-SQL\7.4.0.enable_audit.sql",
    [string[]]$TargetNodes = @("SQLS01.optimedit.eu", "SQLS02.optimedit.eu"),
    [string]$TranscriptPath = ".\7.4.0.enable_audit.log"
)

$ErrorActionPreference = "Stop"

try {
    Start-Transcript -Path $TranscriptPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de demarrer la transcription : $($_.Exception.Message)"
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" }
        "INFO" { "Cyan" } "SKIP" { "DarkGray" } default { "White" }
    }
    $prefix = switch ($Status) {
        "OK" { "[OK]   " } "WARN" { "[WARN] " } "ERROR" { "[ERR]  " }
        "INFO" { "[INFO] " } "SKIP" { "[SKIP] " } default { "[----] " }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

try {
    Write-Section "7.4.0 - Audits SQL Server"
    Write-Host " Nodes    : $($TargetNodes -join ', ')" -ForegroundColor Gray
    Write-Host " SQL      : $SqlScriptPath" -ForegroundColor Gray
    Write-Host " Date     : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode     : $(if ($WhatIfPreference) { 'WhatIf' } else { 'Execution reelle' })" -ForegroundColor Gray

    # --- PRE-VOL 1 : Module SqlServer ---
    Write-Section "Pre-vol 1/3 : Module SqlServer"
    if (-not (Get-Module -Name SqlServer -ListAvailable -ErrorAction SilentlyContinue)) {
        throw "Module SqlServer introuvable."
    }
    if (-not (Get-Module -Name SqlServer -ErrorAction SilentlyContinue)) {
        Import-Module SqlServer -ErrorAction Stop
    }
    $m = Get-Module -Name SqlServer | Select-Object -First 1
    Write-Step "Module SqlServer v$($m.Version)" "OK"

    # --- PRE-VOL 2 : Fichier SQL present ---
    Write-Section "Pre-vol 2/3 : Fichier SQL source"
    if (-not (Test-Path -Path $SqlScriptPath -PathType Leaf)) {
        throw "Fichier introuvable : $SqlScriptPath"
    }
    $fileInfo = Get-Item $SqlScriptPath
    Write-Step "Trouve : $($fileInfo.Name) ($($fileInfo.Length) octets)" "OK"

    # --- PRE-VOL 3 : Dossier de destination sur chaque noeud ---
    Write-Section "Pre-vol 3/3 : Dossier S:\SQL\Backup\Audit sur les noeuds"
    foreach ($node in $TargetNodes) {
        $shortName = ($node -split '\.')[0]
        $ok = Invoke-Command -ComputerName $node -ScriptBlock {
            Test-Path "S:\SQL\Backup\Audit"
        } -ErrorAction Stop
        if (-not $ok) {
            throw "Dossier S:\SQL\Backup\Audit introuvable sur $node. Executer 3.1.0.create_storage_directories.ps1."
        }
        Write-Step "$shortName : dossier present" "OK"
    }

    # --- EXECUTION ---
    foreach ($node in $TargetNodes) {
        Write-Section "Traitement de $node"

        if ($WhatIfPreference) {
            Write-Step "[WhatIf] Execution de $SqlScriptPath sur $node" "SKIP"
            continue
        }

        if ($PSCmdlet.ShouldProcess($node, "Configurer l'audit serveur")) {
            try {
                Invoke-Sqlcmd -ServerInstance $node -Database master `
                              -InputFile $SqlScriptPath `
                              -TrustServerCertificate `
                              -Verbose -ErrorAction Stop | Out-Null
                Write-Step "Audit configure sur $node" "OK"
            } catch {
                Write-Step "Erreur sur $node : $($_.Exception.Message)" "ERROR"
                throw
            }
        }
    }

    # --- VERIFICATION POST-EXECUTION ---
    if (-not $WhatIfPreference) {
        Write-Section "Verification post-execution"
        foreach ($node in $TargetNodes) {
            Write-Host ""
            Write-Host "  Audit sur $node :" -ForegroundColor Cyan
            $q = @"
SELECT name AS AuditName, is_state_enabled, on_failure_desc
FROM sys.server_audits WHERE name = N'Audit-OPTIMEDIT';

SELECT name AS SpecName, is_state_enabled
FROM sys.server_audit_specifications WHERE name = N'AuditSpec-OPTIMEDIT';

SELECT 
    s.name AS SpecName,
    COUNT(sad.audit_action_id) AS NbActions
FROM sys.server_audit_specifications s
JOIN sys.server_audit_specification_details sad 
    ON s.server_specification_id = sad.server_specification_id
WHERE s.name = N'AuditSpec-OPTIMEDIT'
GROUP BY s.name;
"@
            Invoke-Sqlcmd -ServerInstance $node -Query $q -TrustServerCertificate | Format-Table -AutoSize
        }
    }

    # --- RESUME ---
    Write-Section "Resume"
    Write-Host ""
    Write-Host "  Nodes          : $($TargetNodes -join ', ')" -ForegroundColor Cyan
    Write-Host "  Audit          : Audit-OPTIMEDIT" -ForegroundColor Cyan
    Write-Host "  Specification  : AuditSpec-OPTIMEDIT (14 groupes d'actions)" -ForegroundColor Cyan
    Write-Host "  Sortie         : S:\SQL\Backup\Audit\ (100 Mo x 10 fichiers = 1 Go max)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [OK] Audit serveur configure et actif sur les deux noeuds" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [!] Note : un redemarrage du service MSSQLSERVER est recommande" -ForegroundColor Yellow
    Write-Host "      pour garantir que l'audit demarre proprement au boot." -ForegroundColor Yellow
    Write-Host ""

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log : $TranscriptPath" -ForegroundColor DarkGray
}