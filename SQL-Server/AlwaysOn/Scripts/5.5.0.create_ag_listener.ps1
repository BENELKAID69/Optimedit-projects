<#
.SYNOPSIS
    Crée le Listener de l'Availability Group AG-OPTIMEDIT.

.DESCRIPTION
    Ce script :
    1. Crée le Listener SQL-AG-LSTNR avec l'IP 192.168.1.250 et le port 1433
    2. Vérifie que les SPN nécessaires existent sur SVC_SQL_Engine
    3. Vérifie la résolution DNS du Listener
    4. Vérifie la création du VCO dans AD

    ⚠️ IMPORTANT : Les SPN MSSQLSvc/SQL-AG-LSTNR* DOIVENT être enregistrés
    sur le compte de service SVC_SQL_Engine (PAS sur le CNO CL-SQL-AG$).
    C'est le rôle du script 5.0.0.manage_sql_spn.ps1.

    FONCTIONNALITÉS :
    - Vérification préalable (AG existe, primary AG, IP libre, SPN présents)
    - Création du Listener
    - Vérification post-exécution via 4 méthodes :
      * sys.availability_group_listeners
      * Get-ClusterGroup
      * Get-ADComputer
      * Résolution DNS
    - Idempotence, -WhatIf, logging

.PARAMETER AGName
    Nom de l'Availability Group. Défaut : AG-OPTIMEDIT

.PARAMETER ListenerName
    Nom du Listener. Défaut : SQL-AG-LSTNR

.PARAMETER ListenerIP
    Adresse IP virtuelle du Listener. Défaut : 192.168.1.250

.PARAMETER ListenerPort
    Port TCP. Défaut : 1433

.PARAMETER SubnetMask
    Masque de sous-réseau. Défaut : 255.255.255.0

.PARAMETER ServiceAccount
    Compte de service SQL Server qui doit porter les SPN.
    Défaut : optimedit\SVC_SQL_Engine

.PARAMETER SkipSpnCheck
    Ignore la vérification des SPN.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\5.5.0.create_ag_listener.log

.EXAMPLE
    .\5.5.0.create_ag_listener.ps1 -WhatIf
    .\5.5.0.create_ag_listener.ps1

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.2
    Nœud    : À exécuter sur le PRIMARY AG

    ===========================================================================
    ⚠️  PRÉREQUIS :
    ===========================================================================
    1. AG-OPTIMEDIT créé (5.3)
    2. SQLS02 joint à l'AG (5.4)
    3. SPN MSSQLSvc/SQL-AG-LSTNR* créés sur SVC_SQL_Engine (5.0.0)
    4. IP 192.168.1.250 libre
    5. DNS opérationnel
    6. Exécution sur le PRIMARY AG (pas le secondary)

    ===========================================================================
    📝  CORRECTIONS v1.2 :
    ===========================================================================
    - Fix : Test-ListenerExists utilise LIKE pour matcher
      'SQL-AG-LSTNR' ET 'SQL-AG-LSTNR.optimedit.eu'
    - Ajout : Vérification via Get-ClusterGroup
    - Ajout : Vérification de l'objet AD (Get-ADComputer)
    - Ajout : Vérification du primary AG via Get-ClusterGroup
    ===========================================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AGName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ListenerName = "SQL-AG-LSTNR",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ListenerIP = "192.168.1.250",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1024, 65535)]
    [int]$ListenerPort = 1433,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SubnetMask = "255.255.255.0",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceAccount = "optimedit\SVC_SQL_Engine",

    [Parameter(Mandatory = $false)]
    [switch]$SkipSpnCheck,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\5.5.0.create_ag_listener.log"
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
        [Parameter(Mandatory = $false)] [string]$ServerInstance = $script:Fqdn
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $Query -ErrorAction Stop
}

function Test-ListenerExists {
    <#
    .SYNOPSIS
        Vérifie si le Listener existe (correction v1.2 : utilise LIKE).
    #>
    param([string]$ListenerName)
    try {
        # Utiliser LIKE pour matcher 'SQL-AG-LSTNR' ET 'SQL-AG-LSTNR.optimedit.eu'
        $result = Invoke-SqlQuery -Query @"
SELECT COUNT(*) AS ListenerCount
FROM sys.availability_group_listeners
WHERE dns_name = '$ListenerName'
   OR dns_name = '$ListenerName.$($script:Domain)'
   OR dns_name LIKE '$ListenerName%'
"@
        return ($result.ListenerCount -gt 0)
    } catch {
        return $false
    }
}

function Get-ListenerInfo {
    param([string]$ListenerName)
    try {
        $result = Invoke-SqlQuery -Query @"
SELECT 
    agl.dns_name AS ListenerName,
    agl.port AS Port,
    agl.is_conformant AS IsConformant,
    aglip.ip_address AS IPAddress,
    aglip.state_desc AS IPState
FROM sys.availability_group_listeners agl
LEFT JOIN sys.availability_group_listener_ip_addresses aglip 
    ON agl.listener_id = aglip.listener_id
WHERE agl.dns_name = '$ListenerName'
   OR agl.dns_name = '$ListenerName.$($script:Domain)'
   OR agl.dns_name LIKE '$ListenerName%'
"@
        return $result
    } catch {
        return $null
    }
}

function Test-IpFree {
    param([string]$IP)
    try {
        $pings = Test-Connection -ComputerName $IP -Count 2 -Quiet -ErrorAction SilentlyContinue
        return (-not $pings)
    } catch {
        return $true
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

function Test-SpnExists {
    param(
        [string]$SPN,
        [string]$ExpectedAccount
    )
    try {
        $output = & setspn.exe -Q $SPN 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            return "Absent"
        }

        $fullText = ($output -join "`n")
        if ($fullText -match "Aucun SPN identique|No matching SPN|not found|introuvable") {
            return "Absent"
        }

        $cnMatch = $output | Where-Object { $_ -match "^CN=" } | Select-Object -First 1
        if ($cnMatch -and $cnMatch -match "CN=([^,]+)") {
            $owner = $Matches[1]
            $expectedShort = $ExpectedAccount.Split('\')[-1]
            if ($owner -like "*$expectedShort*") {
                return "Exists"
            } else {
                return "WrongOwner"
            }
        }
        return "Absent"
    } catch {
        return "Absent"
    }
}

function Get-PrimaryAG {
    <#
    .SYNOPSIS
        Détecte le primary AG via Get-ClusterGroup.
    #>
    param([string]$AGName)
    try {
        Import-Module FailoverClusters -ErrorAction Stop
        $group = Get-ClusterGroup -Name $AGName -ErrorAction Stop
        return $group.OwnerNode.Name
    } catch {
        return $null
    }
}

function Test-ClusterGroupExists {
    param([string]$AGName)
    try {
        Import-Module FailoverClusters -ErrorAction SilentlyContinue
        $group = Get-ClusterGroup -Name $AGName -ErrorAction SilentlyContinue
        return ($null -ne $group)
    } catch {
        return $false
    }
}

function Test-ADComputerExists {
    param([string]$ComputerName)
    try {
        $computer = Get-ADComputer -Identity $ComputerName -ErrorAction Stop
        return [PSCustomObject]@{
            Exists = $true
            Name   = $computer.Name
            DN     = $computer.DistinguishedName
            Created = $computer.Created
        }
    } catch {
        return [PSCustomObject]@{
            Exists = $false
            Name   = ""
            DN     = ""
            Created = $null
        }
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.5.0 - Création du Listener ($ListenerName) - v1.2"
    Write-Host " Serveur local    : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " FQDN             : $script:Fqdn" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " AG Name          : $AGName" -ForegroundColor Gray
    Write-Host " Listener Name    : $ListenerName" -ForegroundColor Gray
    Write-Host " Listener IP      : $ListenerIP" -ForegroundColor Gray
    Write-Host " Listener Port    : $ListenerPort" -ForegroundColor Gray
    Write-Host " Service Account  : $ServiceAccount" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Privilèges ---
    Write-Section "Pré-vol 1/6 : Vérification des privilèges"

    if (-not (Test-IsAdministrator)) {
        throw "Ce script doit être exécuté en tant qu'administrateur."
    }
    Write-Step "Privilèges administrateur confirmés" "OK"

    # --- PRÉ-VOL 2 : Module SqlServer ---
    Write-Section "Pré-vol 2/6 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible."
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # --- PRÉ-VOL 3 : Vérifier que l'AG existe et le primary AG ---
    Write-Section "Pré-vol 3/6 : Vérification de l'AG et du primary AG"

    # Vérifier que l'AG existe
    $agQuery = @"
SELECT COUNT(*) AS AGCount
FROM sys.availability_groups
WHERE name = '$AGName'
"@
    $agResult = Invoke-SqlQuery -Query $agQuery

    if ($agResult.AGCount -eq 0) {
        throw "L'AG '$AGName' n'existe pas sur ce nœud."
    }
    Write-Step "AG '$AGName' trouvé" "OK"

    # Vérifier que l'AG est un groupe de cluster
    if (-not (Test-ClusterGroupExists -AGName $AGName)) {
        throw "Le groupe de cluster '$AGName' n'existe pas."
    }
    Write-Step "Groupe de cluster '$AGName' trouvé" "OK"

    # Détecter le primary AG
    $primaryAG = Get-PrimaryAG -AGName $AGName
    if (-not $primaryAG) {
        throw "Impossible de détecter le primary AG pour '$AGName'."
    }
    Write-Step "Primary AG détecté : $primaryAG" "OK"

    # Vérifier que le script est exécuté sur le primary AG
    if ($env:COMPUTERNAME -ne $primaryAG) {
        Write-Step "Ce script doit être exécuté sur le primary AG ($primaryAG)" "ERROR"
        Write-Step "Actuellement sur : $env:COMPUTERNAME" "ERROR"
        Write-Host ""
        Write-Host "  Exécutez ce script sur $primaryAG" -ForegroundColor Yellow
        Write-Host ""
        throw "Mauvais nœud pour ADD LISTENER."
    }
    Write-Step "Exécution sur le primary AG : $env:COMPUTERNAME" "OK"

    # Vérifier les replicas
    $replicaQuery = @"
SELECT 
    ar.replica_server_name AS Replica,
    ars.connected_state_desc AS ConnectedState,
    ars.role_desc AS Role
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AGName'
"@
    $replicas = Invoke-SqlQuery -Query $replicaQuery

    $allConnected = $true
    foreach ($r in $replicas) {
        if ($r.ConnectedState -eq "CONNECTED") {
            Write-Step "  $($r.Replica) : $($r.Role) / $($r.ConnectedState)" "OK"
        } else {
            Write-Step "  $($r.Replica) : $($r.Role) / $($r.ConnectedState)" "WARN"
            $allConnected = $false
        }
    }

    if (-not $allConnected) {
        Write-Step "Tous les replicas ne sont pas connectés" "WARN"
        $script:Warnings += "Replicas non tous connectés"
    }

    # --- PRÉ-VOL 4 : Vérifier que l'IP est libre ---
    Write-Section "Pré-vol 4/6 : Vérification de l'IP $ListenerIP"

    if (Test-IpFree -IP $ListenerIP) {
        Write-Step "IP $ListenerIP disponible (pas de réponse au ping)" "OK"
    } else {
        Write-Step "IP $ListenerIP répond au ping (peut être utilisée)" "WARN"
        $script:Warnings += "IP $ListenerIP répond au ping"
    }

    # --- PRÉ-VOL 5 : Vérifier les SPN ---
    Write-Section "Pré-vol 5/6 : Vérification des SPN du Listener"

    if ($SkipSpnCheck) {
        Write-Step "Vérification des SPN ignorée (-SkipSpnCheck)" "SKIP"
    } else {
        Write-Host ""
        Write-Host "  Vérification que les SPN du Listener sont créés sur $ServiceAccount" -ForegroundColor Cyan
        Write-Host "  (créés au préalable par 5.0.0.manage_sql_spn.ps1)" -ForegroundColor DarkGray
        Write-Host ""

        $spnList = @(
            "MSSQLSvc/$ListenerName.$($script:Domain):$ListenerPort",
            "MSSQLSvc/$ListenerName.$($script:Domain)",
            "MSSQLSvc/$ListenerName`:$ListenerPort",
            "MSSQLSvc/$ListenerName"
        )

        $missingSpn = @()
        foreach ($spn in $spnList) {
            $status = Test-SpnExists -SPN $spn -ExpectedAccount $ServiceAccount
            switch ($status) {
                "Exists"     { Write-Step "  $spn : présent sur $ServiceAccount" "OK" }
                "WrongOwner" { Write-Step "  $spn : présent sur un AUTRE compte" "WARN"; $script:Warnings += "SPN $spn sur mauvais compte" }
                "Absent"     { Write-Step "  $spn : ABSENT" "WARN"; $missingSpn += $spn }
                default      { Write-Step "  $spn : $status" "WARN" }
            }
        }

        if ($missingSpn.Count -gt 0) {
            Write-Host ""
            Write-Step "$($missingSpn.Count) SPN manquant(s)" "WARN"
            Write-Step "Exécutez d'abord : .\5.0.0.manage_sql_spn.ps1" "INFO"
            Write-Host ""
            Write-Host "  Les connexions via le Listener risquent de basculer en NTLM." -ForegroundColor Yellow
            Write-Host ""
        } else {
            Write-Step "Tous les SPN du Listener sont présents sur $ServiceAccount" "OK"
        }
    }

    # --- PRÉ-VOL 6 : Vérifier l'existence du Listener ---
    Write-Section "Pré-vol 6/6 : Vérification de l'existence du Listener"

    if (Test-ListenerExists -ListenerName $ListenerName) {
        Write-Step "Le Listener '$ListenerName' existe déjà" "OK"
        $listenerInfo = Get-ListenerInfo -ListenerName $ListenerName

        Write-Host ""
        Write-Host "  Détails du Listener existant :" -ForegroundColor Cyan
        Write-Host "    Nom         : $($listenerInfo.ListenerName)" -ForegroundColor Gray
        Write-Host "    Port        : $($listenerInfo.Port)" -ForegroundColor Gray
        Write-Host "    IP          : $($listenerInfo.IPAddress)" -ForegroundColor Gray
        Write-Host "    IP State    : $($listenerInfo.IPState)" -ForegroundColor Gray
        Write-Host "    Conformant  : $($listenerInfo.IsConformant)" -ForegroundColor Gray
        Write-Host ""

        Write-Section "Résumé"
        Write-Host "  Listener '$ListenerName' déjà présent" -ForegroundColor Green
        return
    }

    Write-Step "Le Listener '$ListenerName' n'existe pas - création nécessaire" "INFO"

    # --- CRÉATION DU LISTENER ---
    Write-Section "Création du Listener"

    $createListenerQuery = @"
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER '$ListenerName'
(
    WITH IP (('$ListenerIP','$SubnetMask')),
    PORT = $ListenerPort
);
"@

    if ($WhatIfPreference) {
        Write-Host ""
        Write-Host "  Requête SQL qui serait exécutée :" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
        $createListenerQuery -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        Write-Step "CREATE LISTENER '$ListenerName' ... (WhatIf)" "SKIP"
    } else {
        Write-Step "Création du Listener '$ListenerName'..." "INFO"
        try {
            Invoke-SqlQuery -Query $createListenerQuery | Out-Null
            Write-Step "Listener '$ListenerName' créé" "OK"
        } catch {
            throw "Échec de création du Listener : $($_.Exception.Message)"
        }

        Write-Step "Attente de la création du VCO dans AD (15 sec)..." "INFO"
        Start-Sleep -Seconds 15
    }

    # --- VÉRIFICATION POST-EXÉCUTION (4 MÉTHODES) ---
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Start-Sleep -Seconds 5

        # Méthode 1 : sys.availability_group_listeners
        Write-Host ""
        Write-Host "  Méthode 1 : sys.availability_group_listeners" -ForegroundColor Cyan
        if (Test-ListenerExists -ListenerName $ListenerName) {
            Write-Step "Listener trouvé dans SQL Server" "OK"
            $listenerInfo = Get-ListenerInfo -ListenerName $ListenerName
            Write-Host "    Nom         : $($listenerInfo.ListenerName)" -ForegroundColor Gray
            Write-Host "    Port        : $($listenerInfo.Port)" -ForegroundColor Gray
            Write-Host "    IP          : $($listenerInfo.IPAddress)" -ForegroundColor Gray
            Write-Host "    IP State    : $($listenerInfo.IPState)" -ForegroundColor Gray
            Write-Host "    Conformant  : $($listenerInfo.IsConformant)" -ForegroundColor Gray
        } else {
            Write-Step "Listener NON trouvé dans SQL Server" "ERROR"
            $script:Errors += "Listener non trouvé dans sys.availability_group_listeners"
        }

        # Méthode 2 : Get-ClusterGroup
        Write-Host ""
        Write-Host "  Méthode 2 : Get-ClusterGroup" -ForegroundColor Cyan
        try {
            Import-Module FailoverClusters -ErrorAction SilentlyContinue
            $groups = Get-ClusterGroup | Where-Object { $_.Name -like "*$ListenerName*" -or $_.Name -like "*$AGName*" }
            if ($groups) {
                foreach ($g in $groups) {
                    Write-Step "Groupe trouvé : $($g.Name) / $($g.State) / $($g.OwnerNode)" "OK"
                }
            } else {
                Write-Step "Aucun groupe trouvé" "WARN"
            }
        } catch {
            Write-Step "Impossible d'interroger le cluster : $($_.Exception.Message)" "WARN"
        }

        # Méthode 3 : Get-ADComputer
        Write-Host ""
        Write-Host "  Méthode 3 : Objet AD (Get-ADComputer)" -ForegroundColor Cyan
        $adResult = Test-ADComputerExists -ComputerName $ListenerName
        if ($adResult.Exists) {
            Write-Step "Objet AD trouvé : $($adResult.Name)" "OK"
            Write-Host "    DN      : $($adResult.DN)" -ForegroundColor Gray
            Write-Host "    Créé le : $($adResult.Created)" -ForegroundColor Gray
        } else {
            Write-Step "Objet AD NON trouvé (peut prendre quelques minutes)" "WARN"
            $script:Warnings += "Objet AD $ListenerName non trouvé immédiatement"
        }

        # Méthode 4 : DNS
        Write-Host ""
        Write-Host "  Méthode 4 : Résolution DNS" -ForegroundColor Cyan
        $dnsName = "$ListenerName.$($script:Domain)"
        if (Test-DnsResolution -Hostname $dnsName) {
            $dnsResult = Resolve-DnsName -Name $dnsName -Type A -ErrorAction SilentlyContinue | 
                Where-Object { $_.IPAddress } | Select-Object -First 1
            Write-Step "DNS résout : $dnsName -> $($dnsResult.IPAddress)" "OK"
        } else {
            Write-Step "DNS ne résout PAS : $dnsName" "WARN"
            Write-Step "  (Normal immédiatement - peut prendre quelques minutes)" "INFO"
            $script:Warnings += "DNS non résolu immédiatement"
        }

        # Méthode 5 : Test de connexion SQL
        Write-Host ""
        Write-Host "  Méthode 5 : Test de connexion SQL via le Listener" -ForegroundColor Cyan
        try {
            $testQuery = Invoke-SqlQuery -ServerInstance $dnsName -Query "SELECT @@SERVERNAME AS ServerName"
            if ($testQuery) {
                Write-Step "Connexion SQL réussie : @@SERVERNAME = $($testQuery.ServerName)" "OK"
            }
        } catch {
            Write-Step "Connexion SQL échouée (peut être normal immédiatement) : $($_.Exception.Message)" "WARN"
            $script:Warnings += "Connexion SQL via Listener non testée immédiatement"
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Serveur          : $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "  AG               : $AGName" -ForegroundColor Cyan
    Write-Host "  Primary AG       : $primaryAG" -ForegroundColor Cyan
    Write-Host "  Listener         : $ListenerName" -ForegroundColor Cyan
    Write-Host "  IP               : $ListenerIP" -ForegroundColor Cyan
    Write-Host "  Port             : $ListenerPort" -ForegroundColor Cyan
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

    Write-Host "  ✅ Listener '$ListenerName' créé avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaines étapes :" -ForegroundColor Yellow
    Write-Host "    1. Attendre 1-2 min pour la réplication AD/DNS" -ForegroundColor Gray
    Write-Host "    2. Tester : sqlcmd -S $ListenerName.$($script:Domain) -E" -ForegroundColor Gray
    Write-Host "    3. Passer à 5.6 (test failover)" -ForegroundColor Gray
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