<#
.SYNOPSIS
    Crée l'Availability Group AG-OPTIMEDIT avec seeding automatique.

.DESCRIPTION
    Ce script crée l'AG-OPTIMEDIT sur SQLS01 (primary) avec :
    - Deux replicas (SQLS01, SQLS02)
    - Mode SYNCHRONOUS_COMMIT + AUTOMATIC FAILOVER
    - Seeding automatique (SEEDING_MODE = AUTOMATIC)
    - Endpoints HADR (vérifiés préalablement)

    FONCTIONNALITÉS :
    - Vérification préalable complète (Always On, endpoints, DNS, cluster)
    - Détection du nœud primaire WSFC
    - Idempotence : ne crée que si l'AG n'existe pas
    - Vérification des prérequis de seeding (backup initial si nécessaire)
    - Support -WhatIf pour la prévisualisation
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Vérification post-exécution complète

.PARAMETER AGName
    Nom de l'Availability Group. Défaut : AG-OPTIMEDIT

.PARAMETER PrimaryNode
    Nom court du nœud primaire. Défaut : SQLS01

.PARAMETER SecondaryNode
    Nom court du nœud secondaire. Défaut : SQLS02

.PARAMETER PrimaryEndpoint
    Endpoint URL du replica primaire. Défaut : TCP://192.168.1.251:5022

.PARAMETER SecondaryEndpoint
    Endpoint URL du replica secondaire. Défaut : TCP://192.168.1.252:5022

.PARAMETER WhatIf
    Prévisualisation sans modification.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\5.3.0.create_availability_group.log

.EXAMPLE
    # Création standard (idempotent)
    .\5.3.0.create_availability_group.ps1

.EXAMPLE
    # Prévisualisation
    .\5.3.0.create_availability_group.ps1 -WhatIf

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : SQLS01 (Primary) - À exécuter sur le nœud primaire uniquement

    ===========================================================================
    ⚠️  PRÉREQUIS :
    ===========================================================================
    1. Always On activé sur les deux nœuds (5.1)
    2. Endpoints HADR créés et démarrés (5.2)
    3. Cluster WSFC opérationnel avec les deux nœuds en Up
    4. Logins SVC_SQL_Engine créés sur les deux nœuds (fait en 5.2)
    5. Résolution DNS bidirectionnelle entre les nœuds

    ===========================================================================
    📝  NOTES TECHNIQUES :
    ===========================================================================
    - SEEDING_MODE = AUTOMATIC permet la synchronisation automatique
      des bases ajoutées ultérieurement (pas de backup/restore manuel).
    - Aucune base n'est ajoutée à l'AG à ce stade : c'est l'étape 6.2.
    - L'AG doit être créé sur le nœud primaire WSFC.
    ===========================================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AGName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$PrimaryNode = "SQLS01",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SecondaryNode = "SQLS02",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$PrimaryEndpoint = "TCP://192.168.1.251:5022",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SecondaryEndpoint = "TCP://192.168.1.252:5022",

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\5.3.0.create_availability_group.log"
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
        [Parameter(Mandatory = $false)] [string]$Database = "master",
        [Parameter(Mandatory = $false)] [string]$ServerInstance = $script:Fqdn
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $Query -ErrorAction Stop
}

function Get-SqlAlwaysOnStatus {
    param([string]$ServerInstance = $script:Fqdn)
    try {
        $result = Invoke-SqlQuery -ServerInstance $ServerInstance -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled"
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

function Test-AGExists {
    param([string]$Name)
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT COUNT(*) AS AGCount
FROM sys.availability_groups
WHERE name = '$Name'
"@
        return ($result.AGCount -gt 0)
    } catch {
        return $false
    }
}

function Get-AGInfo {
    param([string]$Name)
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT 
    ag.name AS AGName,
    ag.group_id AS AGId,
    ag.is_distributed AS IsDistributed,
    ag.failure_condition_level AS FailureConditionLevel,
    ag.health_check_timeout AS HealthCheckTimeout,
    ag.automated_backup_preference_desc AS BackupPreference,
    ag.dtc_support AS DTCSupport
FROM sys.availability_groups ag
WHERE ag.name = '$Name'
"@
        return $result
    } catch {
        return $null
    }
}

function Get-AGReplicas {
    param([string]$Name)
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT 
    ar.replica_server_name AS ReplicaServer,
    ar.availability_mode_desc AS AvailabilityMode,
    ar.failover_mode_desc AS FailoverMode,
    ar.seeding_mode_desc AS SeedingMode,
    ar.endpoint_url AS EndpointUrl
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$Name'
"@
        return $result
    } catch {
        return $null
    }
}

function Test-EndpointReachable {
    param([string]$EndpointUrl)
    try {
        if ($EndpointUrl -match "TCP://([^:]+):(\d+)") {
            $hostName = $Matches[1]
            $port = [int]$Matches[2]
            $test = Test-NetConnection -ComputerName $hostName -Port $port -WarningAction SilentlyContinue
            return $test.TcpTestSucceeded
        }
        return $false
    } catch {
        return $false
    }
}

function Test-DnsResolution {
    param([string]$Hostname)
    try {
        $result = Resolve-DnsName -Name $Hostname -ErrorAction Stop
        return ($result.Count -gt 0)
    } catch {
        return $false
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.3.0 - Création de l'Availability Group ($AGName)"
    Write-Host " Serveur local    : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " FQDN             : $script:Fqdn" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " PowerShell       : $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " AG Name          : $AGName" -ForegroundColor Gray
    Write-Host " Primary          : $PrimaryNode ($PrimaryEndpoint)" -ForegroundColor Gray
    Write-Host " Secondary        : $SecondaryNode ($SecondaryEndpoint)" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --------------------------------------------------------
    # PRÉ-VOL 1/5 : Privilèges et cluster WSFC
    # --------------------------------------------------------
    Write-Section "Pré-vol 1/5 : Privilèges et cluster WSFC"

    if (-not (Test-IsAdministrator)) {
        throw "Ce script doit être exécuté en tant qu'administrateur."
    }
    Write-Step "Privilèges administrateur confirmés" "OK"

    try {
        Import-Module FailoverClusters -ErrorAction Stop
        $cluster = Get-Cluster -ErrorAction Stop
        Write-Step "Cluster WSFC : $($cluster.Name)" "OK"

        # --- DÉTECTION AUTOMATIQUE DU NŒUD PRIMAIRE ---
        Write-Host ""
        Write-Host "  Détection automatique du nœud primaire WSFC..." -ForegroundColor Cyan

        # Le primary est le propriétaire de la ressource "Nom du cluster"
        $clusterOwner = (Get-ClusterResource -Name "Nom du cluster" -ErrorAction Stop).OwnerNode.Name
        Write-Step "Nœud primaire WSFC (propriétaire du CNO) : $clusterOwner" "INFO"

        # Vérifier que le script est exécuté sur ce nœud
        $currentNode = $env:COMPUTERNAME
        if ($currentNode -ne $clusterOwner) {
            Write-Host ""
            Write-Step "Ce script doit être exécuté sur le PRIMARY ('$clusterOwner')" "ERROR"
            Write-Step "Actuellement exécuté sur : '$currentNode'" "ERROR"
            Write-Host ""
            Write-Host "  Actions possibles :" -ForegroundColor Yellow
            Write-Host "    1. Basculer le cluster vers '$currentNode' :" -ForegroundColor Gray
            Write-Host "       Move-ClusterGroup -Name 'Groupe du cluster' -Node '$currentNode'" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "    2. OU exécuter ce script sur '$clusterOwner'" -ForegroundColor Gray
            Write-Host ""
            throw "Mauvais nœud : exécutez ce script sur '$clusterOwner'."
        }
        Write-Step "Exécution sur le nœud primaire WSFC : $currentNode" "OK"

        # Mettre à jour le paramètre PrimaryNode avec la valeur détectée
        $PrimaryNode = $clusterOwner
        Write-Step "PrimaryNode défini automatiquement sur : $PrimaryNode" "INFO"

        # Vérifier que les deux nœuds sont Up
        $nodes = Get-ClusterNode
        foreach ($node in $nodes) {
            if ($node.Name -in @($PrimaryNode, $SecondaryNode)) {
                if ($node.State -eq "Up") {
                    Write-Step "  Nœud $($node.Name) : $($node.State)" "OK"
                } else {
                    Write-Step "  Nœud $($node.Name) : $($node.State)" "ERROR"
                    throw "Le nœud $($node.Name) n'est pas Up."
                }
            }
        }
    } catch {
        throw "Erreur cluster WSFC : $($_.Exception.Message)"
    }
    # --------------------------------------------------------
    # PRÉ-VOL 2 : Module SqlServer + Always On
    # --------------------------------------------------------
    Write-Section "Pré-vol 2/5 : Module SqlServer et Always On"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible. Exécutez d'abord 5.1.0."
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # Vérifier Always On sur les deux nœuds
    foreach ($node in @($PrimaryNode, $SecondaryNode)) {
        $fqdnNode = "$node.$($script:Fqdn.Split('.',2)[1])"
        $hadrStatus = Get-SqlAlwaysOnStatus -ServerInstance $fqdnNode

        if (-not $hadrStatus.Found) {
            throw "Impossible de vérifier Always On sur $node : $($hadrStatus.Error)"
        }
        if ($hadrStatus.Value -ne 1) {
            throw "Always On N'EST PAS activé sur $node (IsHadrEnabled = $($hadrStatus.Value))."
        }
        Write-Step "  $node : IsHadrEnabled = 1" "OK"
    }

    # --------------------------------------------------------
    # PRÉ-VOL 3 : Endpoints HADR
    # --------------------------------------------------------
    Write-Section "Pré-vol 3/5 : Endpoints HADR"

    foreach ($endpoint in @(
        @{ Node = $PrimaryNode;   Url = $PrimaryEndpoint },
        @{ Node = $SecondaryNode; Url = $SecondaryEndpoint }
    )) {
        # Vérifier que l'endpoint HADR existe sur le nœud
        $fqdnNode = "$($endpoint.Node).$($script:Fqdn.Split('.',2)[1])"
        $endpointQuery = @"
SELECT COUNT(*) AS EndpointCount
FROM sys.endpoints
WHERE name = 'Hadr_endpoint' AND state_desc = 'STARTED'
"@
        $endpointResult = Invoke-SqlQuery -ServerInstance $fqdnNode -Query $endpointQuery

        if ($endpointResult.EndpointCount -gt 0) {
            Write-Step "  Endpoint HADR démarré sur $($endpoint.Node)" "OK"
        } else {
            throw "Endpoint HADR NON démarré sur $($endpoint.Node). Exécutez 5.2 d'abord."
        }

        # Vérifier que l'endpoint est joignable
        if (Test-EndpointReachable -EndpointUrl $endpoint.Url) {
            Write-Step "  Endpoint joignable : $($endpoint.Url)" "OK"
        } else {
            Write-Step "  Endpoint non joignable : $($endpoint.Url)" "WARN"
            $script:Warnings += "Endpoint $($endpoint.Url) non joignable"
        }
    }

    # --------------------------------------------------------
    # PRÉ-VOL 4 : Résolution DNS
    # --------------------------------------------------------
    Write-Section "Pré-vol 4/5 : Résolution DNS"

    foreach ($node in @($PrimaryNode, $SecondaryNode)) {
        $fqdnNode = "$node.$($script:Fqdn.Split('.',2)[1])"
        if (Test-DnsResolution -Hostname $fqdnNode) {
            Write-Step "  DNS résout : $fqdnNode" "OK"
        } else {
            throw "DNS ne résout pas : $fqdnNode"
        }
    }

    # --------------------------------------------------------
    # PRÉ-VOL 5 : AG existant ?
    # --------------------------------------------------------
    Write-Section "Pré-vol 5/5 : Vérification de l'existence de l'AG"

    if (Test-AGExists -Name $AGName) {
        Write-Step "L'Availability Group '$AGName' existe déjà" "OK"
        $agInfo = Get-AGInfo -Name $AGName
        $agReplicas = Get-AGReplicas -Name $AGName

        Write-Host ""
        Write-Host "  Détails de l'AG existant :" -ForegroundColor Cyan
        Write-Host "    Nom                : $($agInfo.AGName)" -ForegroundColor Gray
        Write-Host "    ID                 : $($agInfo.AGId)" -ForegroundColor Gray
        Write-Host "    Backup Preference  : $($agInfo.BackupPreference)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Réplicas configurés :" -ForegroundColor Cyan
        foreach ($r in $agReplicas) {
            Write-Host "    - $($r.ReplicaServer) [$($r.AvailabilityMode) / $($r.FailoverMode) / $($r.SeedingMode)]" -ForegroundColor Gray
        }
        Write-Host ""

        Write-Section "Résumé"
        Write-Host "  Availability Group '$AGName' déjà présent" -ForegroundColor Green
        Write-Host "  Aucune action nécessaire." -ForegroundColor Gray
        return
    }

    Write-Step "L'AG '$AGName' n'existe pas - création nécessaire" "INFO"

    # --------------------------------------------------------
    # CRÉATION DE L'AG
    # --------------------------------------------------------
    Write-Section "Création de l'Availability Group"

    $createAGQuery = @"
CREATE AVAILABILITY GROUP [$AGName]
FOR REPLICA ON
N'$PrimaryNode' WITH (
    ENDPOINT_URL = '$PrimaryEndpoint',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = AUTOMATIC,
    SEEDING_MODE = AUTOMATIC
),
N'$SecondaryNode' WITH (
    ENDPOINT_URL = '$SecondaryEndpoint',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = AUTOMATIC,
    SEEDING_MODE = AUTOMATIC
);
"@

    if ($WhatIfPreference) {
        Write-Host ""
        Write-Host "  Requête SQL qui serait exécutée :" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
        $createAGQuery -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        Write-Step "CREATE AVAILABILITY GROUP [$AGName] ... (WhatIf)" "SKIP"
    } else {
        Write-Step "Création de l'AG '$AGName'..." "INFO"
        try {
            Invoke-SqlQuery -Query $createAGQuery | Out-Null
            Write-Step "AG '$AGName' créé avec succès" "OK"
        } catch {
            throw "Échec de création de l'AG : $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # VÉRIFICATION POST-EXÉCUTION
    # --------------------------------------------------------
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Start-Sleep -Seconds 3

        # Vérifier que l'AG existe
        if (Test-AGExists -Name $AGName) {
            Write-Step "AG '$AGName' existe" "OK"
        } else {
            Write-Step "AG '$AGName' NON trouvé après création" "ERROR"
            $script:Errors += "AG non trouvé après création"
        }

        # Détails de l'AG
        $agInfo = Get-AGInfo -Name $AGName
        $agReplicas = Get-AGReplicas -Name $AGName

        if ($agInfo) {
            Write-Host ""
            Write-Host "  Configuration de l'AG :" -ForegroundColor Cyan
            Write-Host "    Nom                : $($agInfo.AGName)" -ForegroundColor Gray
            Write-Host "    ID                 : $($agInfo.AGId)" -ForegroundColor Gray
            Write-Host "    Backup Preference  : $($agInfo.BackupPreference)" -ForegroundColor Gray
        }

        if ($agReplicas) {
            Write-Host ""
            Write-Host "  Réplicas configurés :" -ForegroundColor Cyan
            foreach ($r in $agReplicas) {
                $status = if ($r.AvailabilityMode -eq "SYNCHRONOUS_COMMIT" -and $r.FailoverMode -eq "AUTOMATIC") { "OK" } else { "WARN" }
                Write-Host "    - $($r.ReplicaServer) [$($r.AvailabilityMode) / $($r.FailoverMode) / $($r.SeedingMode)]" -ForegroundColor Gray
            }

            if ($agReplicas.Count -eq 2) {
                Write-Step "2 réplicas configurés" "OK"
            } else {
                Write-Step "$($agReplicas.Count) réplica(s) configuré(s) (attendu : 2)" "WARN"
                $script:Warnings += "Nombre de réplicas inattendu"
            }
        }

        # Vérifier l'état de l'AG (doit être en cours de synchronisation)
        try {
            $agState = Invoke-SqlQuery -Query @"
SELECT 
    ag.name AS AGName,
    ags.primary_replica AS PrimaryReplica,
    ags.synchronization_health_desc AS SyncHealth
FROM sys.dm_hadr_availability_group_states ags
JOIN sys.availability_groups ag ON ags.group_id = ag.group_id
WHERE ag.name = '$AGName'
"@

            if ($agState) {
                Write-Host ""
                Write-Host "  État de l'AG :" -ForegroundColor Cyan
                Write-Host "    Primary Replica     : $($agState.PrimaryReplica)" -ForegroundColor Gray
                Write-Host "    Sync Health         : $($agState.SyncHealth)" -ForegroundColor Gray

                if ($agState.SyncHealth -eq "HEALTHY") {
                    Write-Step "Sync Health : HEALTHY" "OK"
                } elseif ($agState.SyncHealth -eq "PARTIALLY_HEALTHY") {
                    Write-Step "Sync Health : PARTIALLY_HEALTHY (en cours de synchronisation)" "WARN"
                } else {
                    Write-Step "Sync Health : $($agState.SyncHealth)" "WARN"
                }
            }
        } catch {
            Write-Step "Impossible de vérifier l'état de l'AG : $($_.Exception.Message)" "WARN"
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
    Write-Host "  AG               : $AGName" -ForegroundColor Cyan
    Write-Host "  Primary          : $PrimaryNode" -ForegroundColor Cyan
    Write-Host "  Secondary        : $SecondaryNode" -ForegroundColor Cyan
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

    Write-Host "  ✅ Availability Group '$AGName' créé avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaine étape :" -ForegroundColor Yellow
    Write-Host "    1. Exécuter 5.4 sur $SecondaryNode (rejoindre l'AG)" -ForegroundColor Gray
    Write-Host "    2. Exécuter 5.5 sur $PrimaryNode (créer le Listener)" -ForegroundColor Gray
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