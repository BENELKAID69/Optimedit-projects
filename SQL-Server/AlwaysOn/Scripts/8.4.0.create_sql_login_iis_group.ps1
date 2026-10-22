<#
    8.4.0.create_sql_login_iis_group.ps1
    Objet   : Créer le login GG_IIS_AppPools sur les 2 nœuds + droits dans les 14 bases
    Noeud   : Exécution depuis le poste d'admin
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PrimaryInstance   = "SQLS01.optimedit.eu",
    [string]$SecondaryInstance = "SQLS02.optimedit.eu",
    [string]$ListenerInstance  = "SQL-AG-LSTNR.optimedit.eu",
    [string]$SqlScriptPath     = ".\Scripts-T-SQL\8.4.0.create_sql_login_iis_group.sql"
)

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "  [ECHEC] $Message" -ForegroundColor Red }

# ============================================================
# ÉTAPE 1 : Création du Login Serveur sur SQLS01 (Primaire)
# ============================================================
Write-Step "1. Création du Login sur $PrimaryInstance"
$createLoginQuery = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'OPTIMEDIT\GG_IIS_AppPools')
BEGIN
    CREATE LOGIN [OPTIMEDIT\GG_IIS_AppPools] FROM WINDOWS;
    PRINT 'Login cree.';
END
ELSE PRINT 'Login deja existant.';
"@

if ($PSCmdlet.ShouldProcess($PrimaryInstance, "Créer le Login")) {
    Invoke-Sqlcmd -ServerInstance $PrimaryInstance -TrustServerCertificate -Query $createLoginQuery -Verbose | Out-Null
    Write-Ok "Login traité sur $PrimaryInstance."
}

# ============================================================
# ÉTAPE 2 : Création du Login Serveur sur SQLS02 (Secondaire)
# ============================================================
Write-Step "2. Création du Login sur $SecondaryInstance"
if ($PSCmdlet.ShouldProcess($SecondaryInstance, "Créer le Login")) {
    try {
        Invoke-Sqlcmd -ServerInstance $SecondaryInstance -TrustServerCertificate -Query $createLoginQuery -Verbose | Out-Null
        Write-Ok "Login traité sur $SecondaryInstance."
    } catch {
        Write-Fail "Erreur sur $SecondaryInstance : $($_.Exception.Message)"
    }
}

# ============================================================
# ÉTAPE 3 : Attribution des droits dans les 14 bases (via Listener)
# ============================================================
Write-Step "3. Attribution des droits dans les bases sur $ListenerInstance"
if (-not (Test-Path $SqlScriptPath)) {
    Write-Fail "Fichier introuvable : $SqlScriptPath"
    exit 1
}

if ($PSCmdlet.ShouldProcess($ListenerInstance, "Attribuer les droits dans les 14 bases")) {
    try {
        # On exécute le script SQL, mais on ignore les erreurs de "Login existe déjà"
        Invoke-Sqlcmd -ServerInstance $ListenerInstance -Database master `
                      -InputFile $SqlScriptPath `
                      -TrustServerCertificate -Verbose -ErrorAction Stop | Out-Null
        Write-Ok "Droits attribués dans les bases."
    } catch {
        Write-Fail "Erreur lors de l'exécution du script : $($_.Exception.Message)"
        exit 1
    }
}

Write-Host "`n  [OK] Traitement terminé. Le Login et les droits sont prêts sur les 2 nœuds." -ForegroundColor Green