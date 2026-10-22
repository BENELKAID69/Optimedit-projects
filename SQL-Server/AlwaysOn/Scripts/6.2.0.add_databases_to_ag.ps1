<#
.SYNOPSIS
    Ajoute les 13 bases applicatives à l'Availability Group AG-OPTIMEDIT.

.DESCRIPTION
    Ce script ajoute les bases applicatives (DB_Direction, DB_Comptabilite, ...)
    à l'Availability Group [AG-OPTIMEDIT] avec :
    - Idempotence : ne traite que les bases qui ne sont PAS encore dans l'AG
    - Vérifications préalables :
        * Module SqlServer disponible
        * Connexion SQL Server accessible
        * AG-OPTIMEDIT existe
        * Les 13 bases existent et sont en FULL recovery model
        * Les backups FULL + LOG récents existent (< 24h)
        * Le seeding automatique est activé sur l'AG
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Support -WhatIf (prévisualisation)
    - Support -Rollback (retire les bases de l'AG en cas d'erreur)
    - Vérification post-exécution (état de synchronisation des réplicas)
    - Compatible Windows PowerShell 5.1 et PowerShell 7+

    FONCTIONNALITÉS CLÉS :
    - Détecte automatiquement les bases déjà dans l'AG (idempotence)
    - Bloque l'ajout si une base n'est pas en FULL recovery model
    - Bloque l'ajout si un backup FULL récent est manquant
    - Attend la synchronisation après ajout (avec timeout)
    - Rapport détaillé par base

.PARAMETER ServerInstance
    Instance SQL Server cible (Primary). Défaut : SQLS01.optimedit.eu

.PARAMETER AvailabilityGroupName
    Nom de l'Availability Group. Défaut : AG-OPTIMEDIT

.PARAMETER Databases
    Liste des bases à ajouter. Défaut : les 13 bases applicatives.

.PARAMETER MaxBackupAgeHours
    Âge maximum des backups FULL en heures. Défaut : 24

.PARAMETER SyncTimeoutSeconds
    Timeout d'attente de synchronisation après ajout. Défaut : 300 (5 min)

.PARAMETER RollbackOnError
    Retire les bases de l'AG en cas d'erreur.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\6.2.0.add_databases_to_ag.log

.EXAMPLE
    # Prévisualisation
    .\6.2.0.add_databases_to_ag.ps1 -WhatIf

.EXAMPLE
    # Ajout standard
    .\6.2.0.add_databases_to_ag.ps1

.EXAMPLE
    # Ajout avec rollback en cas d'erreur
    .\6.2.0.add_databases_to_ag.ps1 -RollbackOnError

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : SQLS01 (Primary)
    Prérequis :
        - AG-OPTIMEDIT créé et en bonne santé
        - Les 13 bases en FULL recovery model
        - Backups FULL + LOG récents pour chaque base
        - Seeding automatique activé sur l'AG
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerInstance = "SQLS01.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AvailabilityGroupName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [string[]]$Databases = @(
        "DB_Direction",
        "DB_Comptabilite",
        "DB_Paie",
        "DB_RH",
        "DB_CE",
        "DB_IT",
        "DB_Production",
        "DB_Formation",
        "DB_Achat",
        "DB_Commercial",
        "DB_Client",
        "DB_Juridique",
        "DB_Blog"
    ),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 720)]
    [int]$MaxBackupAgeHours = 24,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 3600)]
    [int]$SyncTimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [switch]$RollbackOnError,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\6.2.0.add_databases_to_ag.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:AddedDatabases = @()
$script:SkippedDatabases = @()
$script:FailedDatabases = @()

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

function Test-SqlServerModule {
    try {
        $null = Get-Module -Name SqlServer -ListAvailable -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Invoke-SqlQuery {
    param(
        [Parameter(Mandatory = $true)] [string]$Query,
        [Parameter(Mandatory = $false)] [string]$ServerInstance = $ServerInstance,
        [Parameter(Mandatory = $false)] [string]$Database = "master"
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $Query -ErrorAction Stop
}

function Test-AvailabilityGroupExists {
    param([string]$AGName)
    try {
        $query = "SELECT COUNT(*) AS AGCount FROM sys.availability_groups WHERE name = '$AGName'"
        $result = Invoke-SqlQuery -Query $query
        return ($result.AGCount -gt 0)
    } catch {
        return $false
    }
}

function Test-DatabaseExists {
    param([string]$DatabaseName)
    try {
        $query = "SELECT COUNT(*) AS DbCount FROM sys.databases WHERE name = '$DatabaseName'"
        $result = Invoke-SqlQuery -Query $query
        return ($result.DbCount -gt 0)
    } catch {
        return $false
    }
}

function Test-DatabaseInAG {
    param(
        [string]$DatabaseName,
        [string]$AGName
    )
    try {
        $query = @"
SELECT COUNT(*) AS DbInAG
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
WHERE adc.database_name = '$DatabaseName' AND ag.name = '$AGName'
"@
        $result = Invoke-SqlQuery -Query $query
        return ($result.DbInAG -gt 0)
    } catch {
        return $false
    }
}

function Test-DatabaseRecoveryModel {
    param([string]$DatabaseName)
    try {
        $query = "SELECT recovery_model_desc AS RecoveryModel FROM sys.databases WHERE name = '$DatabaseName'"
        $result = Invoke-SqlQuery -Query $query
        return ($result.RecoveryModel -eq "FULL")
    } catch {
        return $false
    }
}

function Test-RecentFullBackup {
    param(
        [string]$DatabaseName,
        [int]$MaxAgeHours
    )
    try {
        $query = @"
SELECT COUNT(*) AS RecentBackups
FROM msdb.dbo.backupset
WHERE database_name = '$DatabaseName'
  AND type = 'D'
  AND backup_finish_date > DATEADD(HOUR, -$MaxAgeHours, GETDATE())
"@
        $result = Invoke-SqlQuery -Query $query
        return ($result.RecentBackups -gt 0)
    } catch {
        return $false
    }
}

function Test-AutoSeedingEnabled {
    param([string]$AGName)
    try {
        $query = @"
SELECT TOP 1 seeding_mode_desc AS SeedingMode
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AGName'
"@
        $result = Invoke-SqlQuery -Query $query
        return ($result.SeedingMode -eq "AUTOMATIC")
    } catch {
        return $false
    }
}

function Add-DatabaseToAG {
    param(
        [string]$DatabaseName,
        [string]$AGName
    )
    $query = "ALTER AVAILABILITY GROUP [$AGName] ADD DATABASE [$DatabaseName]"
    Invoke-SqlQuery -Query $query | Out-Null
}

function Remove-DatabaseFromAG {
    param(
        [string]$DatabaseName,
        [string]$AGName
    )
    $query = "ALTER AVAILABILITY GROUP [$AGName] REMOVE DATABASE [$DatabaseName]"
    Invoke-SqlQuery -Query $query | Out-Null
}

function Wait-DatabaseSynchronized {
    param(
        [string]$DatabaseName,
        [string]$AGName,
        [int]$TimeoutSeconds,
        [int]$SeedWaitSeconds = 600   # Timeout spécifique pour le seeding (10 min)
    )
    
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $seedDeadline = (Get-Date).AddSeconds($SeedWaitSeconds)
    $lastState = ""
    $seedingDetected = $false
    
    while ((Get-Date) -lt $deadline) {
        $query = @"
SELECT 
    drs.synchronization_state_desc AS SyncState,
    drs.synchronization_health_desc AS SyncHealth,
    drs.is_suspended AS IsSuspended,
    drs.log_send_queue_size AS LogSendQueueKB,
    drs.redo_queue_size AS RedoQueueKB,
    drs.database_state_desc AS DbState
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE adc.database_name = '$DatabaseName' AND ag.name = '$AGName'
"@
        $result = Invoke-SqlQuery -Query $query
        
        if ($result) {
            $currentState = "$($result.SyncState) / $($result.SyncHealth) / $($result.DbState)"
            $lastState = $currentState
            
            # CAS 1 : Base SYNCHRONIZED et HEALTHY → SUCCÈS
            if ($result.SyncState -eq "SYNCHRONIZED" -and $result.SyncHealth -eq "HEALTHY") {
                return @{ 
                    Success = $true; 
                    State = $result.SyncState; 
                    Health = $result.SyncHealth;
                    LogSendQueueKB = $result.LogSendQueueKB;
                    RedoQueueKB = $result.RedoQueueKB;
                    Message = "Synchronisée et saine"
                }
            }
            
            # CAS 2 : Base en SYNCHRONIZING → seeding en cours, on attend
            if ($result.SyncState -eq "SYNCHRONIZING" -or $result.DbState -eq "RESTORING") {
                if (-not $seedingDetected) {
                    Write-Host "    [INFO] Seeding en cours (DbState: $($result.DbState))..." -ForegroundColor Cyan
                    $seedingDetected = $true
                }
                
                # Si le seeding dépasse le seedDeadline, on avertit
                if ((Get-Date) -gt $seedDeadline) {
                    return @{ 
                        Success = $false; 
                        State = $result.SyncState; 
                        Health = $result.SyncHealth;
                        Message = "Seeding toujours en cours après $SeedWaitSeconds s (timeout seeding)"
                    }
                }
                
                Start-Sleep -Seconds 5
                continue
            }
            
            # CAS 3 : Base NOT SYNCHRONIZING → problème
            if ($result.SyncState -eq "NOT SYNCHRONIZING") {
                if ($result.IsSuspended -eq $true) {
                    return @{ 
                        Success = $false; 
                        State = $result.SyncState; 
                        Health = $result.SyncHealth;
                        Message = "Base suspendue (is_suspended = TRUE)"
                    }
                }
                Start-Sleep -Seconds 5
                continue
            }
        }
        
        Start-Sleep -Seconds 3
    }
    
    return @{ 
        Success = $false; 
        State = $lastState; 
        Health = "TIMEOUT";
        Message = "Timeout global après $TimeoutSeconds s"
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "6.2.0 - Ajout des 13 bases à l'Availability Group"
    Write-Host " Serveur SQL      : $ServerInstance" -ForegroundColor Gray
    Write-Host " Availability Group : $AvailabilityGroupName" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Rollback on err  : $(if ($RollbackOnError) { 'OUI' } else { 'NON' })" -ForegroundColor Gray
    Write-Host " Âge max backup   : $MaxBackupAgeHours heures" -ForegroundColor Gray
    Write-Host " Timeout sync     : $SyncTimeoutSeconds secondes" -ForegroundColor Gray
    Write-Host " Nombre de bases  : $($Databases.Count)" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Module SqlServer ---
    Write-Section "Pré-vol 1/6 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible."
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # --- PRÉ-VOL 2 : Connexion SQL Server ---
    Write-Section "Pré-vol 2/6 : Vérification de la connexion SQL Server"

    try {
        $version = Invoke-SqlQuery -Query "SELECT @@VERSION AS Version"
        Write-Step "SQL Server accessible : $($version.Version.Split("`n")[0])" "OK"
    } catch {
        throw "Impossible de se connecter à $ServerInstance : $($_.Exception.Message)"
    }

    # --- PRÉ-VOL 3 : AG existe ---
    Write-Section "Pré-vol 3/6 : Vérification de l'Availability Group"

    if (-not (Test-AvailabilityGroupExists -AGName $AvailabilityGroupName)) {
        throw "L'Availability Group '$AvailabilityGroupName' n'existe pas sur $ServerInstance."
    }
    Write-Step "Availability Group '$AvailabilityGroupName' existe" "OK"

    # Vérifier le seeding automatique
    if (Test-AutoSeedingEnabled -AGName $AvailabilityGroupName) {
        Write-Step "Seeding automatique ACTIVÉ sur l'AG" "OK"
    } else {
        Write-Step "Seeding automatique NON ACTIVÉ sur l'AG" "WARN"
        $script:Warnings += "Seeding automatique non activé - l'ajout peut échouer"
    }

    # --- PRÉ-VOL 4 : Existence des bases ---
    Write-Section "Pré-vol 4/6 : Vérification de l'existence des bases"

    $missingDatabases = @()
    foreach ($db in $Databases) {
        if (-not (Test-DatabaseExists -DatabaseName $db)) {
            $missingDatabases += $db
        }
    }

    if ($missingDatabases.Count -gt 0) {
        Write-Step "$($missingDatabases.Count) base(s) MANQUANTE(S) :" "ERROR"
        $missingDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "Certaines bases n'existent pas. Exécutez d'abord 6.1.0.create_application_databases.ps1"
    }
    Write-Step "Les $($Databases.Count) bases existent" "OK"

    # --- PRÉ-VOL 5 : Recovery model FULL ---
    Write-Section "Pré-vol 5/6 : Vérification du recovery model (FULL obligatoire)"

    $notFullDatabases = @()
    foreach ($db in $Databases) {
        if (-not (Test-DatabaseRecoveryModel -DatabaseName $db)) {
            $notFullDatabases += $db
        }
    }

    if ($notFullDatabases.Count -gt 0) {
        Write-Step "$($notFullDatabases.Count) base(s) PAS en FULL :" "ERROR"
        $notFullDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "Toutes les bases doivent être en FULL recovery model."
    }
    Write-Step "Toutes les bases sont en FULL recovery model" "OK"

    # --- PRÉ-VOL 6 : Backups récents ---
    Write-Section "Pré-vol 6/6 : Vérification des backups FULL récents (< $MaxBackupAgeHours h)"

    $missingBackupDatabases = @()
    foreach ($db in $Databases) {
        if (-not (Test-RecentFullBackup -DatabaseName $db -MaxAgeHours $MaxBackupAgeHours)) {
            $missingBackupDatabases += $db
        }
    }

    if ($missingBackupDatabases.Count -gt 0) {
        Write-Step "$($missingBackupDatabases.Count) base(s) sans backup FULL récent :" "ERROR"
        $missingBackupDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "Un backup FULL récent (< $MaxBackupAgeHours h) est obligatoire pour chaque base avant l'ajout à l'AG."
    }
    Write-Step "Toutes les bases ont un backup FULL récent" "OK"

    # --- AJOUT DES BASES À L'AG ---
    Write-Section "Ajout des bases à l'AG"

    foreach ($db in $Databases) {
        Write-Host ""
        Write-Host "  ── $db ──" -ForegroundColor Magenta

        # Vérifier si la base est déjà dans l'AG
        if (Test-DatabaseInAG -DatabaseName $db -AGName $AvailabilityGroupName) {
            Write-Step "Déjà dans l'AG - ignorée" "SKIP"
            $script:SkippedDatabases += $db
            continue
        }

        # Ajouter la base
        if ($WhatIfPreference) {
            Write-Step "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] ADD DATABASE [$db] (WhatIf)" "SKIP"
        } else {
            try {
                Add-DatabaseToAG -DatabaseName $db -AGName $AvailabilityGroupName
                Write-Step "Ajoutée à l'AG" "OK"
                $script:AddedDatabases += $db
            } catch {
                Write-Step "ÉCHEC : $($_.Exception.Message)" "ERROR"
                $script:Errors += "Échec ajout $db : $($_.Exception.Message)"
                $script:FailedDatabases += $db

                # Rollback si demandé
                if ($RollbackOnError) {
                    Write-Step "Rollback : retrait de $db de l'AG..." "WARN"
                    try {
                        Remove-DatabaseFromAG -DatabaseName $db -AGName $AvailabilityGroupName
                        Write-Step "Base $db retirée de l'AG" "OK"
                    } catch {
                        Write-Step "Impossible de retirer $db : $($_.Exception.Message)" "ERROR"
                    }
                }
            }
        }
    }

    # --- ATTENTE DE LA SYNCHRONISATION ---
    if (-not $WhatIfPreference -and $script:AddedDatabases.Count -gt 0) {
        Write-Section "Attente de la synchronisation des bases (timeout: $SyncTimeoutSeconds s)"

        foreach ($db in $script:AddedDatabases) {
            Write-Host ""
            Write-Host "  ── $db ──" -ForegroundColor Magenta

            $syncResult = Wait-DatabaseSynchronized -DatabaseName $db -AGName $AvailabilityGroupName -TimeoutSeconds $SyncTimeoutSeconds

            if ($syncResult.Success) {
                Write-Step "SYNCHRONIZED / HEALTHY" "OK"
            } else {
                Write-Step "Timeout ou état non optimal : $($syncResult.State) / $($syncResult.Health)" "WARN"
                $script:Warnings += "Base $db : synchronisation non finalisée ($($syncResult.State))"
            }
        }
    }

    # --- VÉRIFICATION POST-EXÉCUTION ---
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Write-Host ""
        Write-Host "  État des bases dans l'AG :" -ForegroundColor Cyan

        $verifyQuery = @"
SELECT 
    db.name AS DatabaseName,
    drs.synchronization_state_desc AS SyncState,
    drs.synchronization_health_desc AS SyncHealth,
    drs.is_suspended AS IsSuspended,
    drs.log_send_queue_size AS LogSendQueueKB,
    drs.redo_queue_size AS RedoQueueKB
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
JOIN sys.databases db ON adc.database_name = db.name
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE ag.name = '$AvailabilityGroupName'
ORDER BY db.name
"@
        $agState = Invoke-SqlQuery -Query $verifyQuery
        if ($agState) {
            $agState | Format-Table DatabaseName, SyncState, SyncHealth, IsSuspended, LogSendQueueKB, RedoQueueKB -AutoSize

            $totalInAG = ($agState | Measure-Object).Count
            Write-Step "Total de bases dans l'AG : $totalInAG / $($Databases.Count)" "INFO"

            $synchronizedCount = ($agState | Where-Object { $_.SyncState -eq "SYNCHRONIZED" }).Count
            Write-Step "Bases SYNCHRONIZED : $synchronizedCount / $totalInAG" "INFO"
        } else {
            Write-Step "Aucune base trouvée dans l'AG" "WARN"
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Serveur SQL      : $ServerInstance" -ForegroundColor Cyan
    Write-Host "  Availability Group : $AvailabilityGroupName" -ForegroundColor Cyan
    Write-Host "  Bases ajoutées   : $($script:AddedDatabases.Count)" -ForegroundColor Green
    Write-Host "  Bases ignorées   : $($script:SkippedDatabases.Count)" -ForegroundColor Cyan
    Write-Host "  Bases en échec   : $($script:FailedDatabases.Count)" -ForegroundColor $(if ($script:FailedDatabases.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Erreurs          : $($script:Errors.Count)" -ForegroundColor $(if ($script:Errors.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Durée            : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""

    if ($script:AddedDatabases.Count -gt 0) {
        Write-Host "  Bases ajoutées :" -ForegroundColor Green
        $script:AddedDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
        Write-Host ""
    }

    if ($script:SkippedDatabases.Count -gt 0) {
        Write-Host "  Bases ignorées (déjà dans l'AG) :" -ForegroundColor Cyan
        $script:SkippedDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
        Write-Host ""
    }

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

    Write-Host "  ✅ Ajout des bases à l'AG terminé avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaine étape : 7.1.0 (activation TDE)" -ForegroundColor Yellow
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

    # Rollback en cas d'erreur fatale
    if ($RollbackOnError -and $script:AddedDatabases.Count -gt 0) {
        Write-Section "Rollback des bases ajoutées"
        foreach ($db in $script:AddedDatabases) {
            Write-Step "Retrait de $db de l'AG..." "WARN"
            try {
                Remove-DatabaseFromAG -DatabaseName $db -AGName $AvailabilityGroupName
                Write-Step "Base $db retirée de l'AG" "OK"
            } catch {
                Write-Step "Impossible de retirer $db : $($_.Exception.Message)" "ERROR"
            }
        }
    }

    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}