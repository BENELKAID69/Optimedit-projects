<#
.SYNOPSIS
    Test de failover manuel de l'Availability Group AG-OPTIMEDIT.

.DESCRIPTION
    Ce script effectue un failover manuel planifié de l'AG-OPTIMEDIT
    vers le replica secondaire, puis vérifie que le failover a réussi.

    FONCTIONNALITÉS :
    - Détection automatique du primary et du secondary
    - Vérification préalable (AG healthy, replicas connectés)
    - Failover vers le nœud cible
    - Vérification post-failover complète
    - Support -WhatIf pour la prévisualisation
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Test optionnel de connexion via le Listener

.PARAMETER AGName
    Nom de l'Availability Group. Défaut : AG-OPTIMEDIT

.PARAMETER TargetNode
    Nom du nœud cible du failover. Défaut : SQLS02

.PARAMETER ListenerName
    Nom du Listener pour test optionnel. Défaut : SQL-AG-LSTNR

.PARAMETER TestListener
    Teste la connexion via le Listener après le failover.

.PARAMETER TranscriptPath
    Chemin du fichier de log.
    Défaut : .\5.6.0.test_failover.log

.EXAMPLE
    # Failover vers SQLS02 (par défaut)
    .\5.6.0.test_failover.ps1

.EXAMPLE
    # Prévisualisation
    .\5.6.0.test_failover.ps1 -WhatIf

.EXAMPLE
    # Failover avec test du Listener
    .\5.6.0.test_failover.ps1 -TestListener

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : À exécuter sur n'importe quel nœud du cluster

    ===========================================================================
    ⚠️  PRÉREQUIS :
    ===========================================================================
    1. AG-OPTIMEDIT créé (5.3)
    2. SQLS02 joint à l'AG (5.4)
    3. Listener SQL-AG-LSTNR créé (5.5)
    4. Les deux replicas CONNECTED

    ===========================================================================
    📝  NOTES TECHNIQUES :
    ===========================================================================
    - Le failover est MANUEL (pas automatique)
    - Il est PLANIFIÉ (pas en cas de panne)
    - Le primary devient secondary et vice-versa
    - L'IP virtuelle du Listener bascule automatiquement
    - Le CNO du Listener bascule aussi
    ===========================================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AGName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetNode = "SQLS02",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ListenerName = "SQL-AG-LSTNR",

    [Parameter(Mandatory = $false)]
    [switch]$TestListener,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\5.6.0.test_failover.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:Fqdn = "$env:COMPUTERNAME.$((Get-CimInstance Win32_ComputerSystem).Domain)"
$script:Domain = ($script:Fqdn -split '\.', 2)[1]

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
        [Parameter(Mandatory = $false)] [string]$ServerInstance = $script:Fqdn
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $Query -ErrorAction Stop
}

function Get-AGState {
    param(
        [string]$AGName,
        [string]$ServerInstance = $script:Fqdn
    )
    try {
        $result = Invoke-SqlQuery -ServerInstance $ServerInstance -Query @"
SELECT 
    ag.name AS AGName,
    ags.primary_replica AS PrimaryReplica,
    ags.synchronization_health_desc AS SyncHealth,
    ars.role_desc AS LocalRole,
    ars.connected_state_desc AS ConnectedState,
    ars.operational_state_desc AS OperationalState
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ag.group_id = ars.group_id
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
WHERE ag.name = '$AGName'
  AND ar.replica_server_name = '$env:COMPUTERNAME'
"@
        return $result
    } catch {
        return $null
    }
}

function Get-AllReplicasState {
    param(
        [string]$AGName,
        [string]$ServerInstance = $script:Fqdn
    )
    try {
        $result = Invoke-SqlQuery -ServerInstance $ServerInstance -Query @"
SELECT 
    ar.replica_server_name AS Replica,
    ars.role_desc AS Role,
    ars.connected_state_desc AS ConnectedState,
    ars.operational_state_desc AS OperationalState,
    ars.synchronization_health_desc AS SyncHealth
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AGName'
"@
        return $result
    } catch {
        return $null
    }
}

function Get-PrimaryAG {
    param([string]$AGName)
    try {
        Import-Module FailoverClusters -ErrorAction Stop
        $group = Get-ClusterGroup -Name $AGName -ErrorAction Stop
        return $group.OwnerNode.Name
    } catch {
        return $null
    }
}

function Test-ListenerConnection {
    param([string]$ListenerName)
    try {
        $dnsName = "$ListenerName.$($script:Domain)"
        $result = Invoke-SqlQuery -ServerInstance $dnsName -Query "SELECT @@SERVERNAME AS ServerName"
        return $result
    } catch {
        return $null
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.6.0 - Test de failover de l'AG ($AGName)"
    Write-Host " Serveur local    : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " AG Name          : $AGName" -ForegroundColor Gray
    Write-Host " Nœud cible       : $TargetNode" -ForegroundColor Gray
    Write-Host " Test Listener    : $(if ($TestListener) { 'OUI' } else { 'NON' })" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Module SqlServer ---
    Write-Section "Pré-vol 1/4 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible."
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # --- PRÉ-VOL 2 : État actuel de l'AG ---
    Write-Section "Pré-vol 2/4 : État actuel de l'AG"

    $currentPrimary = Get-PrimaryAG -AGName $AGName
    if (-not $currentPrimary) {
        throw "Impossible de détecter le primary AG pour '$AGName'."
    }
    Write-Step "Primary AG actuel : $currentPrimary" "INFO"

    # Vérifier que la cible n'est pas déjà le primary
    if ($currentPrimary -eq $TargetNode) {
        Write-Step "Le nœud cible '$TargetNode' est DÉJÀ le primary AG" "WARN"
        Write-Step "Aucune action nécessaire" "INFO"

        Write-Section "Résumé"
        Write-Host "  Aucun failover nécessaire" -ForegroundColor Yellow
        return
    }

    Write-Step "Le nœud cible '$TargetNode' est le secondary AG" "OK"

    # Vérifier l'état des replicas
    $replicas = Get-AllReplicasState -AGName $AGName
    if (-not $replicas) {
        throw "Impossible de lire l'état des replicas."
    }

    Write-Host ""
    Write-Host "  État des replicas :" -ForegroundColor Cyan
    foreach ($r in $replicas) {
        $color = if ($r.ConnectedState -eq "CONNECTED") { "Green" } else { "Yellow" }
        Write-Host "    $($r.Replica) : $($r.Role) / $($r.ConnectedState) / $($r.SyncHealth)" -ForegroundColor $color
    }

    # Vérifier que tous les replicas sont CONNECTED
    $allConnected = ($replicas | Where-Object { $_.ConnectedState -ne "CONNECTED" }).Count -eq 0
    if (-not $allConnected) {
        Write-Step "Tous les replicas ne sont pas CONNECTED" "WARN"
        $script:Warnings += "Replicas non tous connectés"

        if (-not $WhatIfPreference) {
            Write-Host ""
            Write-Host "  Voulez-vous continuer malgré tout ? (O/N) : " -NoNewline -ForegroundColor Yellow
            $answer = Read-Host
            if ($answer -notmatch "^[Oo]") {
                throw "Abandon : replicas non connectés."
            }
        }
    }

    # --- PRÉ-VOL 3 : Vérification de la cible ---
    Write-Section "Pré-vol 3/4 : Vérification du nœud cible"

    $targetReplica = $replicas | Where-Object { $_.Replica -eq $TargetNode }
    if (-not $targetReplica) {
        throw "Le nœud cible '$TargetNode' n'est pas un replica de l'AG."
    }

    if ($targetReplica.Role -ne "SECONDARY") {
        throw "Le nœud cible '$TargetNode' n'est pas en rôle SECONDARY (rôle actuel : $($targetReplica.Role))."
    }

    Write-Step "Nœud cible '$TargetNode' : $($targetReplica.Role) / $($targetReplica.ConnectedState)" "OK"

    # --- PRÉ-VOL 4 : État du Listener ---
    Write-Section "Pré-vol 4/4 : État du Listener"

    $listenerState = Test-ListenerConnection -ListenerName $ListenerName
    if ($listenerState) {
        Write-Step "Listener '$ListenerName' accessible : @@SERVERNAME = $($listenerState.ServerName)" "OK"
    } else {
        Write-Step "Listener '$ListenerName' non accessible actuellement" "WARN"
        $script:Warnings += "Listener non testé"
    }

    # --- CONFIRMATION ---
    Write-Section "Confirmation du failover"

    Write-Host ""
    Write-Host "  ⚠️  Vous êtes sur le point de basculer l'AG '$AGName'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "     Primary actuel  : $currentPrimary" -ForegroundColor Gray
    Write-Host "     Nouveau primary : $TargetNode" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Le failover est MANUEL et PLANIFIÉ." -ForegroundColor Gray
    Write-Host ""

    if (-not $WhatIfPreference) {
        Write-Host "  Confirmer le failover ? (O/N) : " -NoNewline -ForegroundColor Yellow
        $confirm = Read-Host
        if ($confirm -notmatch "^[Oo]") {
            Write-Step "Failover annulé par l'utilisateur" "WARN"
            return
        }
    }

    # --- FAILOVER ---
    Write-Section "Exécution du failover"

    if ($WhatIfPreference) {
        Write-Host ""
        Write-Host "  Commande qui serait exécutée :" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Switch-SqlAvailabilityGroup -Path 'SQLSERVER:\SQL\$TargetNode\DEFAULT\AvailabilityGroups\$AGName'" -ForegroundColor DarkGray
        Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        Write-Step "Switch-SqlAvailabilityGroup (WhatIf)" "SKIP"
    } else {
        Write-Step "Bascule de '$currentPrimary' vers '$TargetNode'..." "INFO"

        $swStartTime = Get-Date
        try {
            $path = "SQLSERVER:\SQL\$TargetNode\DEFAULT\AvailabilityGroups\$AGName"
            Switch-SqlAvailabilityGroup -Path $path -ErrorAction Stop
            $swDuration = (Get-Date) - $swStartTime
            Write-Step "Failover effectué en $([math]::Round($swDuration.TotalSeconds, 2)) secondes" "OK"
        } catch {
            throw "Échec du failover : $($_.Exception.Message)"
        }

        # Attendre la stabilisation
        Write-Step "Attente de la stabilisation (10 sec)..." "INFO"
        Start-Sleep -Seconds 10
    }

    # --- VÉRIFICATION POST-FAILOVER ---
    Write-Section "Vérification post-failover"

    if (-not $WhatIfPreference) {
        # Nouveau primary AG
        $newPrimary = Get-PrimaryAG -AGName $AGName
        if ($newPrimary -eq $TargetNode) {
            Write-Step "Nouveau primary AG : $newPrimary (correct)" "OK"
        } else {
            Write-Step "Nouveau primary AG : $newPrimary (attendu : $TargetNode)" "ERROR"
            $script:Errors += "Le primary n'a pas basculé vers $TargetNode"
        }

        # État des replicas
        $newReplicas = Get-AllReplicasState -AGName $AGName
        if ($newReplicas) {
            Write-Host ""
            Write-Host "  État des replicas après failover :" -ForegroundColor Cyan
            foreach ($r in $newReplicas) {
                $color = switch ($r.ConnectedState) {
                    "CONNECTED" { "Green" }
                    "DISCONNECTED" { "Yellow" }
                    default { "Gray" }
                }
                Write-Host "    $($r.Replica) : $($r.Role) / $($r.ConnectedState) / $($r.SyncHealth)" -ForegroundColor $color
            }
        }

        # Test du Listener
        if ($TestListener) {
            Write-Host ""
            Write-Section "Test de connexion via le Listener"

            $listenerTest = Test-ListenerConnection -ListenerName $ListenerName
            if ($listenerTest) {
                if ($listenerTest.ServerName -eq $TargetNode) {
                    Write-Step "Listener bascule : @@SERVERNAME = $($listenerTest.ServerName) (correct)" "OK"
                } else {
                    Write-Step "Listener : @@SERVERNAME = $($listenerTest.ServerName) (attendu : $TargetNode)" "WARN"
                    $script:Warnings += "Listener n'a pas basculé immédiatement"
                }
            } else {
                Write-Step "Listener non accessible après failover" "WARN"
                $script:Warnings += "Listener non accessible"
            }
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Serveur local    : $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "  AG               : $AGName" -ForegroundColor Cyan
    Write-Host "  Ancien primary   : $currentPrimary" -ForegroundColor Cyan
    Write-Host "  Nouveau primary  : $TargetNode" -ForegroundColor Cyan
    Write-Host "  Durée totale     : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
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

    Write-Host "  ✅ Failover effectué avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaines étapes :" -ForegroundColor Yellow
    Write-Host "    1. Vérifier que les applications se connectent au Listener" -ForegroundColor Gray
    Write-Host "    2. Rebasculer vers SQLS01 quand tu le souhaites :" -ForegroundColor Gray
    Write-Host "       .\5.6.0.test_failover.ps1 -TargetNode SQLS01" -ForegroundColor DarkGray
    Write-Host "    3. Passer à 6.1 (création des bases)" -ForegroundColor Gray
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