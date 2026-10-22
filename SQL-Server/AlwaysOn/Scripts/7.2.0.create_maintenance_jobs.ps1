<#
.SYNOPSIS
    Exécute 7.2.0.create_maintenance_jobs.sql sur le nœud PRIMARY de l'AG.

.DESCRIPTION
    Wrapper PowerShell pour créer les jobs SQL Agent de maintenance
    (Backup FULL hebdomadaire + DBCC CHECKDB hebdomadaire) sur le nœud
    PRIMARY de l'Availability Group AG-OPTIMEDIT.

    Vérifie que :
      - Le module SqlServer est disponible
      - La connexion SQL fonctionne
      - Le nœud cible est bien PRIMARY
      - Le fichier .sql source existe
    Puis exécute le .sql via Invoke-Sqlcmd.

.PARAMETER PrimaryNode
    Nœud PRIMARY de l'AG. Défaut : SQLS01.optimedit.eu

.PARAMETER AvailabilityGroupName
    Nom de l'AG. Défaut : AG-OPTIMEDIT

.PARAMETER SqlScriptPath
    Chemin du fichier .sql. Défaut : .\7.2.0.create_maintenance_jobs.sql

.PARAMETER TranscriptPath
    Chemin du log. Défaut : .\7.2.0.create_maintenance_jobs.log

.EXAMPLE
    .\7.2.0.create_maintenance_jobs.ps1 -WhatIf
    .\7.2.0.create_maintenance_jobs.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [string]$PrimaryNode = "SQLS01.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [string]$AvailabilityGroupName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [string]$SqlScriptPath = ".\Scripts-T-SQL\7.2.0.create_maintenance_jobs.sql", # Attention au path si renommer

    [Parameter(Mandatory = $false)]
    [string]$TranscriptPath = ".\7.2.0.create_maintenance_jobs.log"
)

$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()

try {
    Start-Transcript -Path $TranscriptPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de démarrer la transcription : $($_.Exception.Message)"
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

function Ensure-Module {
    param([string]$Name, [string]$InstallHint = "")
    $loaded = Get-Module -Name $Name -ErrorAction SilentlyContinue
    if ($loaded) { return [PSCustomObject]@{ Version = $loaded.Version; Action = "Déjà chargé" } }
    $available = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue |
                 Sort-Object Version -Descending | Select-Object -First 1
    if (-not $available) {
        $msg = "Module '$Name' introuvable."
        if ($InstallHint) { $msg += "`n  → $InstallHint" }
        throw $msg
    }
    Import-Module -Name $Name -ErrorAction Stop
    return [PSCustomObject]@{ Version = $available.Version; Action = "Importé" }
}

try {
    Write-Section "7.2.0 - Création des jobs SQL Agent de maintenance"
    Write-Host " Primary Node    : $PrimaryNode" -ForegroundColor Gray
    Write-Host " AG Name         : $AvailabilityGroupName" -ForegroundColor Gray
    Write-Host " SQL Script      : $SqlScriptPath" -ForegroundColor Gray
    Write-Host " Mode            : $(if ($WhatIfPreference) { 'WhatIf' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Date            : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Module SqlServer ---
    Write-Section "Pré-vol 1/4 : Vérification du module SqlServer"
    try {
        $m = Ensure-Module -Name "SqlServer" -InstallHint "Install-Module -Name SqlServer -Scope AllUsers -Force"
        Write-Step "Module SqlServer v$($m.Version) [$($m.Action)]" "OK"
    } catch { throw $_.Exception.Message }

    # --- PRÉ-VOL 2 : Fichier .sql présent ---
    Write-Section "Pré-vol 2/4 : Vérification du fichier SQL source"
    if (-not (Test-Path $SqlScriptPath)) {
        throw "Fichier introuvable : $SqlScriptPath"
    }
    $sqlContent = Get-Content -Path $SqlScriptPath -Raw
    $sqlSize = (Get-Item $SqlScriptPath).Length
    Write-Step "Fichier trouvé : $SqlScriptPath ($sqlSize octets)" "OK"

    # --- PRÉ-VOL 3 : Connexion et rôle PRIMARY ---
    Write-Section "Pré-vol 3/4 : Vérification du rôle PRIMARY"
    $roleQuery = @"
SELECT ar.replica_server_name AS Replica, ars.role_desc AS Role
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AvailabilityGroupName'
"@
    $roles = Invoke-Sqlcmd -ServerInstance $PrimaryNode -Database master `
                           -Query $roleQuery -TrustServerCertificate -ErrorAction Stop

    $shortName = ($PrimaryNode -split '\.')[0]
    $targetRole = ($roles | Where-Object { $_.Replica -eq $shortName }).Role

    Write-Host "  Rôles actuels :" -ForegroundColor Cyan
    $roles | Format-Table Replica, Role -AutoSize

    if ($targetRole -ne "PRIMARY") {
        throw "$PrimaryNode est $targetRole, pas PRIMARY. Exécuter ce script sur le nœud PRIMARY."
    }
    Write-Step "$PrimaryNode est bien PRIMARY" "OK"

    # --- PRÉ-VOL 4 : msdb accessible ---
    Write-Section "Pré-vol 4/4 : Vérification de msdb"
    $msdbCheck = Invoke-Sqlcmd -ServerInstance $PrimaryNode -Database msdb `
                               -Query "SELECT DB_NAME() AS DbName" -TrustServerCertificate
    Write-Step "Base msdb accessible sur $PrimaryNode" "OK"

    # --- EXÉCUTION ---
    Write-Section "Exécution du script SQL"

    if ($WhatIfPreference) {
        Write-Step "Mode WhatIf : le script SQL ne sera PAS exécuté" "SKIP"
        Write-Host ""
        Write-Host "  --- Contenu du script SQL ---" -ForegroundColor DarkGray
        Write-Host $sqlContent -ForegroundColor DarkGray
        Write-Host "  --- Fin du contenu ---" -ForegroundColor DarkGray
    } else {
        if ($PSCmdlet.ShouldProcess($PrimaryNode, "Exécuter $SqlScriptPath")) {
            Write-Host "  Exécution de $SqlScriptPath sur $PrimaryNode..." -ForegroundColor Gray

            # Exécuter via Invoke-Sqlcmd en gardant les messages PRINT
            $output = Invoke-Sqlcmd -ServerInstance $PrimaryNode -Database msdb `
                                    -InputFile $SqlScriptPath `
                                    -TrustServerCertificate `
                                    -Verbose `
                                    -ErrorAction Stop

            if ($output) {
                Write-Host ""
                Write-Host "  Sortie du script SQL :" -ForegroundColor Cyan
                $output | Format-Table -AutoSize
            }

            Write-Step "Script SQL exécuté avec succès" "OK"
        }
    }

    # --- VÉRIFICATION POST-EXÉCUTION ---
    if (-not $WhatIfPreference) {
        Write-Section "Vérification post-exécution"

        $jobsQuery = @"
SELECT name AS JobName, enabled AS IsEnabled,
       CASE WHEN enabled = 1 THEN 'Oui' ELSE 'Non' END AS Actif
FROM msdb.dbo.sysjobs
WHERE name LIKE 'DBA - %'
ORDER BY name
"@
        $jobs = Invoke-Sqlcmd -ServerInstance $PrimaryNode -Database msdb `
                              -Query $jobsQuery -TrustServerCertificate

        Write-Host ""
        Write-Host "  Jobs créés sur $PrimaryNode :" -ForegroundColor Cyan
        $jobs | Format-Table JobName, Actif -AutoSize

        if ($jobs.Count -ge 2) {
            Write-Step "$($jobs.Count) job(s) de maintenance créé(s)" "OK"
        } else {
            Write-Step "Moins de 2 jobs trouvés - vérifier manuellement" "WARN"
        }
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime
    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Primary Node    : $PrimaryNode" -ForegroundColor Cyan
    Write-Host "  Script SQL      : $SqlScriptPath" -ForegroundColor Cyan
    Write-Host "  Erreurs         : $($script:Errors.Count)" -ForegroundColor $(if ($script:Errors.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Durée           : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ✅ Jobs de maintenance créés avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  📌 Prochaine étape : 7.2.1 (synchroniser les jobs sur SQLS02)" -ForegroundColor Yellow
    Write-Host ""

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  Message : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Ligne   : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}