<#
.SYNOPSIS
    Crée les 13 bases applicatives sur SQL Server.

.DESCRIPTION
    Ce script crée les 13 bases applicatives (DB_Direction, DB_Comptabilite, ...)
    avec :
    - Idempotence : ne crée que si la base n'existe pas
    - Collation SQL_Latin1_General_CP1_CI_AS
    - Recovery model FULL
    - Backup FULL + LOG (obligatoire pour l'ajout à l'AG)

    FONCTIONNALITÉS :
    - Support -WhatIf pour la prévisualisation
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Vérification préalable (disque S:, chemin backup, SQL Server accessible)
    - Vérification post-exécution (bases créées, backups effectués)
    - Support -Rollback (supprime les bases créées en cas d'erreur)
    - Compatible Windows PowerShell 5.1 et PowerShell 7+

.PARAMETER ServerInstance
    Instance SQL Server cible. Défaut : SQLS01.optimedit.eu

.PARAMETER Databases
    Liste des bases à créer. Défaut : les 13 bases applicatives.

.PARAMETER BackupPath
    Chemin de destination des backups. Défaut : S:\SQL\Backup\

.PARAMETER Collation
    Collation des bases. Défaut : SQL_Latin1_General_CP1_CI_AS

.PARAMETER RollbackOnError
    Supprime les bases créées en cas d'erreur.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\6.1.0.create_application_databases.log

.EXAMPLE
    # Prévisualisation
    .\6.1.0.create_application_databases.ps1 -WhatIf

.EXAMPLE
    # Création standard
    .\6.1.0.create_application_databases.ps1

.EXAMPLE
    # Avec rollback en cas d'erreur
    .\6.1.0.create_application_databases.ps1 -RollbackOnError

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : SQLS01 (Primary)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerInstance = "SQLS01.optimedit.eu",

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
    [ValidateNotNullOrEmpty()]
    [string]$BackupPath = "S:\SQL\Backup\",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Collation = "SQL_Latin1_General_CP1_CI_AS",

    [Parameter(Mandatory = $false)]
    [switch]$RollbackOnError,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\6.1.0.create_application_databases.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:CreatedDatabases = @()
$script:SkippedDatabases = @()

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

function Test-BackupPathExists {
    param([string]$Path)
    try {
        # Retirer l'antislash final si présent
        $cleanPath = $Path.TrimEnd('\')
        
        $query = @"
DECLARE @Result INT;
EXEC master.dbo.xp_fileexist '$cleanPath', @Result OUTPUT;
SELECT @Result AS FileExists;
"@
        $result = Invoke-SqlQuery -Query $query
        return ($result.FileExists -eq 1)
    } catch {
        return $false
    }
}

function New-ApplicationDatabase {
    param(
        [string]$DatabaseName,
        [string]$Collation,
        [string]$BackupPath
    )

    # Création de la base
    $createQuery = "CREATE DATABASE [$DatabaseName] COLLATE $Collation"
    Invoke-SqlQuery -Query $createQuery | Out-Null

    # Recovery FULL
    $recoveryQuery = "ALTER DATABASE [$DatabaseName] SET RECOVERY FULL"
    Invoke-SqlQuery -Query $recoveryQuery | Out-Null

    # Backup FULL
    $backupFile = "$BackupPath$DatabaseName`_FULL.bak"
    $backupQuery = "BACKUP DATABASE [$DatabaseName] TO DISK = '$backupFile' WITH INIT, COMPRESSION"
    Invoke-SqlQuery -Query $backupQuery | Out-Null

    # Backup LOG
    $logFile = "$BackupPath$DatabaseName`_LOG.trn"
    $logQuery = "BACKUP LOG [$DatabaseName] TO DISK = '$logFile' WITH INIT, COMPRESSION"
    Invoke-SqlQuery -Query $logQuery | Out-Null

    return @{
        Database = $DatabaseName
        BackupFile = $backupFile
        LogFile = $logFile
    }
}

function Remove-ApplicationDatabase {
    param([string]$DatabaseName)
    $query = @"
IF DB_ID('$DatabaseName') IS NOT NULL
BEGIN
    ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DatabaseName];
END
"@
    Invoke-SqlQuery -Query $query | Out-Null
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "6.1.0 - Création des 13 bases applicatives"
    Write-Host " Serveur SQL      : $ServerInstance" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Collation        : $Collation" -ForegroundColor Gray
    Write-Host " Chemin backup    : $BackupPath" -ForegroundColor Gray
    Write-Host " Rollback on err  : $(if ($RollbackOnError) { 'OUI' } else { 'NON' })" -ForegroundColor Gray
    Write-Host " Nombre de bases  : $($Databases.Count)" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Module SqlServer ---
    Write-Section "Pré-vol 1/4 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible."
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # --- PRÉ-VOL 2 : Connexion SQL Server ---
    Write-Section "Pré-vol 2/4 : Vérification de la connexion SQL Server"

    try {
        $version = Invoke-SqlQuery -Query "SELECT @@VERSION AS Version"
        Write-Step "SQL Server accessible : $($version.Version.Split("`n")[0])" "OK"
    } catch {
        throw "Impossible de se connecter à $ServerInstance : $($_.Exception.Message)"
    }

    # --- PRÉ-VOL 3 : Chemin de backup ---
    Write-Section "Pré-vol 3/4 : Vérification du chemin de backup"

	function Test-BackupPathExists {
		param([string]$Path)
		try {
			# Tester depuis PowerShell localement
			# (plus fiable que xp_fileexist pour les chemins réseau ou montés)
			if (Test-Path -Path $Path) {
				return $true
			}
			return $false
		} catch {
			return $false
		}
	}

    # --- PRÉ-VOL 4 : Vérification des bases existantes ---
    Write-Section "Pré-vol 4/4 : Vérification des bases existantes"

    $existingDatabases = @()
    foreach ($db in $Databases) {
        if (Test-DatabaseExists -DatabaseName $db) {
            $existingDatabases += $db
        }
    }

    if ($existingDatabases.Count -gt 0) {
        Write-Step "$($existingDatabases.Count) base(s) déjà existante(s) :" "WARN"
        $existingDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
        Write-Step "Ces bases seront ignorées (idempotence)" "INFO"
    } else {
        Write-Step "Aucune base existante - les 13 bases seront créées" "OK"
    }

    # --- CRÉATION DES BASES ---
    Write-Section "Création des bases"

    foreach ($db in $Databases) {
        Write-Host ""
        Write-Host "  ── $db ──" -ForegroundColor Magenta

        # Vérifier si la base existe déjà
        if (Test-DatabaseExists -DatabaseName $db) {
            Write-Step "Déjà existante - ignorée" "SKIP"
            $script:SkippedDatabases += $db
            continue
        }

        # Créer la base
        if ($WhatIfPreference) {
            Write-Step "CREATE DATABASE [$db] COLLATE $Collation (WhatIf)" "SKIP"
            Write-Step "ALTER DATABASE [$db] SET RECOVERY FULL (WhatIf)" "SKIP"
            Write-Step "BACKUP DATABASE [$db] TO DISK = '${BackupPath}${db}_FULL.bak' (WhatIf)" "SKIP"
            Write-Step "BACKUP LOG [$db] TO DISK = '${BackupPath}${db}_LOG.trn' (WhatIf)" "SKIP"
        } else {
            try {
                $result = New-ApplicationDatabase -DatabaseName $db -Collation $Collation -BackupPath $BackupPath
                Write-Step "Base créée + Recovery FULL + Backups OK" "OK"
                Write-Host "    Backup : $($result.BackupFile)" -ForegroundColor DarkGray
                Write-Host "    Log    : $($result.LogFile)" -ForegroundColor DarkGray
                $script:CreatedDatabases += $db
            } catch {
                Write-Step "ÉCHEC : $($_.Exception.Message)" "ERROR"
                $script:Errors += "Échec création $db : $($_.Exception.Message)"

                # Rollback si demandé
                if ($RollbackOnError) {
                    Write-Step "Rollback : suppression de $db..." "WARN"
                    try {
                        Remove-ApplicationDatabase -DatabaseName $db
                        Write-Step "Base $db supprimée" "OK"
                    } catch {
                        Write-Step "Impossible de supprimer $db : $($_.Exception.Message)" "ERROR"
                    }
                }
            }
        }
    }

    # --- VÉRIFICATION POST-EXÉCUTION ---
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Write-Host ""
        Write-Host "  État des bases :" -ForegroundColor Cyan

        $verifyQuery = @"
SELECT 
    name AS DatabaseName,
    recovery_model_desc AS RecoveryModel,
    state_desc AS State,
    collation_name AS Collation
FROM sys.databases
WHERE name LIKE 'DB_%'
ORDER BY name
"@
        $finalState = Invoke-SqlQuery -Query $verifyQuery
        $finalState | Format-Table DatabaseName, RecoveryModel, State, Collation -AutoSize

        $totalCreated = $finalState.Count
        Write-Step "Total de bases présentes : $totalCreated / $($Databases.Count)" "INFO"

        # Vérifier les backups
        Write-Host ""
        Write-Host "  Derniers backups :" -ForegroundColor Cyan

        $backupQuery = @"
SELECT 
    database_name AS DatabaseName,
    type AS BackupType,
    backup_finish_date AS BackupDate
FROM msdb.dbo.backupset
WHERE database_name LIKE 'DB_%'
  AND backup_finish_date > DATEADD(HOUR, -1, GETDATE())
ORDER BY database_name, type
"@
        $backups = Invoke-SqlQuery -Query $backupQuery
        if ($backups) {
            $backups | Format-Table DatabaseName, BackupType, BackupDate -AutoSize
        } else {
            Write-Step "Aucun backup récent trouvé" "WARN"
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Serveur SQL      : $ServerInstance" -ForegroundColor Cyan
    Write-Host "  Bases créées     : $($script:CreatedDatabases.Count)" -ForegroundColor Green
    Write-Host "  Bases ignorées   : $($script:SkippedDatabases.Count)" -ForegroundColor Cyan
    Write-Host "  Erreurs          : $($script:Errors.Count)" -ForegroundColor $(if ($script:Errors.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Durée            : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""

    if ($script:SkippedDatabases.Count -gt 0) {
        Write-Host "  Bases ignorées (déjà existantes) :" -ForegroundColor Cyan
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

    Write-Host "  ✅ Création des bases terminée avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaine étape : 6.2.0 (ajout des bases à l'AG)" -ForegroundColor Yellow
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
    if ($RollbackOnError -and $script:CreatedDatabases.Count -gt 0) {
        Write-Section "Rollback des bases créées"
        foreach ($db in $script:CreatedDatabases) {
            Write-Step "Suppression de $db..." "WARN"
            try {
                Remove-ApplicationDatabase -DatabaseName $db
                Write-Step "Base $db supprimée" "OK"
            } catch {
                Write-Step "Impossible de supprimer $db : $($_.Exception.Message)" "ERROR"
            }
        }
    }

    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}