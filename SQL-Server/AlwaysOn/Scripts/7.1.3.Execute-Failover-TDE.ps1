<#
.SYNOPSIS
    Effectue une bascule RÉELLE de l'Availability Group vers un nœud cible.
    Ne rebascule PAS automatiquement (contrairement au script de test 7.1.2).

.DESCRIPTION
    Ce script bascule l'Availability Group AG-OPTIMEDIT vers un nœud cible
    (SQLS02 par défaut) et valide que :
      - Le nœud cible est bien PRIMARY + CONNECTED
      - Le nœud source est bien SECONDARY + CONNECTED
      - Les 13 bases sont ONLINE et chiffrées (TDE) sur le nouveau primaire
      - Une requête de test sur DB_Direction est servie par le nouveau primaire

    CONTRAIREMENT au script 7.1.2.Test-Failover-TDE.ps1, ce script NE FAIT PAS
    de rebascule automatique vers le nœud d'origine : il laisse l'AG dans l'état
    basculé. C'est utile pour :
      - Tester en conditions réelles un basculement de production
      - Mettre SQLS02 en PRIMARY pour maintenance de SQLS01
      - Valider la persistance applicative après bascule

    UTILISATION BIDIRECTIONNELLE :
      - Pour basculer vers SQLS02 : .\7.1.3.Execute-Failover-TDE.ps1
      - Pour basculer vers SQLS01 : .\7.1.3.Execute-Failover-TDE.ps1 -TargetNode SQLS01

.PARAMETER TargetNode
    Nœud vers lequel basculer l'AG. Accepte SQLS01, SQLS02, ou les FQDN.
    Défaut : SQLS02.optimedit.eu

.PARAMETER AvailabilityGroupName
    Nom de l'Availability Group. Défaut : AG-OPTIMEDIT

.PARAMETER Databases
    Liste des bases à vérifier après bascule. Défaut : les 13 bases applicatives.

.PARAMETER TestDatabase
    Base utilisée pour le test de requête. Défaut : DB_Direction

.PARAMETER FailoverTimeoutSeconds
    Timeout d'attente de la bascule. Défaut : 60 secondes.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\7.1.3.Execute-Failover-TDE.log

.EXAMPLE
    # Prévisualisation (aucune bascule réelle)
    .\7.1.3.Execute-Failover-TDE.ps1 -TargetNode SQLS02 -WhatIf

.EXAMPLE
    # Bascule réelle vers SQLS02
    .\7.1.3.Execute-Failover-TDE.ps1 -TargetNode SQLS02

.EXAMPLE
    # Bascule réelle vers SQLS01 (retour à l'état nominal)
    .\7.1.3.Execute-Failover-TDE.ps1 -TargetNode SQLS01

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : Poste d'administration (ou SQLS01/SQLS02)
    Prérequis :
        - Module SqlServer (Install-Module -Name SqlServer)
        - Module FailoverClusters (RSAT-Clustering)
        - AG-OPTIMEDIT en état SYNCHRONIZED
        - TDE activé sur les 13 bases et certificat restauré sur les deux nœuds
    IMPORTANT :
        Ce script effectue une VRAIE bascule. Ne pas exécuter en production
        sans préavis. Utilisez -WhatIf pour prévisualiser.
        Le script NE REBASCULE PAS automatiquement : utilisez-le à bon escient.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("SQLS01", "SQLS02", "SQLS01.optimedit.eu", "SQLS02.optimedit.eu")]
    [string]$TargetNode = "SQLS02.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AvailabilityGroupName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [string[]]$Databases = @(
        "DB_Direction", "DB_Comptabilite", "DB_Paie", "DB_RH", "DB_CE",
        "DB_IT", "DB_Production", "DB_Formation", "DB_Achat",
        "DB_Commercial", "DB_Client", "DB_Juridique", "DB_Blog"
    ),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TestDatabase = "DB_Direction",

    [Parameter(Mandatory = $false)]
    [ValidateRange(10, 300)]
    [int]$FailoverTimeoutSeconds = 60,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\7.1.3.Execute-Failover-TDE.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:FailoverPerformed = $false

# Normalisation du nœud cible : "SQLS02.optimedit.eu" -> "SQLS02.optimedit.eu" conservé, "SQLS02" -> "SQLS02.optimedit.eu"
$TargetNodeFQDN = if ($TargetNode -notmatch '\.') { "$TargetNode.optimedit.eu" } else { $TargetNode }
$TargetNodeShort = ($TargetNodeFQDN -split '\.')[0]

# Détermination automatique du nœud source (l'autre nœud)
$allNodes = @("SQLS01", "SQLS02")
$SourceNodeShort = $allNodes | Where-Object { $_ -ne $TargetNodeShort }
$SourceNodeFQDN = "$SourceNodeShort.optimedit.eu"

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

function Invoke-SqlQuery {
    param(
        [Parameter(Mandatory = $true)] [string]$Query,
        [Parameter(Mandatory = $true)] [string]$ServerInstance,
        [Parameter(Mandatory = $false)] [string]$Database = "master"
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $Query -ErrorAction Stop -TrustServerCertificate
}

function Get-AGRole {
    param([string]$ServerInstance, [string]$AGName)
    try {
        $query = @"
SELECT 
    ar.replica_server_name AS Replica,
    ars.role_desc AS Role,
    ars.operational_state_desc AS OpState,
    ars.connected_state_desc AS ConnState,
    ars.synchronization_health_desc AS SyncHealth
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AGName'
ORDER BY ar.replica_server_name
"@
        return Invoke-SqlQuery -Query $query -ServerInstance $ServerInstance
    } catch {
        return $null
    }
}

function Get-AGDatabaseState {
    param([string]$ServerInstance, [string]$AGName)
    try {
        $query = @"
SELECT 
    db.name AS DatabaseName,
    db.state_desc AS State,
    db.is_encrypted AS IsEncrypted,
    drs.synchronization_state_desc AS SyncState,
    drs.synchronization_health_desc AS SyncHealth
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
JOIN sys.databases db ON adc.database_name = db.name
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
WHERE ag.name = '$AGName' AND ar.replica_server_name = '$ServerInstance'
ORDER BY db.name
"@
        return Invoke-SqlQuery -Query $query -ServerInstance $ServerInstance
    } catch {
        return $null
    }
}

function Wait-AGRoleChange {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)] [string]$ServerInstance,
        [Parameter(Mandatory = $true)] [string]$AGName,
        [Parameter(Mandatory = $true)] [ValidateSet("PRIMARY", "SECONDARY")] [string]$ExpectedRole,
        [Parameter(Mandatory = $false)] [int]$TimeoutSeconds = 60,
        [Parameter(Mandatory = $false)] [int]$PollIntervalSeconds = 3
    )

    $shortName = ($ServerInstance -split '\.')[0].ToUpperInvariant()
    $expectedRoleUpper = $ExpectedRole.ToUpperInvariant()

    $startTime = Get-Date
    $deadline = $startTime.AddSeconds($TimeoutSeconds)
    $attempts = 0
    $lastState = "Aucun état récupéré"
    $lastFullState = ""

    while ((Get-Date) -lt $deadline) {
        $attempts++
        $roles = $null

        try {
            $roles = Get-AGRole -ServerInstance $ServerInstance -AGName $AGName -ErrorAction Stop
        } catch {
            $lastState = "Erreur Get-AGRole : $($_.Exception.Message)"
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }

        if ($roles) {
            $lastFullState = ($roles | ForEach-Object {
                "$($_.Replica) = $($_.Role) / $($_.ConnState)"
            }) -join " ; "

            $targetReplica = $roles | Where-Object {
                ($_.Replica -split '\.')[0].ToUpperInvariant() -eq $shortName
            }

            if ($targetReplica) {
                $lastState = "$($targetReplica.Replica) = $($targetReplica.Role) / $($targetReplica.ConnState)"

                if ($targetReplica.Role.ToUpperInvariant() -eq $expectedRoleUpper -and
                    $targetReplica.ConnState.ToUpperInvariant() -eq "CONNECTED") {
                    return [PSCustomObject]@{
                        Success   = $true
                        State     = $lastState
                        FullState = $lastFullState
                        Elapsed   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
                        Attempts  = $attempts
                    }
                }
            } else {
                $lastState = "Nœud $shortName introuvable dans l'AG (réplicas : $lastFullState)"
            }
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $sleep = if ($elapsed -gt 30) { 5 } else { $PollIntervalSeconds }
        Start-Sleep -Seconds $sleep
    }

    return [PSCustomObject]@{
        Success   = $false
        State     = $lastState
        FullState = $lastFullState
        Elapsed   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
        Attempts  = $attempts
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "7.1.3 - Exécution d'une bascule réelle de l'Availability Group"
    Write-Host " Target Node         : $TargetNodeFQDN  (deviendra PRIMARY)" -ForegroundColor Gray
    Write-Host " Source Node         : $SourceNodeFQDN  (deviendra SECONDARY)" -ForegroundColor Gray
    Write-Host " AG Name             : $AvailabilityGroupName" -ForegroundColor Gray
    Write-Host " Test Database       : $TestDatabase" -ForegroundColor Gray
    Write-Host " Failover Timeout    : $FailoverTimeoutSeconds secondes" -ForegroundColor Gray
    Write-Host " Date                : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode                : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Log                 : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Modules ---
    Write-Section "Pré-vol 1/4 : Vérification et chargement des modules requis"

    try {
        $sqlModule = Ensure-Module -Name "SqlServer" `
            -InstallHint "Install-Module -Name SqlServer -Scope AllUsers -Force"
        Write-Step "Module SqlServer v$($sqlModule.Version) [$($sqlModule.Action)]" "OK"
    } catch { throw $_.Exception.Message }

    try {
        $clusterModule = Ensure-Module -Name "FailoverClusters" `
            -InstallHint "Install-WindowsFeature RSAT-Clustering -IncludeManagementTools"
        Write-Step "Module FailoverClusters v$($clusterModule.Version) [$($clusterModule.Action)]" "OK"
    } catch { throw $_.Exception.Message }

    foreach ($cmd in @("Invoke-Sqlcmd", "Switch-SqlAvailabilityGroup", "Get-ClusterGroup")) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            throw "Commande requise introuvable : $cmd."
        }
        Write-Step "Commande disponible : $cmd" "OK"
    }

    # --- PRÉ-VOL 2 : Connexion aux deux nœuds ---
    Write-Section "Pré-vol 2/4 : Vérification de la connexion aux deux nœuds"

    foreach ($node in @($TargetNodeFQDN, $SourceNodeFQDN)) {
        try {
            $null = Invoke-SqlQuery -Query "SELECT 1 AS Test" -ServerInstance $node
            Write-Step "Connexion SQL Server OK : $node" "OK"
        } catch {
            throw "Impossible de se connecter à $node : $($_.Exception.Message)"
        }
    }

    # --- PRÉ-VOL 3 : État initial de l'AG ---
    Write-Section "Pré-vol 3/4 : État initial de l'Availability Group"

    $initialRoles = Get-AGRole -ServerInstance $TargetNodeFQDN -AGName $AvailabilityGroupName
    if (-not $initialRoles) {
        throw "Impossible de récupérer l'état de l'AG '$AvailabilityGroupName'."
    }

    Write-Host ""
    Write-Host "  État initial des réplicas :" -ForegroundColor Cyan
    $initialRoles | Format-Table Replica, Role, OpState, ConnState, SyncHealth -AutoSize

    # Vérifier que le nœud source est bien PRIMARY
    $sourceReplica = $initialRoles | Where-Object { ($_.Replica -split '\.')[0] -eq $SourceNodeShort }
    if (-not $sourceReplica -or $sourceReplica.Role -ne "PRIMARY") {
        throw "$SourceNodeFQDN n'est pas le nœud PRIMARY actuel. État : $($sourceReplica.Role). Une bascule n'est pas nécessaire."
    }
    Write-Step "$SourceNodeFQDN est bien PRIMARY (état actuel)" "OK"

    # Vérifier que le nœud cible est bien SECONDARY + CONNECTED
    $targetReplica = $initialRoles | Where-Object { ($_.Replica -split '\.')[0] -eq $TargetNodeShort }
    if (-not $targetReplica -or $targetReplica.Role -ne "SECONDARY") {
        throw "$TargetNodeFQDN n'est pas SECONDARY. État : $($targetReplica.Role)."
    }
    if ($targetReplica.ConnState -ne "CONNECTED") {
        throw "$TargetNodeFQDN n'est pas CONNECTED. État : $($targetReplica.ConnState)."
    }
    Write-Step "$TargetNodeFQDN est bien SECONDARY + CONNECTED" "OK"

    # Vérifier que les bases sont synchronisées
    $initialDbs = Get-AGDatabaseState -ServerInstance $TargetNodeFQDN -AGName $AvailabilityGroupName
    $notSynced = $initialDbs | Where-Object { $_.SyncState -ne "SYNCHRONIZED" }
    if ($notSynced.Count -gt 0) {
        Write-Step "$($notSynced.Count) base(s) NON synchronisée(s) :" "WARN"
        $notSynced | ForEach-Object { Write-Host "    - $($_.DatabaseName) : $($_.SyncState)" -ForegroundColor Yellow }
        $script:Warnings += "Certaines bases ne sont pas synchronisées avant failover"
    } else {
        Write-Step "Toutes les bases sont SYNCHRONIZED" "OK"
    }

    # --- PRÉ-VOL 4 : État TDE initial ---
    Write-Section "Pré-vol 4/4 : Vérification de l'état TDE initial"

    $tdeQuery = @"
SELECT name AS DatabaseName, is_encrypted AS IsEncrypted
FROM sys.databases WHERE name LIKE 'DB_%' ORDER BY name
"@
    $tdeState = Invoke-SqlQuery -Query $tdeQuery -ServerInstance $SourceNodeFQDN
    $encryptedCount = ($tdeState | Where-Object { $_.IsEncrypted -eq $true }).Count

    Write-Step "Bases chiffrées (TDE) sur $SourceNodeFQDN : $encryptedCount / $($Databases.Count)" "OK"

    if ($encryptedCount -ne $Databases.Count) {
        Write-Step "Certaines bases ne sont PAS chiffrées - TDE incomplet" "WARN"
        $script:Warnings += "TDE incomplet sur $SourceNodeFQDN"
    }

    # --- ÉTAPE 1 : Bascule vers le nœud cible ---
    Write-Section "Étape 1/4 : Bascule de l'AG vers $TargetNodeFQDN"

    if ($WhatIfPreference) {
        Write-Step "Switch-SqlAvailabilityGroup -Path 'SQLSERVER:\SQL\$TargetNodeShort\DEFAULT\AvailabilityGroups\$AvailabilityGroupName' (WhatIf)" "SKIP"
    } else {
        try {
            Switch-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$TargetNodeShort\DEFAULT\AvailabilityGroups\$AvailabilityGroupName" -ErrorAction Stop
            $script:FailoverPerformed = $true
            Write-Step "Bascule initiée vers $TargetNodeFQDN" "OK"
        } catch {
            throw "Échec de la bascule : $($_.Exception.Message)"
        }
    }

    # --- ÉTAPE 2 : Attente et vérification du rôle cible ---
    if (-not $WhatIfPreference -and $script:FailoverPerformed) {
        Write-Section "Étape 2/4 : Attente et vérification du rôle PRIMARY sur $TargetNodeFQDN"

        Write-Host "  Attente de la bascule (timeout: $FailoverTimeoutSeconds s)..." -ForegroundColor Gray
        $waitResult = Wait-AGRoleChange -ServerInstance $TargetNodeFQDN `
                                        -AGName $AvailabilityGroupName `
                                        -ExpectedRole "PRIMARY" `
                                        -TimeoutSeconds $FailoverTimeoutSeconds

        if ($waitResult.Success) {
            Write-Step "$TargetNodeFQDN est maintenant PRIMARY et CONNECTED ($($waitResult.Elapsed)s, $($waitResult.Attempts) tentatives)" "OK"
        } else {
            Write-Step "Timeout - état actuel : $($waitResult.State)" "ERROR"
            Write-Host "  État complet : $($waitResult.FullState)" -ForegroundColor DarkGray
            $script:Errors += "Timeout de bascule (état: $($waitResult.State))"
        }

        $postRoles = Get-AGRole -ServerInstance $TargetNodeFQDN -AGName $AvailabilityGroupName
        Write-Host ""
        Write-Host "  État des réplicas après bascule :" -ForegroundColor Cyan
        $postRoles | Format-Table Replica, Role, OpState, ConnState, SyncHealth -AutoSize
    } else {
        Write-Step "Vérification du rôle ignorée (WhatIf)" "SKIP"
    }

    # --- ÉTAPE 3 : Vérification des bases et TDE sur le nouveau primaire ---
    if (-not $WhatIfPreference -and $script:FailoverPerformed) {
        Write-Section "Étape 3/4 : Vérification des bases et TDE sur $TargetNodeFQDN"

        $dbQuery = @"
SELECT name AS DatabaseName, state_desc AS State, is_encrypted AS IsEncrypted
FROM sys.databases WHERE name LIKE 'DB_%' ORDER BY name
"@
        $dbState = Invoke-SqlQuery -Query $dbQuery -ServerInstance $TargetNodeFQDN
        Write-Host ""
        Write-Host "  État des bases sur $TargetNodeFQDN :" -ForegroundColor Cyan
        $dbState | Format-Table DatabaseName, State, IsEncrypted -AutoSize

        $onlineCount = ($dbState | Where-Object { $_.State -eq "ONLINE" }).Count
        $encryptedCount = ($dbState | Where-Object { $_.IsEncrypted -eq $true }).Count

        Write-Step "Bases ONLINE sur $TargetNodeFQDN : $onlineCount / $($Databases.Count)" "OK"
        Write-Step "Bases chiffrées (TDE) sur $TargetNodeFQDN : $encryptedCount / $($Databases.Count)" "OK"

        if ($onlineCount -ne $Databases.Count) {
            Write-Step "Certaines bases ne sont PAS ONLINE" "ERROR"
            $script:Errors += "Bases non ONLINE sur $TargetNodeFQDN"
        }
        if ($encryptedCount -ne $Databases.Count) {
            Write-Step "Certaines bases ne sont PAS chiffrées" "ERROR"
            $script:Errors += "TDE incomplet sur $TargetNodeFQDN"
        }

        # Test de requête via le Listener (pour prouver la redirection)
        Write-Host ""
        Write-Host "  Test de requête via le Listener SQL-AG-LSTNR sur $TestDatabase :" -ForegroundColor Cyan
        try {
            $testQuery = "SELECT DB_NAME() AS CurrentDb, GETDATE() AS TestTime, @@SERVERNAME AS ServerName"
            $testResult = Invoke-SqlQuery -Query $testQuery -ServerInstance "SQL-AG-LSTNR.optimedit.eu" -Database $TestDatabase
            Write-Step "Requête réussie via le Listener" "OK"
            Write-Host "    Base       : $($testResult.CurrentDb)" -ForegroundColor Gray
            Write-Host "    Serveur    : $($testResult.ServerName)  (doit être $TargetNodeShort)" -ForegroundColor Gray
            Write-Host "    Heure      : $($testResult.TestTime)" -ForegroundColor Gray

            if ($testResult.ServerName -ne $TargetNodeShort) {
                Write-Step "ATTENTION : le Listener redirige vers $($testResult.ServerName) au lieu de $TargetNodeShort" "WARN"
                $script:Warnings += "Listener ne redirige pas vers $TargetNodeShort"
            }
        } catch {
            Write-Step "Échec de la requête via le Listener : $($_.Exception.Message)" "ERROR"
            $script:Errors += "Échec requête via Listener"
        }
    } else {
        Write-Step "Vérification des bases ignorée (WhatIf)" "SKIP"
    }

    # --- ÉTAPE 4 : Vérification de l'état final ---
    if (-not $WhatIfPreference) {
        Write-Section "Étape 4/4 : Vérification de l'état final"

        $finalRoles = Get-AGRole -ServerInstance $TargetNodeFQDN -AGName $AvailabilityGroupName
        Write-Host ""
        Write-Host "  État final des réplicas :" -ForegroundColor Cyan
        $finalRoles | Format-Table Replica, Role, OpState, ConnState, SyncHealth -AutoSize

        $finalPrimary = $finalRoles | Where-Object { ($_.Replica -split '\.')[0] -eq $TargetNodeShort }
        $finalSecondary = $finalRoles | Where-Object { ($_.Replica -split '\.')[0] -eq $SourceNodeShort }

        if ($finalPrimary -and $finalPrimary.Role -eq "PRIMARY") {
            Write-Step "$TargetNodeFQDN est bien PRIMARY" "OK"
        } else {
            Write-Step "$TargetNodeFQDN n'est PAS PRIMARY" "ERROR"
            $script:Errors += "État final incorrect : $TargetNodeFQDN n'est pas PRIMARY"
        }

        if ($finalSecondary -and $finalSecondary.Role -eq "SECONDARY") {
            Write-Step "$SourceNodeFQDN est bien SECONDARY" "OK"
        } else {
            Write-Step "$SourceNodeFQDN n'est PAS SECONDARY" "ERROR"
            $script:Errors += "État final incorrect : $SourceNodeFQDN n'est pas SECONDARY"
        }
    } else {
        Write-Step "Vérification finale ignorée (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  AG Name          : $AvailabilityGroupName" -ForegroundColor Cyan
    Write-Host "  Target Node      : $TargetNodeFQDN  (PRIMARY attendu)" -ForegroundColor Cyan
    Write-Host "  Source Node      : $SourceNodeFQDN  (SECONDARY attendu)" -ForegroundColor Cyan
    Write-Host "  Bascule effectuée: $(if ($script:FailoverPerformed) { 'OUI' } else { 'NON (WhatIf ou erreur)' })" -ForegroundColor $(if ($script:FailoverPerformed) { 'Green' } else { 'Yellow' })
    Write-Host "  Erreurs          : $($script:Errors.Count)" -ForegroundColor $(if ($script:Errors.Count -gt 0) { 'Red' } else { 'Gray' })
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

    if ($script:FailoverPerformed) {
        Write-Host "  ✅ Bascule réelle terminée avec succès" -ForegroundColor Green
        Write-Host "     $TargetNodeFQDN est maintenant PRIMARY" -ForegroundColor Green
        Write-Host "     $SourceNodeFQDN est maintenant SECONDARY" -ForegroundColor Green
    } else {
        Write-Host "  ⏭  Bascule NON effectuée (mode WhatIf)" -ForegroundColor Yellow
    }
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

    # Pas de rebascule automatique : ce script n'est PAS un test.
    # Si la bascule a été initiée mais que la vérification échoue,
    # l'admin doit intervenir manuellement.
    if ($script:FailoverPerformed -and -not $WhatIfPreference) {
        Write-Host ""
        Write-Host "  ⚠ La bascule a été initiée. Vérifiez manuellement l'état de l'AG :" -ForegroundColor Yellow
        Write-Host "    Import-Module FailoverClusters" -ForegroundColor Yellow
        Write-Host "    Get-ClusterGroup -Name '$AvailabilityGroupName'" -ForegroundColor Yellow
    }

    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}