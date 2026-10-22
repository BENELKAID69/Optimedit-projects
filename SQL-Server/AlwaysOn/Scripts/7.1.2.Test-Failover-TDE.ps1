<#
.SYNOPSIS
    Teste un failover de l'Availability Group et valide TDE sur le secondaire.

.DESCRIPTION
    Ce script effectue un test complet de failover sur l'Availability Group
    AG-OPTIMEDIT, puis valide que TDE fonctionne correctement sur le nœud
    secondaire. À la fin, il rebascule vers le nœud primaire d'origine.

    ÉTAPES :
    1. Vérification et chargement des modules requis (SqlServer, FailoverClusters)
    2. Vérification de la connexion aux deux nœuds
    3. Récupération de l'état initial de l'AG (avant failover)
    4. Bascule de l'AG vers SQLS02 (secondaire)
    5. Attente de la reconnexion complète (CONNECTED)
    6. Vérification des rôles après bascule
    7. Vérification des bases (ONLINE + is_encrypted = 1)
    8. Test d'une requête sur une base chiffrée (DB_Direction)
    9. Attente que SQLS01 soit SECONDARY + CONNECTED
   10. Rebascule vers SQLS01 (nœud primaire d'origine)
   11. Vérification de l'état final (retour à l'état initial)

    FONCTIONNALITÉS :
    - Support -WhatIf (prévisualisation - n'effectue PAS la bascule)
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Vérifications préalables (modules, rôles, sync state)
    - Vérifications post-exécution (rôles, bases, TDE)
    - Timeout configurable pour la propagation du failover
    - Attente explicite de CONNECTED avant rebascule (piège page 82)
    - Rapport détaillé par étape

.PARAMETER PrimaryNode
    Nœud primaire d'origine. Défaut : SQLS01.optimedit.eu

.PARAMETER SecondaryNode
    Nœud secondaire cible du failover. Défaut : SQLS02.optimedit.eu

.PARAMETER AvailabilityGroupName
    Nom de l'Availability Group. Défaut : AG-OPTIMEDIT

.PARAMETER Databases
    Liste des bases à vérifier après bascule. Défaut : les 13 bases applicatives.

.PARAMETER TestDatabase
    Base utilisée pour le test de requête. Défaut : DB_Direction

.PARAMETER FailoverTimeoutSeconds
    Timeout d'attente après bascule. Défaut : 60 secondes.

.PARAMETER ReconnectTimeoutSeconds
    Timeout d'attente de la reconnexion du nœud secondaire avant rebascule.
    Défaut : 60 secondes.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\7.1.2.Test-Failover-TDE.log

.EXAMPLE
    # Prévisualisation (aucune bascule réelle)
    .\7.1.2.Test-Failover-TDE.ps1 -WhatIf

.EXAMPLE
    # Test complet (bascule + rebascule)
    .\7.1.2.Test-Failover-TDE.ps1

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.2
    Nœud    : Poste d'administration (ou SQLS01/SQLS02)
    Prérequis :
        - Module SqlServer installé (Install-Module -Name SqlServer)
        - Module FailoverClusters installé (RSAT-Clustering)
        - AG-OPTIMEDIT en état SYNCHRONIZED sur les deux nœuds
        - TDE activé sur les 13 bases
        - Certificat TDE restauré sur SQLS02 (étape 7.1.1)
    IMPORTANT :
        Ce script effectue une VRAIE bascule. Ne pas exécuter en production
        sans préavis. Utilisez -WhatIf pour prévisualiser.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$PrimaryNode = "SQLS01.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SecondaryNode = "SQLS02.optimedit.eu",

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
    [ValidateRange(10, 300)]
    [int]$ReconnectTimeoutSeconds = 60,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\7.1.2.Test-Failover-TDE.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:FailoverPerformed = $false

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

    .DESCRIPTION
        Trois étapes :
        1. Le module est-il déjà chargé dans la session ? → retourne son état.
        2. Le module est-il disponible sur le système ? → l'importe.
        3. Sinon → throw avec la commande d'installation suggérée.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$InstallHint = ""
    )

    # 1. Module déjà chargé ?
    $loaded = Get-Module -Name $Name -ErrorAction SilentlyContinue
    if ($loaded) {
        return [PSCustomObject]@{
            Name    = $Name
            Version = $loaded.Version
            Action  = "Déjà chargé"
        }
    }

    # 2. Module disponible sur le système ?
    $available = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue |
                 Sort-Object Version -Descending |
                 Select-Object -First 1

    if (-not $available) {
        $msg = "Module '$Name' introuvable sur ce système."
        if ($InstallHint) {
            $msg += "`n  → Installation : $InstallHint"
        }
        throw $msg
    }

    # 3. Import explicite
    try {
        Import-Module -Name $Name -ErrorAction Stop
        return [PSCustomObject]@{
            Name    = $Name
            Version = $available.Version
            Action  = "Importé"
        }
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
    param(
        [string]$ServerInstance,
        [string]$AGName
    )
    try {
        $query = @"
SELECT 
    ar.replica_server_name AS Replica,
    ars.role_desc AS Role,
    ars.operational_state_desc AS OpState,
    ars.connected_state_desc AS ConnState
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
    param(
        [string]$ServerInstance,
        [string]$AGName
    )
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
    <#
    .SYNOPSIS
        Attend qu'un nœud d'un Availability Group atteigne un rôle et un état
        de connexion attendus.

    .DESCRIPTION
        Interroge périodiquement l'AG pour vérifier que le nœud cible est bien
        dans le rôle et l'état CONNECTED attendus. Retourne un objet structuré
        indiquant le succès ou l'échec, avec l'état final observé pour faciliter
        le diagnostic.

        Correction importante : vérifie ConnState = CONNECTED en plus du rôle,
        car lors d'un failover, le nœud qui perd le rôle PRIMARY passe
        temporairement en DISCONNECTED avant de se reconnecter en SECONDARY
        (10-30 secondes). Sans cette vérification, la rebascule échoue.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerInstance,

        [Parameter(Mandatory = $true)]
        [string]$AGName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PRIMARY", "SECONDARY")]
        [string]$ExpectedRole,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 3
    )

    # Normalisation du nom de nœud : "SQLS02.optimedit.eu" -> "SQLS02"
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
            # Mémorise l'état complet pour le diagnostic
            $lastFullState = ($roles | ForEach-Object {
                "$($_.Replica) = $($_.Role) / $($_.ConnState)"
            }) -join " ; "

            # Recherche du nœud cible (comparaison insensible à la casse et aux FQDN)
            $targetReplica = $roles | Where-Object {
                ($_.Replica -split '\.')[0].ToUpperInvariant() -eq $shortName
            }

            if ($targetReplica) {
                $lastState = "$($targetReplica.Replica) = $($targetReplica.Role) / $($targetReplica.ConnState)"

                # Vérification du rôle ET de l'état de connexion
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

        # Polling adaptatif : 3 s au début, puis 5 s après 30 s
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
    Write-Section "7.1.2 - Test de failover TDE sur l'Availability Group"
    Write-Host " Primary Node        : $PrimaryNode" -ForegroundColor Gray
    Write-Host " Secondary Node      : $SecondaryNode" -ForegroundColor Gray
    Write-Host " AG Name             : $AvailabilityGroupName" -ForegroundColor Gray
    Write-Host " Test Database       : $TestDatabase" -ForegroundColor Gray
    Write-Host " Failover Timeout    : $FailoverTimeoutSeconds secondes" -ForegroundColor Gray
    Write-Host " Reconnect Timeout   : $ReconnectTimeoutSeconds secondes" -ForegroundColor Gray
    Write-Host " Date                : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode                : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Log                 : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Vérification et chargement des modules requis ---
    Write-Section "Pré-vol 1/4 : Vérification et chargement des modules requis"

    # --- Module SqlServer (obligatoire) ---
    try {
        $sqlModule = Ensure-Module -Name "SqlServer" `
            -InstallHint "Install-Module -Name SqlServer -Scope AllUsers -Force"
        Write-Step "Module SqlServer v$($sqlModule.Version) [$($sqlModule.Action)]" "OK"
    } catch {
        throw $_.Exception.Message
    }

    # --- Module FailoverClusters (obligatoire pour diagnostic cluster) ---
    try {
        $clusterModule = Ensure-Module -Name "FailoverClusters" `
            -InstallHint "Install-WindowsFeature RSAT-Clustering -IncludeManagementTools"
        Write-Step "Module FailoverClusters v$($clusterModule.Version) [$($clusterModule.Action)]" "OK"
    } catch {
        throw $_.Exception.Message
    }

    # --- Vérification des commandes critiques ---
    $requiredCommands = @(
        "Invoke-Sqlcmd",
        "Switch-SqlAvailabilityGroup",
        "Get-ClusterGroup"
    )
    foreach ($cmd in $requiredCommands) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            throw "Commande requise introuvable : $cmd. Vérifiez l'installation des modules SqlServer et FailoverClusters."
        }
        Write-Step "Commande disponible : $cmd" "OK"
    }

    # --- PRÉ-VOL 2 : Connexion aux deux nœuds ---
    Write-Section "Pré-vol 2/4 : Vérification de la connexion aux deux nœuds"

    foreach ($node in @($PrimaryNode, $SecondaryNode)) {
        try {
            $null = Invoke-SqlQuery -Query "SELECT 1 AS Test" -ServerInstance $node
            Write-Step "Connexion SQL Server OK : $node" "OK"
        } catch {
            throw "Impossible de se connecter à $node : $($_.Exception.Message)"
        }
    }

    # --- PRÉ-VOL 3 : État initial de l'AG ---
    Write-Section "Pré-vol 3/4 : État initial de l'Availability Group"

    $initialRoles = Get-AGRole -ServerInstance $PrimaryNode -AGName $AvailabilityGroupName
    if (-not $initialRoles) {
        throw "Impossible de récupérer l'état de l'AG '$AvailabilityGroupName'."
    }

    Write-Host ""
    Write-Host "  État initial des réplicas :" -ForegroundColor Cyan
    $initialRoles | Format-Table Replica, Role, OpState, ConnState -AutoSize

    # Vérifier que le nœud primaire est bien PRIMARY
    $primaryReplica = $initialRoles | Where-Object { $_.Replica -eq $PrimaryNode.Split('.')[0] }
    if (-not $primaryReplica -or $primaryReplica.Role -ne "PRIMARY") {
        throw "$PrimaryNode n'est pas le nœud PRIMARY actuel de l'AG. État : $($primaryReplica.Role)"
    }
    Write-Step "$PrimaryNode est bien PRIMARY" "OK"

    # Vérifier que le secondaire est bien CONNECTED
    $secondaryReplica = $initialRoles | Where-Object { $_.Replica -eq $SecondaryNode.Split('.')[0] }
    if (-not $secondaryReplica -or $secondaryReplica.ConnState -ne "CONNECTED") {
        throw "$SecondaryNode n'est pas CONNECTED. État : $($secondaryReplica.ConnState)"
    }
    Write-Step "$SecondaryNode est bien CONNECTED" "OK"

    # Vérifier que les bases sont synchronisées
    $initialDbs = Get-AGDatabaseState -ServerInstance $SecondaryNode -AGName $AvailabilityGroupName
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
SELECT 
    name AS DatabaseName,
    is_encrypted AS IsEncrypted
FROM sys.databases
WHERE name LIKE 'DB_%'
ORDER BY name
"@
    $tdeState = Invoke-SqlQuery -Query $tdeQuery -ServerInstance $PrimaryNode
    $encryptedCount = ($tdeState | Where-Object { $_.IsEncrypted -eq $true }).Count

    Write-Step "Bases chiffrées (TDE) sur $PrimaryNode : $encryptedCount / $($Databases.Count)" "OK"

    if ($encryptedCount -ne $Databases.Count) {
        Write-Step "Certaines bases ne sont PAS chiffrées - TDE incomplet" "WARN"
        $script:Warnings += "TDE incomplet sur $PrimaryNode"
    }

    # --- ÉTAPE 1 : Bascule vers le secondaire ---
    Write-Section "Étape 1/5 : Bascule de l'AG vers $SecondaryNode"

    if ($WhatIfPreference) {
        Write-Step "Switch-SqlAvailabilityGroup -Path 'SQLSERVER:\SQL\$($SecondaryNode.Split('.')[0])\DEFAULT\AvailabilityGroups\$AvailabilityGroupName' (WhatIf)" "SKIP"
    } else {
        try {
            Switch-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$($SecondaryNode.Split('.')[0])\DEFAULT\AvailabilityGroups\$AvailabilityGroupName" -ErrorAction Stop
            $script:FailoverPerformed = $true
            Write-Step "Bascule initiée vers $SecondaryNode" "OK"
        } catch {
            throw "Échec de la bascule : $($_.Exception.Message)"
        }
    }

    # --- ÉTAPE 2 : Attente et vérification des rôles après bascule ---
    if (-not $WhatIfPreference -and $script:FailoverPerformed) {
        Write-Section "Étape 2/5 : Attente et vérification des rôles après bascule"

        Write-Host "  Attente de la bascule (timeout: $FailoverTimeoutSeconds s)..." -ForegroundColor Gray
        $waitResult = Wait-AGRoleChange -ServerInstance $SecondaryNode `
                                        -AGName $AvailabilityGroupName `
                                        -ExpectedRole "PRIMARY" `
                                        -TimeoutSeconds $FailoverTimeoutSeconds

        if ($waitResult.Success) {
            Write-Step "$SecondaryNode est maintenant PRIMARY et CONNECTED ($($waitResult.Elapsed)s, $($waitResult.Attempts) tentatives)" "OK"
        } else {
            Write-Step "Timeout - état actuel : $($waitResult.State)" "ERROR"
            Write-Host "  État complet : $($waitResult.FullState)" -ForegroundColor DarkGray
            $script:Errors += "Timeout de bascule (état: $($waitResult.State))"
        }

        # Récupérer l'état des rôles après bascule
        $postRoles = Get-AGRole -ServerInstance $SecondaryNode -AGName $AvailabilityGroupName
        Write-Host ""
        Write-Host "  État des réplicas après bascule :" -ForegroundColor Cyan
        $postRoles | Format-Table Replica, Role, OpState, ConnState -AutoSize
    } else {
        Write-Step "Vérification des rôles ignorée (WhatIf)" "SKIP"
    }

    # --- ÉTAPE 3 : Vérification des bases et TDE ---
    if (-not $WhatIfPreference -and $script:FailoverPerformed) {
        Write-Section "Étape 3/5 : Vérification des bases et TDE sur $SecondaryNode"

        # Vérifier l'état des bases
        $dbQuery = @"
SELECT 
    name AS DatabaseName,
    state_desc AS State,
    is_encrypted AS IsEncrypted
FROM sys.databases
WHERE name LIKE 'DB_%'
ORDER BY name
"@
        $dbState = Invoke-SqlQuery -Query $dbQuery -ServerInstance $SecondaryNode
        Write-Host ""
        Write-Host "  État des bases sur $SecondaryNode :" -ForegroundColor Cyan
        $dbState | Format-Table DatabaseName, State, IsEncrypted -AutoSize

        $onlineCount = ($dbState | Where-Object { $_.State -eq "ONLINE" }).Count
        $encryptedCount = ($dbState | Where-Object { $_.IsEncrypted -eq $true }).Count

        Write-Step "Bases ONLINE sur $SecondaryNode : $onlineCount / $($Databases.Count)" "OK"
        Write-Step "Bases chiffrées (TDE) sur $SecondaryNode : $encryptedCount / $($Databases.Count)" "OK"

        if ($onlineCount -ne $Databases.Count) {
            Write-Step "Certaines bases ne sont PAS ONLINE" "ERROR"
            $script:Errors += "Bases non ONLINE sur $SecondaryNode"
        }

        if ($encryptedCount -ne $Databases.Count) {
            Write-Step "Certaines bases ne sont PAS chiffrées" "ERROR"
            $script:Errors += "TDE incomplet sur $SecondaryNode"
        }

        # Test d'une requête sur la base de test
        Write-Host ""
        Write-Host "  Test de requête sur $TestDatabase :" -ForegroundColor Cyan
        try {
            $testQuery = "SELECT DB_NAME() AS CurrentDb, GETDATE() AS TestTime, @@SERVERNAME AS ServerName"
            $testResult = Invoke-SqlQuery -Query $testQuery -ServerInstance $SecondaryNode -Database $TestDatabase
            Write-Step "Requête réussie sur $TestDatabase" "OK"
            Write-Host "    Base       : $($testResult.CurrentDb)" -ForegroundColor Gray
            Write-Host "    Serveur    : $($testResult.ServerName)" -ForegroundColor Gray
            Write-Host "    Heure      : $($testResult.TestTime)" -ForegroundColor Gray
        } catch {
            Write-Step "Échec de la requête sur $TestDatabase : $($_.Exception.Message)" "ERROR"
            $script:Errors += "Échec requête sur $TestDatabase"
        }
    } else {
        Write-Step "Vérification des bases ignorée (WhatIf)" "SKIP"
    }

    # --- ÉTAPE 4 : Attente de la reconnexion du nœud primaire d'origine ---
    if (-not $WhatIfPreference -and $script:FailoverPerformed) {
        Write-Section "Étape 4/5 : Attente de la reconnexion de $PrimaryNode avant rebascule"

        Write-Host "  Après un failover, le nœud qui perd le rôle PRIMARY passe" -ForegroundColor Gray
        Write-Host "  temporairement en DISCONNECTED avant de se reconnecter en SECONDARY." -ForegroundColor Gray
        Write-Host "  Cette reconnexion prend 10 à 30 secondes." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Attente que $PrimaryNode soit SECONDARY + CONNECTED (timeout: $ReconnectTimeoutSeconds s)..." -ForegroundColor Gray

        $reconnectResult = Wait-AGRoleChange -ServerInstance $PrimaryNode `
                                             -AGName $AvailabilityGroupName `
                                             -ExpectedRole "SECONDARY" `
                                             -TimeoutSeconds $ReconnectTimeoutSeconds

        if ($reconnectResult.Success) {
            Write-Step "$PrimaryNode est maintenant SECONDARY et CONNECTED ($($reconnectResult.Elapsed)s, $($reconnectResult.Attempts) tentatives)" "OK"
        } else {
            Write-Step "Timeout - $PrimaryNode n'est pas prêt pour la rebascule : $($reconnectResult.State)" "ERROR"
            Write-Host "  État complet : $($reconnectResult.FullState)" -ForegroundColor DarkGray
            $script:Errors += "Timeout de reconnexion avant rebascule (état: $($reconnectResult.State))"
            throw "Rebascule impossible : $PrimaryNode n'est pas dans un état stable."
        }
    } else {
        Write-Step "Attente de reconnexion ignorée (WhatIf)" "SKIP"
    }

    # --- ÉTAPE 5 : Rebascule vers le primaire d'origine ---
    Write-Section "Étape 5/5 : Rebascule vers $PrimaryNode"

    if ($WhatIfPreference) {
        Write-Step "Switch-SqlAvailabilityGroup -Path 'SQLSERVER:\SQL\$($PrimaryNode.Split('.')[0])\DEFAULT\AvailabilityGroups\$AvailabilityGroupName' (WhatIf)" "SKIP"
    } elseif ($script:FailoverPerformed) {
        try {
            Switch-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$($PrimaryNode.Split('.')[0])\DEFAULT\AvailabilityGroups\$AvailabilityGroupName" -ErrorAction Stop
            Write-Step "Rebascule initiée vers $PrimaryNode" "OK"

            # Attendre que le rôle soit effectif
            Write-Host "  Attente de la rebascule (timeout: $FailoverTimeoutSeconds s)..." -ForegroundColor Gray
            $waitResult = Wait-AGRoleChange -ServerInstance $PrimaryNode `
                                            -AGName $AvailabilityGroupName `
                                            -ExpectedRole "PRIMARY" `
                                            -TimeoutSeconds $FailoverTimeoutSeconds

            if ($waitResult.Success) {
                Write-Step "$PrimaryNode est de nouveau PRIMARY et CONNECTED ($($waitResult.Elapsed)s, $($waitResult.Attempts) tentatives)" "OK"
            } else {
                Write-Step "Timeout - état actuel : $($waitResult.State)" "ERROR"
                Write-Host "  État complet : $($waitResult.FullState)" -ForegroundColor DarkGray
                $script:Errors += "Timeout de rebascule (état: $($waitResult.State))"
            }
        } catch {
            Write-Step "Échec de la rebascule : $($_.Exception.Message)" "ERROR"
            $script:Errors += "Échec rebascule : $($_.Exception.Message)"
        }
    } else {
        Write-Step "Rebascule ignorée (pas de bascule effectuée)" "SKIP"
    }

    # --- VÉRIFICATION POST-EXÉCUTION ---
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Write-Host ""
        Write-Host "  État final des réplicas :" -ForegroundColor Cyan
        $finalRoles = Get-AGRole -ServerInstance $PrimaryNode -AGName $AvailabilityGroupName
        $finalRoles | Format-Table Replica, Role, OpState, ConnState -AutoSize

        # Vérifier que le primaire est bien revenu
        $finalPrimary = $finalRoles | Where-Object { $_.Replica -eq $PrimaryNode.Split('.')[0] }
        if ($finalPrimary -and $finalPrimary.Role -eq "PRIMARY") {
            Write-Step "$PrimaryNode est bien revenu PRIMARY" "OK"
        } else {
            Write-Step "$PrimaryNode n'est PAS PRIMARY (état: $($finalPrimary.Role))" "ERROR"
            $script:Errors += "État final incorrect : $PrimaryNode n'est pas PRIMARY"
        }

        # Vérifier les bases finales
        Write-Host ""
        Write-Host "  État final des bases sur $SecondaryNode :" -ForegroundColor Cyan
        $finalDbs = Get-AGDatabaseState -ServerInstance $SecondaryNode -AGName $AvailabilityGroupName
        $finalSynced = ($finalDbs | Where-Object { $_.SyncState -eq "SYNCHRONIZED" }).Count
        Write-Step "Bases SYNCHRONIZED : $finalSynced / $($Databases.Count)" "OK"

        if ($finalSynced -ne $Databases.Count) {
            Write-Step "Certaines bases ne sont PAS synchronisées" "WARN"
            $script:Warnings += "Certaines bases ne sont pas synchronisées après test"
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  AG Name          : $AvailabilityGroupName" -ForegroundColor Cyan
    Write-Host "  Primary Node     : $PrimaryNode" -ForegroundColor Cyan
    Write-Host "  Secondary Node   : $SecondaryNode" -ForegroundColor Cyan
    Write-Host "  Failover testé   : $(if ($script:FailoverPerformed) { 'OUI' } else { 'NON (WhatIf ou erreur)' })" -ForegroundColor $(if ($script:FailoverPerformed) { 'Green' } else { 'Yellow' })
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

    Write-Host "  ✅ Test de failover TDE terminé avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  📌 Prochaine étape : 7.2.0 (création des jobs SQL Agent)" -ForegroundColor Yellow
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

    # Tentative de rebascule en cas d'erreur après bascule
    if ($script:FailoverPerformed -and -not $WhatIfPreference) {
        Write-Section "Tentative de rebascule d'urgence"
        try {
            Start-Sleep -Seconds 10
            Switch-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$($PrimaryNode.Split('.')[0])\DEFAULT\AvailabilityGroups\$AvailabilityGroupName" -ErrorAction Stop
            Write-Step "Rebascule d'urgence vers $PrimaryNode effectuée" "OK"
        } catch {
            Write-Step "Échec de la rebascule d'urgence : $($_.Exception.Message)" "ERROR"
        }
    }

    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}