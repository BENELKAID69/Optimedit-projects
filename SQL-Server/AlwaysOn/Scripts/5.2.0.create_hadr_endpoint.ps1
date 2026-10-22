<#
.SYNOPSIS
    Crée l'endpoint HADR pour Always On Availability Groups.

.DESCRIPTION
    Ce script :
    1. Crée les logins SQL Server pour les comptes de service AD (si absents)
    2. Crée l'endpoint HADR (Hadr_endpoint) sur le nœud SQL Server local
    3. Accorde GRANT CONNECT au compte de service
    4. Vérifie le résultat

    FONCTIONNALITÉS :
    - Création automatique des logins SVC_SQL_Engine et SVC_SQL_Agent
    - Ajout des logins au rôle sysadmin (requis pour Always On)
    - Détection automatique de l'instance SQL Server
    - Idempotence : ne crée que ce qui manque
    - Vérification du port 5022
    - Support -WhatIf pour la prévisualisation
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript

.PARAMETER Port
    Port TCP de l'endpoint. Défaut : 5022

.PARAMETER ServiceAccount
    Compte de service SQL Server à autoriser.
    Défaut : optimedit\SVC_SQL_Engine

.PARAMETER AgentAccount
    Compte de service SQL Agent à créer (login).
    Défaut : optimedit\SVC_SQL_Agent

.PARAMETER SkipLoginCreation
    Ignore la création des logins.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\5.2.0.create_hadr_endpoint.log

.EXAMPLE
    .\5.2.0.create_hadr_endpoint.ps1 -WhatIf
    .\5.2.0.create_hadr_endpoint.ps1

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 2.1
    Nœud    : SQLS01 + SQLS02 (exécuter sur chaque nœud)

    ===========================================================================
    ⚠️  PRÉREQUIS :
    ===========================================================================
    1. Always On activé (IsHadrEnabled = 1) — script 5.1.0 exécuté
    2. Service MSSQLSERVER en Running
    3. Comptes AD SVC_SQL_Engine et SVC_SQL_Agent existants
    4. Port 5022 libre sur le nœud

    ===========================================================================
    📝  CORRECTIONS v2.1 :
    ===========================================================================
    - Vérification des logins ignorée en mode WhatIf
    - Requête SQL corrigée : sys.tcp_endpoints au lieu de sys.endpoints.port
    - Message d'erreur explicite si la vérification échoue après création
    ===========================================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1024, 65535)]
    [int]$Port = 5022,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceAccount = "optimedit\SVC_SQL_Engine",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AgentAccount = "optimedit\SVC_SQL_Agent",

    [Parameter(Mandatory = $false)]
    [switch]$SkipLoginCreation,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\5.2.0.create_hadr_endpoint.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:Fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem).Domain)"

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

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
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
        [Parameter(Mandatory = $false)] [string]$Database = "master"
    )
    return Invoke-Sqlcmd -ServerInstance $script:Fqdn -Database $Database -Query $Query -ErrorAction Stop
}

function Get-SqlAlwaysOnStatus {
    try {
        $result = Invoke-SqlQuery -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled"
        return [PSCustomObject]@{
            Found = $true
            Value = [int]$result.IsHadrEnabled
            Error = $null
        }
    } catch {
        return [PSCustomObject]@{
            Found = $false
            Value = $null
            Error = $_.Exception.Message
        }
    }
}

function Test-LoginExists {
    param([string]$LoginName)
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT COUNT(*) AS LoginCount
FROM sys.server_principals
WHERE name = '$LoginName'
"@
        return ($result.LoginCount -gt 0)
    } catch {
        throw "Impossible de vérifier le login '$LoginName' : $($_.Exception.Message)"
    }
}

function Test-LoginInSysadmin {
    param([string]$LoginName)
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT COUNT(*) AS MemberCount
FROM sys.server_role_members rm
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
WHERE r.name = 'sysadmin' AND m.name = '$LoginName'
"@
        return ($result.MemberCount -gt 0)
    } catch {
        return $false
    }
}

function New-SqlLogin {
    param(
        [string]$LoginName,
        [switch]$AddToSysadmin
    )

    if (Test-LoginExists -LoginName $LoginName) {
        Write-Step "Login '$LoginName' existe déjà" "OK"

        if ($AddToSysadmin) {
            if (Test-LoginInSysadmin -LoginName $LoginName) {
                Write-Step "Login '$LoginName' déjà dans sysadmin" "OK"
            } else {
                if ($WhatIfPreference) {
                    Write-Step "Ajout de '$LoginName' à sysadmin (WhatIf)" "SKIP"
                } else {
                    $addQuery = "ALTER SERVER ROLE sysadmin ADD MEMBER [$LoginName];"
                    Invoke-SqlQuery -Query $addQuery | Out-Null
                    Write-Step "Login '$LoginName' ajouté à sysadmin" "OK"
                }
            }
        }
        return $true
    }

    # Login n'existe pas : créer
    if ($WhatIfPreference) {
        Write-Step "CREATE LOGIN [$LoginName] FROM WINDOWS (WhatIf)" "SKIP"
        if ($AddToSysadmin) {
            Write-Step "ALTER SERVER ROLE sysadmin ADD MEMBER [$LoginName] (WhatIf)" "SKIP"
        }
        return $true
    }

    try {
        $createQuery = "CREATE LOGIN [$LoginName] FROM WINDOWS;"
        Invoke-SqlQuery -Query $createQuery | Out-Null
        Write-Step "Login '$LoginName' créé" "OK"

        if ($AddToSysadmin) {
            $addQuery = "ALTER SERVER ROLE sysadmin ADD MEMBER [$LoginName];"
            Invoke-SqlQuery -Query $addQuery | Out-Null
            Write-Step "Login '$LoginName' ajouté à sysadmin" "OK"
        }

        return $true
    } catch {
        Write-Step "Échec de création du login '$LoginName' : $($_.Exception.Message)" "ERROR"
        $script:Errors += "Échec création login '$LoginName' : $($_.Exception.Message)"
        return $false
    }
}

function Test-EndpointExists {
    param([string]$EndpointName = "Hadr_endpoint")
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT COUNT(*) AS EndpointCount
FROM sys.endpoints
WHERE name = '$EndpointName'
"@
        return ($result.EndpointCount -gt 0)
    } catch {
        throw "Impossible de vérifier l'existence de l'endpoint : $($_.Exception.Message)"
    }
}

function Get-EndpointInfo {
    <#
    .SYNOPSIS
        Récupère les informations d'un endpoint (avec correction v2.1).
    .DESCRIPTION
        Le port est dans sys.tcp_endpoints, pas dans sys.endpoints.
    #>
    param([string]$EndpointName = "Hadr_endpoint")
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT 
    e.name AS EndpointName,
    e.state_desc AS State,
    e.type_desc AS Type,
    e.is_admin_endpoint AS IsAdmin,
    t.port AS Port
FROM sys.endpoints e
LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id
WHERE e.name = '$EndpointName'
"@
        return $result
    } catch {
        return $null
    }
}

function Test-PortAvailable {
    param([int]$PortNumber)
    try {
        $connections = Get-NetTCPConnection -LocalPort $PortNumber -ErrorAction SilentlyContinue
        return ($null -eq $connections -or $connections.Count -eq 0)
    } catch {
        return $true
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.2.0 - Création de l'endpoint HADR ($env:COMPUTERNAME) - v2.1"
    Write-Host " Serveur          : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " FQDN             : $script:Fqdn" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " PowerShell       : $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Port endpoint    : $Port" -ForegroundColor Gray
    Write-Host " Compte Engine    : $ServiceAccount" -ForegroundColor Gray
    Write-Host " Compte Agent     : $AgentAccount" -ForegroundColor Gray
    Write-Host " Créer logins     : $(if ($SkipLoginCreation) { 'NON (skip)' } else { 'OUI' })" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --------------------------------------------------------
    # PRÉ-VOL 1 : Privilèges administrateur
    # --------------------------------------------------------
    Write-Section "Pré-vol 1/4 : Vérification des privilèges"

    if (-not (Test-IsAdministrator)) {
        throw "Ce script doit être exécuté en tant qu'administrateur."
    }
    Write-Step "Privilèges administrateur confirmés" "OK"

    # --------------------------------------------------------
    # PRÉ-VOL 2 : Services SQL Server
    # --------------------------------------------------------
    Write-Section "Pré-vol 2/4 : Vérification des services SQL Server"

    $sqlService = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if (-not $sqlService) {
        throw "Le service MSSQLSERVER n'existe pas."
    }

    if ($sqlService.Status -ne "Running") {
        throw "Le service MSSQLSERVER n'est pas démarré (statut : $($sqlService.Status))."
    }
    Write-Step "MSSQLSERVER : Running" "OK"

    # --------------------------------------------------------
    # PRÉ-VOL 3 : Module SqlServer + Always On activé
    # --------------------------------------------------------
    Write-Section "Pré-vol 3/4 : Vérification du module SqlServer et d'Always On"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible. Exécutez d'abord 5.1.0."
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    $hadrStatus = Get-SqlAlwaysOnStatus
    if (-not $hadrStatus.Found) {
        throw "Impossible de vérifier IsHadrEnabled : $($hadrStatus.Error)"
    }
    if ($hadrStatus.Value -ne 1) {
        throw "Always On n'est PAS activé (IsHadrEnabled = $($hadrStatus.Value)). Exécutez d'abord 5.1.0."
    }
    Write-Step "Always On activé (IsHadrEnabled = 1)" "OK"

    # --------------------------------------------------------
    # PRÉ-VOL 4 : Port
    # --------------------------------------------------------
    Write-Section "Pré-vol 4/4 : Vérification du port $Port"

    if (Test-PortAvailable -PortNumber $Port) {
        Write-Step "Port $Port disponible" "OK"
    } else {
        if (Test-EndpointExists -EndpointName "Hadr_endpoint") {
            Write-Step "Port $Port utilisé par l'endpoint Hadr_endpoint existant" "INFO"
        } else {
            Write-Step "Port $Port déjà utilisé par un autre service" "WARN"
            $script:Warnings += "Port $Port potentiellement occupé"
        }
    }

    # --------------------------------------------------------
    # CRÉATION DES LOGINS SQL SERVER
    # --------------------------------------------------------
    if (-not $SkipLoginCreation) {
        Write-Section "Création des logins SQL Server"

        Write-Host ""
        Write-Host "  Création des logins pour les comptes de service AD..." -ForegroundColor Cyan
        Write-Host ""

        # Login SVC_SQL_Engine
        Write-Step "Traitement du login '$ServiceAccount'..." "INFO"
        New-SqlLogin -LoginName $ServiceAccount -AddToSysadmin | Out-Null

        # Login SVC_SQL_Agent
        Write-Step "Traitement du login '$AgentAccount'..." "INFO"
        New-SqlLogin -LoginName $AgentAccount -AddToSysadmin | Out-Null

        # Vérification post-création (UNIQUEMENT en mode réel)
        if (-not $WhatIfPreference) {
            Write-Host ""
            Write-Step "Vérification des logins créés..." "INFO"

            foreach ($login in @($ServiceAccount, $AgentAccount)) {
                if (Test-LoginExists -LoginName $login) {
                    $inSysadmin = Test-LoginInSysadmin -LoginName $login
                    $status = if ($inSysadmin) { "présent (sysadmin)" } else { "présent" }
                    Write-Step "  $login : $status" "OK"
                } else {
                    Write-Step "  $login : ABSENT" "ERROR"
                    $script:Errors += "Login '$login' absent après création"
                }
            }
        } else {
            Write-Host ""
            Write-Step "Vérification des logins ignorée (WhatIf)" "SKIP"
        }
    } else {
        Write-Section "Création des logins SQL Server"
        Write-Step "Création des logins ignorée (-SkipLoginCreation)" "SKIP"

        # Vérifier quand même que le login existe
        if (-not $WhatIfPreference) {
            if (-not (Test-LoginExists -LoginName $ServiceAccount)) {
                Write-Step "ATTENTION : '$ServiceAccount' n'existe pas - GRANT CONNECT échouera" "WARN"
                $script:Warnings += "Login '$ServiceAccount' absent"
            }
        }
    }

    # --------------------------------------------------------
    # VÉRIFICATION DE L'ÉTAT ACTUEL DE L'ENDPOINT
    # --------------------------------------------------------
    Write-Section "Vérification de l'existence de l'endpoint HADR"

    $endpointExists = Test-EndpointExists -EndpointName "Hadr_endpoint"

    if ($endpointExists) {
        Write-Step "L'endpoint 'Hadr_endpoint' existe déjà" "OK"
        $endpointInfo = Get-EndpointInfo -EndpointName "Hadr_endpoint"

        Write-Host ""
        Write-Host "  Détails de l'endpoint existant :" -ForegroundColor Cyan
        Write-Host "    Nom       : $($endpointInfo.EndpointName)" -ForegroundColor Gray
        Write-Host "    État      : $($endpointInfo.State)" -ForegroundColor Gray
        Write-Host "    Port      : $($endpointInfo.Port)" -ForegroundColor Gray
        Write-Host "    Type      : $($endpointInfo.Type)" -ForegroundColor Gray
        Write-Host ""

        if ($endpointInfo.State -eq "STARTED") {
            Write-Step "L'endpoint est démarré - aucune action nécessaire" "OK"
        } else {
            Write-Step "L'endpoint existe mais n'est pas démarré - démarrage..." "WARN"
            if (-not $WhatIfPreference) {
                $startQuery = "ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;"
                Invoke-SqlQuery -Query $startQuery | Out-Null
                Write-Step "Endpoint démarré" "OK"
            } else {
                Write-Step "Démarrage de l'endpoint (WhatIf)" "SKIP"
            }
        }

        Write-Section "Résumé"
        Write-Host "  Endpoint 'Hadr_endpoint' déjà présent sur $env:COMPUTERNAME" -ForegroundColor Green
        Write-Host "  Aucune action nécessaire." -ForegroundColor Gray
        return
    }

    Write-Step "L'endpoint 'Hadr_endpoint' n'existe pas - création nécessaire" "INFO"

    # --------------------------------------------------------
    # CRÉATION DE L'ENDPOINT
    # --------------------------------------------------------
    Write-Section "Création de l'endpoint HADR"

    $createEndpointQuery = @"
CREATE ENDPOINT [Hadr_endpoint]
STATE = STARTED
AS TCP (LISTENER_PORT = $Port)
FOR DATABASE_MIRRORING (
    ROLE = ALL,
    AUTHENTICATION = WINDOWS NEGOTIATE,
    ENCRYPTION = REQUIRED ALGORITHM AES
);
"@

    $grantConnectQuery = @"
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$ServiceAccount];
"@

    if ($WhatIfPreference) {
        Write-Step "CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED AS TCP (LISTENER_PORT = $Port) ... (WhatIf)" "SKIP"
        Write-Step "GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$ServiceAccount] (WhatIf)" "SKIP"
    } else {
        # Création de l'endpoint
        Write-Step "Création de l'endpoint sur le port $Port..." "INFO"
        try {
            Invoke-SqlQuery -Query $createEndpointQuery | Out-Null
            Write-Step "Endpoint 'Hadr_endpoint' créé avec succès" "OK"
        } catch {
            throw "Échec de création de l'endpoint : $($_.Exception.Message)"
        }

        # Attribution des droits
        Write-Step "Attribution de GRANT CONNECT à '$ServiceAccount'..." "INFO"
        try {
            Invoke-SqlQuery -Query $grantConnectQuery | Out-Null
            Write-Step "GRANT CONNECT accordé" "OK"
        } catch {
            Write-Step "Échec de GRANT CONNECT : $($_.Exception.Message)" "ERROR"
            $script:Errors += "Échec GRANT CONNECT : $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # VÉRIFICATION POST-EXÉCUTION
    # --------------------------------------------------------
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Start-Sleep -Seconds 2

        $finalEndpoint = Get-EndpointInfo -EndpointName "Hadr_endpoint"

        if ($finalEndpoint) {
            Write-Step "Endpoint 'Hadr_endpoint' existe" "OK"
            Write-Step "  État : $($finalEndpoint.State)" "INFO"
            Write-Step "  Port : $($finalEndpoint.Port)" "INFO"
            Write-Step "  Type : $($finalEndpoint.Type)" "INFO"

            if ($finalEndpoint.State -eq "STARTED" -and $finalEndpoint.Port -eq $Port) {
                Write-Step "Endpoint créé et démarré sur le port $Port" "OK"
            } else {
                Write-Step "Endpoint existe mais état/port non conformes" "WARN"
                $script:Warnings += "État ou port de l'endpoint non conformes"
            }
        } else {
            Write-Step "Endpoint NON trouvé après création" "ERROR"
            $script:Errors += "Endpoint non trouvé après création"
        }

        # Vérifier les permissions CONNECT
        try {
            $permCheck = Invoke-SqlQuery -Query @"
SELECT 
    p.name AS PrincipalName,
    pe.permission_name AS Permission,
    pe.state_desc AS State
FROM sys.server_permissions pe
JOIN sys.server_principals p ON pe.grantee_principal_id = p.principal_id
WHERE pe.class_desc = 'ENDPOINT'
  AND p.name = '$ServiceAccount'
"@

            if ($permCheck) {
                Write-Step "Permissions CONNECT confirmées pour '$ServiceAccount'" "OK"
            } else {
                Write-Step "Permissions CONNECT non trouvées pour '$ServiceAccount'" "WARN"
                $script:Warnings += "Permissions CONNECT non confirmées"
            }
        } catch {
            Write-Step "Vérification des permissions impossible : $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --------------------------------------------------------
    # RÉSUMÉ
    # --------------------------------------------------------
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"

    Write-Host ""
    Write-Host "  Serveur          : $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "  Endpoint         : Hadr_endpoint" -ForegroundColor Cyan
    Write-Host "  Port             : $Port" -ForegroundColor Cyan
    Write-Host "  Compte autorisé  : $ServiceAccount" -ForegroundColor Cyan
    Write-Host "  Durée            : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
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

    Write-Host "  ✅ Endpoint HADR créé avec succès sur $env:COMPUTERNAME" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaine étape :" -ForegroundColor Yellow
    Write-Host "    1. Exécuter ce script sur l'autre nœud (5.2)" -ForegroundColor Gray
    Write-Host "    2. Puis passer à la création de l'AG (5.3)" -ForegroundColor Gray
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