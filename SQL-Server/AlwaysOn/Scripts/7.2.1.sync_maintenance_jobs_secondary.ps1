<#
.SYNOPSIS
    Synchronise les jobs SQL Agent de maintenance sur le nœud SECONDARY de l'AG.

.DESCRIPTION
    Wrapper PowerShell pour exécuter Scripts-T-SQL\7.2.1.sync_maintenance_jobs_secondary.sql
    sur le nœud SECONDARY de l'Availability Group AG-OPTIMEDIT.

    IMPORTANT : msdb n'est PAS répliquée par l'AG. Sans cette étape, plus aucun
    job ne s'exécuterait après une bascule vers SQLS02.

    Le script :
      1. Vérifie le module SqlServer
      2. Vérifie la présence du fichier .sql source
      3. Vérifie que le nœud cible est bien SECONDARY
      4. Vérifie que msdb est accessible
      5. Exécute le script SQL via Invoke-Sqlcmd
      6. Vérifie que les 2 jobs sont bien présents sur le nœud SECONDARY

.PARAMETER SecondaryNode
    Nœud SECONDARY de l'AG. Défaut : SQLS02.optimedit.eu

.PARAMETER AvailabilityGroupName
    Nom de l'AG. Défaut : AG-OPTIMEDIT

.PARAMETER SqlScriptPath
    Chemin du fichier .sql.
    Défaut : .\Scripts-T-SQL\7.2.1.sync_maintenance_jobs_secondary.sql

.PARAMETER TranscriptPath
    Chemin du log. Défaut : .\7.2.1.sync_maintenance_jobs_secondary.log

.EXAMPLE
    # Prévisualisation (aucune modification)
    .\7.2.1.sync_maintenance_jobs_secondary.ps1 -WhatIf

.EXAMPLE
    # Exécution réelle
    .\7.2.1.sync_maintenance_jobs_secondary.ps1

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : Poste d'administration (ou SQLS01/SQLS02)
    Prérequis :
        - Module SqlServer (Install-Module -Name SqlServer)
        - Fichier Scripts-T-SQL\7.2.1.sync_maintenance_jobs_secondary.sql présent
        - SQLS02 en rôle SECONDARY
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SecondaryNode = "SQLS02.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AvailabilityGroupName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SqlScriptPath = ".\Scripts-T-SQL\7.2.1.sync_maintenance_jobs_secondary.sql",

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\7.2.1.sync_maintenance_jobs_secondary.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()

try {
    Start-Transcript -Path $TranscriptPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de démarrer la transcription : $($_.Exception.Message)"
}

# ============================================================
# FONCTIONS AUXILIAIRES
# ============================================================

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
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "INFO"  { "Cyan" }
        "SKIP"  { "DarkGray" }
        default { "White" }
    }
    $prefix = switch ($Status) {
        "OK"    { "[OK]   " }
        "WARN"  { "[WARN] " }
        "ERROR" { "[ERR]  " }
        "INFO"  { "[INFO] " }
        "SKIP"  { "[SKIP] " }
        default { "[----] " }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

function Ensure-Module {
    <#
    .SYNOPSIS
        Vérifie la présence d'un module PowerShell, l'importe si nécessaire,
        ou lève une erreur claire avec la commande d'installation.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $false)] [string]$InstallHint = ""
    )

    $loaded = Get-Module -Name $Name -ErrorAction SilentlyContinue
    if ($loaded) {
        return [PSCustomObject]@{ Name = $Name; Version = $loaded.Version; Action = "Déjà chargé" }
    }

    $available = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue |
                 Sort-Object Version -Descending | Select-Object -First 1

    if (-not $available) {
        $msg = "Module '$Name' introuvable sur ce système."
        if ($InstallHint) { $msg += "`n  → Installation : $InstallHint" }
        throw $msg
    }

    try {
        Import-Module -Name $Name -ErrorAction Stop
        return [PSCustomObject]@{ Name = $Name; Version = $available.Version; Action = "Importé" }
    } catch {
        throw "Échec de l'import du module '$Name' : $($_.Exception.Message)"
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "7.2.1 - Synchronisation des jobs SQL Agent sur le SECONDARY"
    Write-Host " Secondary Node  : $SecondaryNode" -ForegroundColor Gray
    Write-Host " AG Name         : $AvailabilityGroupName" -ForegroundColor Gray
    Write-Host " SQL Script      : $SqlScriptPath" -ForegroundColor Gray
    Write-Host " Date            : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode            : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Log             : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Module SqlServer ---
    Write-Section "Pré-vol 1/4 : Vérification du module SqlServer"

    try {
        $sqlModule = Ensure-Module -Name "SqlServer" `
            -InstallHint "Install-Module -Name SqlServer -Scope AllUsers -Force"
        Write-Step "Module SqlServer v$($sqlModule.Version) [$($sqlModule.Action)]" "OK"
    } catch {
        throw $_.Exception.Message
    }

    # Vérification de la commande critique
    if (-not (Get-Command -Name "Invoke-Sqlcmd" -ErrorAction SilentlyContinue)) {
        throw "Commande requise introuvable : Invoke-Sqlcmd."
    }
    Write-Step "Commande disponible : Invoke-Sqlcmd" "OK"

    # --- PRÉ-VOL 2 : Fichier .sql présent ---
    Write-Section "Pré-vol 2/4 : Vérification du fichier SQL source"

    if (-not (Test-Path $SqlScriptPath)) {
        throw "Fichier introuvable : $SqlScriptPath`nVérifiez que le dossier .\Scripts-T-SQL\ contient bien le fichier attendu."
    }

    $sqlContent = Get-Content -Path $SqlScriptPath -Raw
    $sqlSize = (Get-Item $SqlScriptPath).Length
    Write-Step "Fichier trouvé : $SqlScriptPath ($sqlSize octets)" "OK"

    # --- PRÉ-VOL 3 : Rôle SECONDARY ---
    Write-Section "Pré-vol 3/4 : Vérification du rôle SECONDARY"

    $roleQuery = @"
SELECT ar.replica_server_name AS Replica, ars.role_desc AS Role
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AvailabilityGroupName'
"@

    $roles = Invoke-Sqlcmd -ServerInstance $SecondaryNode -Database master `
                           -Query $roleQuery -TrustServerCertificate -ErrorAction Stop

    $shortName = ($SecondaryNode -split '\.')[0]
    $targetRole = ($roles | Where-Object { $_.Replica -eq $shortName }).Role

    Write-Host "  Rôles actuels :" -ForegroundColor Cyan
    $roles | Format-Table Replica, Role -AutoSize

    if ($targetRole -ne "SECONDARY") {
        throw "$SecondaryNode est $targetRole, pas SECONDARY. Exécuter ce script sur le nœud SECONDARY."
    }
    Write-Step "$SecondaryNode est bien SECONDARY" "OK"

    # --- PRÉ-VOL 4 : msdb accessible ---
    Write-Section "Pré-vol 4/4 : Vérification de msdb"

    $null = Invoke-Sqlcmd -ServerInstance $SecondaryNode -Database msdb `
                          -Query "SELECT DB_NAME() AS DbName" -TrustServerCertificate
    Write-Step "Base msdb accessible sur $SecondaryNode" "OK"

    # --- EXÉCUTION ---
    Write-Section "Exécution du script SQL"

    if ($WhatIfPreference) {
        Write-Step "Mode WhatIf : le script SQL ne sera PAS exécuté" "SKIP"
        Write-Host ""
        Write-Host "  --- Contenu du script SQL ($SqlScriptPath) ---" -ForegroundColor DarkGray
        Write-Host $sqlContent -ForegroundColor DarkGray
        Write-Host "  --- Fin du contenu ---" -ForegroundColor DarkGray
    } else {
        if ($PSCmdlet.ShouldProcess($SecondaryNode, "Exécuter $SqlScriptPath")) {
            Write-Host "  Exécution de $SqlScriptPath sur $SecondaryNode..." -ForegroundColor Gray

            $output = Invoke-Sqlcmd -ServerInstance $SecondaryNode -Database msdb `
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

        $jobs = Invoke-Sqlcmd -ServerInstance $SecondaryNode -Database msdb `
                              -Query $jobsQuery -TrustServerCertificate

        Write-Host ""
        Write-Host "  Jobs présents sur $SecondaryNode :" -ForegroundColor Cyan
        $jobs | Format-Table JobName, Actif -AutoSize

        if ($jobs.Count -ge 2) {
            Write-Step "$($jobs.Count) job(s) de maintenance présent(s) sur $SecondaryNode" "OK"
        } else {
            Write-Step "Moins de 2 jobs trouvés - vérifier manuellement" "WARN"
            $script:Warnings += "Nombre de jobs inférieur à 2 sur $SecondaryNode"
        }

        # Vérification des schedules
        $schedulesQuery = @"
SELECT s.name AS ScheduleName, 
       CASE s.freq_type 
            WHEN 8 THEN 'Hebdomadaire' 
            ELSE 'Autre' 
       END AS FreqType,
       CASE s.freq_interval 
            WHEN 1 THEN 'Dimanche'
            WHEN 7 THEN 'Samedi'
            ELSE 'Autre'
       END AS JourSemaine
FROM msdb.dbo.sysschedules s
WHERE s.name IN (N'Chaque dimanche 02h00', N'Chaque samedi 01h00')
ORDER BY s.name
"@

        $schedules = Invoke-Sqlcmd -ServerInstance $SecondaryNode -Database msdb `
                                   -Query $schedulesQuery -TrustServerCertificate

        if ($schedules) {
            Write-Host ""
            Write-Host "  Schedules présents sur $SecondaryNode :" -ForegroundColor Cyan
            $schedules | Format-Table ScheduleName, FreqType, JourSemaine -AutoSize
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Secondary Node  : $SecondaryNode" -ForegroundColor Cyan
    Write-Host "  AG Name         : $AvailabilityGroupName" -ForegroundColor Cyan
    Write-Host "  SQL Script      : $SqlScriptPath" -ForegroundColor Cyan
    Write-Host "  Erreurs         : $($script:Errors.Count)" -ForegroundColor $(if ($script:Errors.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Durée           : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""

    if ($script:Warnings.Count -gt 0) {
        Write-Host "  Avertissements :" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        Write-Host ""
    }

    if ($script:Errors.Count -gt 0) {
        Write-Host "  Erreurs :" -ForegroundColor Red
        $script:Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host ""
        exit 1
    }

    if ($WhatIfPreference) {
        Write-Host "  ⏭  Mode WhatIf - aucune modification effectuée" -ForegroundColor Yellow
    } else {
        Write-Host "  ✅ Jobs synchronisés avec succès sur $SecondaryNode" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  📌 Prochaine étape : 7.3.0 (création des alertes SQL Server)" -ForegroundColor Yellow
    Write-Host ""

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  Message : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Ligne   : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host ""
    if ($_.ScriptStackTrace) {
        Write-Host "  Stack trace :" -ForegroundColor DarkRed
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }

    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}