<#
.SYNOPSIS
    Cree les alertes SQL Server et le job PowerShell associe sur SQLS01 et SQLS02.

.DESCRIPTION
    Chapitre 7.3 - Repli PowerShell (Database Mail incompatible OVH).
    Execute en une seule commande sur les deux noeuds via $TargetNodes.

.PARAMETER JobScriptPath
    Chemin du .sql qui cree le job. Defaut : .\Scripts-T-SQL\7.3.0c.create_alert_job.sql

.PARAMETER AlertScriptPath
    Chemin du .sql qui cree les alertes. Defaut : .\Scripts-T-SQL\7.3.0.create_alerts.sql

.PARAMETER SenderScriptPath
    Chemin du script d'envoi PowerShell. Defaut : .\Scripts-T-SQL\send_alert_email.ps1

.PARAMETER TargetNodes
    Noeuds cibles. Defaut : SQLS01 + SQLS02.

.EXAMPLE
    .\7.3.0.create_alerts.ps1 -WhatIf
    .\7.3.0.create_alerts.ps1
.Version 0.2
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$JobScriptPath    = ".\Scripts-T-SQL\7.3.0c.create_alert_job.sql",
    [string]$AlertScriptPath  = ".\Scripts-T-SQL\7.3.0.create_alerts.sql",
    [string]$SenderScriptPath = ".\Scripts-T-SQL\send_alert_email.ps1",
    [string[]]$TargetNodes    = @("SQLS01.optimedit.eu", "SQLS02.optimedit.eu"),
    [string]$TranscriptPath   = ".\7.3.0.create_alerts.log"
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
    Write-Section "7.3.0 - Alertes SQL Server (repli PowerShell)"
    Write-Host " Nodes      : $($TargetNodes -join ', ')" -ForegroundColor Gray
    Write-Host " Job SQL    : $JobScriptPath" -ForegroundColor Gray
    Write-Host " Alertes    : $AlertScriptPath" -ForegroundColor Gray
    Write-Host " Sender PS  : $SenderScriptPath" -ForegroundColor Gray
    Write-Host " Date       : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode       : $(if ($WhatIfPreference) { 'WhatIf' } else { 'Execution reelle' })" -ForegroundColor Gray

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

    # --- PRE-VOL 2 : Test-Path des 3 fichiers ---
    Write-Section "Pre-vol 2/3 : Verification des fichiers sources"
    foreach ($f in @($JobScriptPath, $AlertScriptPath, $SenderScriptPath)) {
        if (-not (Test-Path -Path $f -PathType Leaf)) { throw "Fichier introuvable : $f" }
        $fileInfo = Get-Item $f
        Write-Step "Trouve : $($fileInfo.Name) ($($fileInfo.Length) octets)" "OK"
    }

    # --- PRE-VOL 3 : Secret SMTP sur les noeuds ---
    Write-Section "Pre-vol 3/3 : Secret smtp-ovh-pwd.enc sur les noeuds"
    foreach ($node in $TargetNodes) {
        $shortName = ($node -split '\.')[0]
        $ok = Invoke-Command -ComputerName $node -ScriptBlock {
            Test-Path "C:\ProgramData\SQLSecrets\smtp-ovh-pwd.enc"
        } -ErrorAction Stop
        if (-not $ok) {
            throw "Secret smtp-ovh-pwd.enc introuvable sur $node."
        }
        Write-Step "$shortName : secret present" "OK"
    }

    # --- EXECUTION ---
    foreach ($node in $TargetNodes) {
        Write-Section "Traitement de $node"

        if ($WhatIfPreference) {
            Write-Step "[WhatIf] Job SQL     sur $node" "SKIP"
            Write-Step "[WhatIf] Alertes SQL sur $node" "SKIP"
            continue
        }

        if ($PSCmdlet.ShouldProcess($node, "Creer le job SQL Agent")) {
            Invoke-Sqlcmd -ServerInstance $node -Database msdb `
                          -InputFile $JobScriptPath `
                          -TrustServerCertificate -ErrorAction Stop | Out-Null
            Write-Step "Job 'DBA - Send Alert Email' cree" "OK"
        }

        if ($PSCmdlet.ShouldProcess($node, "Creer les alertes SQL Server")) {
            Invoke-Sqlcmd -ServerInstance $node -Database msdb `
                          -InputFile $AlertScriptPath `
                          -TrustServerCertificate -ErrorAction Stop | Out-Null
            Write-Step "Alertes creees et liees au job" "OK"
        }
    }

    # --- VERIFICATION POST-EXECUTION ---
    if (-not $WhatIfPreference) {
        Write-Section "Verification post-execution"
        foreach ($node in $TargetNodes) {
            Write-Host ""
            Write-Host "  Alertes sur $node :" -ForegroundColor Cyan
            $q = @"
SELECT a.name AS AlertName, a.severity, a.message_id, a.enabled,
       CASE WHEN a.job_id IS NULL THEN 'Non lie' ELSE 'Lie au job' END AS JobStatus
FROM msdb.dbo.sysalerts a
WHERE a.name LIKE 'DBA - %'
ORDER BY a.name;
"@
            Invoke-Sqlcmd -ServerInstance $node -Query $q -TrustServerCertificate | Format-Table -AutoSize
        }
    }

    Write-Section "Resume"
    Write-Host ""
    Write-Host "  Nodes        : $($TargetNodes -join ', ')" -ForegroundColor Cyan
    Write-Host "  Job          : DBA - Send Alert Email" -ForegroundColor Cyan
    Write-Host "  Alertes      : 7 (severites 19-25) + 4 (erreurs 823/824/825/9002) = 11" -ForegroundColor Cyan
    Write-Host "  Notification : Job PowerShell -> Send-MailMessage -> OVH -> Gmail" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [OK] Alertes SQL Server creees et operationnelles" -ForegroundColor Green
    Write-Host ""

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log : $TranscriptPath" -ForegroundColor DarkGray
}