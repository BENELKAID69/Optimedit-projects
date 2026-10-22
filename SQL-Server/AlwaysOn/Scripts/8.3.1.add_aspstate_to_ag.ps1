<#
    8.3.1.add_aspstate_to_ag.ps1
    Objet   : Passer ASPState en FULL, faire un backup et l'ajouter à l'AG
    Noeud   : SQLS01 (Primary) via le Listener
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SqlInstance = "SQL-AG-LSTNR.optimedit.eu",
    [string]$DatabaseName = "ASPState",
    [string]$AGName = "AG-OPTIMEDIT",
    [string]$BackupPath = "S:\SQL\Backup\ASPState_FULL.bak"
)

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  [SKIP] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  [ECHEC] $Message" -ForegroundColor Red }

Write-Step "Vérification de l'existence de la base"
$checkDb = Invoke-Sqlcmd -ServerInstance $SqlInstance -TrustServerCertificate -Query "SELECT name FROM sys.databases WHERE name = '$DatabaseName'" -ErrorAction SilentlyContinue
if (-not $checkDb) {
    Write-Fail "La base $DatabaseName n'existe pas. Exécutez 8.3.0 d'abord."
    exit 1
}
Write-Ok "Base $DatabaseName trouvée."

Write-Step "Vérification de l'appartenance à l'AG"
$checkAg = Invoke-Sqlcmd -ServerInstance $SqlInstance -TrustServerCertificate -Query "SELECT database_name FROM sys.availability_databases_cluster WHERE database_name = '$DatabaseName'" -ErrorAction SilentlyContinue
if ($checkAg) {
    Write-Warn "La base $DatabaseName est déjà dans l'AG $AGName. Rien à faire."
    exit 0
}

if ($PSCmdlet.ShouldProcess($DatabaseName, "Ajouter à l'AG $AGName")) {
    Write-Step "Passage en mode FULL et Sauvegarde"
    $sqlPrep = @"
ALTER DATABASE [$DatabaseName] SET RECOVERY FULL;
BACKUP DATABASE [$DatabaseName] TO DISK = '$BackupPath' WITH INIT, COMPRESSION;
"@
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -TrustServerCertificate -Query $sqlPrep -ErrorAction Stop
        Write-Ok "Mode FULL configuré et backup effectué dans $BackupPath."
    } catch {
        Write-Fail "Erreur lors de la préparation de la base : $($_.Exception.Message)"
        exit 1
    }

    Write-Step "Ajout à l'Availability Group $AGName"
    $sqlAdd = "ALTER AVAILABILITY GROUP [$AGName] ADD DATABASE [$DatabaseName];"
    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -TrustServerCertificate -Query $sqlAdd -ErrorAction Stop
        Write-Ok "Base $DatabaseName ajoutée à l'AG avec succès."
    } catch {
        Write-Fail "Erreur lors de l'ajout à l'AG : $($_.Exception.Message)"
        exit 1
    }
}

Write-Host "`n  [OK] Terminé." -ForegroundColor Green