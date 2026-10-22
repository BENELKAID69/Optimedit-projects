<#
    8.3.0.create_aspstate_database.ps1
    Objet   : Créer la base de sessions ASPState via aspnet_regsql
    Noeud   : SQLS01 (Primary) - se connecte au Listener de l'AG
    Note    : Utilise -sstype p, -sstype p utilise bien les tables persistantes dans la base ASPState et non TempDB.
              car TempDB n'est pas répliquée par l'Availability Group.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SqlInstance    = "SQL-AG-LSTNR.optimedit.eu",
    [string]$AspnetRegSqlPath = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\aspnet_regsql.exe",
    [string]$DatabaseName   = "ASPState"
)

# ============================================================
# FONCTIONS UTILITAIRES
# ============================================================
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [SKIP] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [ECHEC] $Message" -ForegroundColor Red
}

# ============================================================
# ÉTAPE 1 — Vérification du module SqlServer
# ============================================================
Write-Step "1. Vérification du module SqlServer"

if (-not (Get-Module -Name SqlServer -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Fail "Module SqlServer introuvable. Exécutez : Install-Module -Name SqlServer -Scope AllUsers -Force"
    exit 1
}
if (-not (Get-Module -Name SqlServer -ErrorAction SilentlyContinue)) {
    Import-Module SqlServer -ErrorAction Stop
}
Write-Ok "Module SqlServer chargé."

# ============================================================
# ÉTAPE 2 — Vérification de l'exécutable aspnet_regsql.exe
# ============================================================
Write-Step "2. Vérification de l'exécutable aspnet_regsql.exe"

if (-not (Test-Path $AspnetRegSqlPath)) {
    Write-Fail "Exécutable introuvable : $AspnetRegSqlPath"
    Write-Host "  → Vérifiez que le .NET Framework 4.x est installé." -ForegroundColor Yellow
    exit 1
}
Write-Ok "Exécutable trouvé : $AspnetRegSqlPath"

# ============================================================
# ÉTAPE 3 — Vérification de l'état de l'AG (doit être PRIMARY)
# ============================================================
Write-Step "3. Vérification de l'état de l'Availability Group"

try {
    $roles = Invoke-Sqlcmd -ServerInstance $SqlInstance -TrustServerCertificate -Query @"
SELECT ar.replica_server_name, ars.role_desc 
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
"@ -ErrorAction Stop

    $localNode = $env:COMPUTERNAME
    $localRole = ($roles | Where-Object { $_.replica_server_name -eq $localNode }).role_desc
	
	#Vérification du rôle PRIMARY : elle s'assure qu'on l'exécute depuis le bon nœud.
    if ($localRole -ne "PRIMARY") {
        Write-Fail "Le nœud actuel ($localNode) est $localRole. Exécutez ce script sur le nœud PRIMARY."
        exit 1
    }
    Write-Ok "Le nœud $localNode est bien PRIMARY."
} catch {
    Write-Fail "Impossible de vérifier l'état de l'AG. Le Listener répond-il ? Erreur : $($_.Exception.Message)"
    exit 1
}

# ============================================================
# ÉTAPE 4 — Vérification si la base existe déjà
# ============================================================
Write-Step "4. Vérification de l'existence de la base $DatabaseName"

$dbCheckQuery = "SELECT name FROM sys.databases WHERE name = '$DatabaseName'"
$dbExists = Invoke-Sqlcmd -ServerInstance $SqlInstance -TrustServerCertificate -Query $dbCheckQuery -ErrorAction SilentlyContinue

if ($dbExists) {
    Write-Warn "La base $DatabaseName existe déjà sur $SqlInstance (ignoré)."
} else {
    Write-Host "  La base n'existe pas. Création en cours..." -ForegroundColor Gray

    if ($PSCmdlet.ShouldProcess($SqlInstance, "Créer la base ASPState avec -sstype p (persistant)")) {
        try {
            # Exécution de aspnet_regsql avec sstype p (tables persistantes pour l'AG)
            # Note : aspnet_regsql affiche parfois des messages d'avertissement normaux sur stderr.
            $output = & $AspnetRegSqlPath -S $SqlInstance -E -ssadd -sstype p 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                throw "aspnet_regsql.exe a échoué avec le code $LASTEXITCODE.`n$output"
            }
            
            Write-Ok "Base $DatabaseName créée avec succès sur $SqlInstance."
        } catch {
            Write-Fail "Échec de la création : $($_.Exception.Message)"
            exit 1
        }
    }
}

# ============================================================
# ÉTAPE 5 — Vérification finale
# ============================================================
Write-Step "5. Vérification finale"

if ($WhatIfPreference) {
    Write-Host "  [WhatIf] Vérification finale ignorée." -ForegroundColor Yellow
} else {
    try {
        $finalCheck = Invoke-Sqlcmd -ServerInstance $SqlInstance -TrustServerCertificate -Query $dbCheckQuery -ErrorAction Stop
        if ($finalCheck) {
            Write-Ok "La base $DatabaseName est présente sur le Listener."
        } else {
            Write-Fail "La base $DatabaseName est introuvable après exécution."
            exit 1
        }
    } catch {
        Write-Fail "Erreur lors de la vérification finale : $($_.Exception.Message)"
        exit 1
    }
}

Write-Host ""
Write-Host "  [OK] Traitement terminé." -ForegroundColor Green
Write-Host ""