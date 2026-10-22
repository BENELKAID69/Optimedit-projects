<#
.SYNOPSIS
    Rejoint l'Availability Group AG-OPTIMEDIT depuis le replica secondaire.

.DESCRIPTION
    Ce script exécute sur le replica SECONDARY de l'AG :
    1. Détecte le primary AG (via sys.dm_hadr_availability_group_states sur SQLS01)
    2. Vérifie que le nœud local est bien le SECONDARY (pas le PRIMARY)
    3. Exécute ALTER AVAILABILITY GROUP [AG-OPTIMEDIT] JOIN
    4. Exécute ALTER AVAILABILITY GROUP [AG-OPTIMEDIT] GRANT CREATE ANY DATABASE
    5. Vérifie que le JOIN a réussi

    ⚠️ IMPORTANT : Avant le JOIN, l'AG n'apparaît PAS dans sys.availability_groups
    sur le secondary. C'est NORMAL. Le script vérifie donc l'existence de l'AG
    sur le PRIMARY, pas localement.

.PARAMETER AGName
    Nom de l'Availability Group. Défaut : AG-OPTIMEDIT

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\5.4.0.join_availability_group_secondary.log

.EXAMPLE
    .\5.4.0.join_availability_group_secondary.ps1 -WhatIf
    .\5.4.0.join_availability_group_secondary.ps1

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.2
    Nœud    : À exécuter sur le replica SECONDARY de l'AG
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AGName = "AG-OPTIMEDIT",

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\5.4.0.join_availability_group_secondary.log"
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
        [Parameter(Mandatory = $false)] [string]$ServerInstance = $script:Fqdn,
        [Parameter(Mandatory = $false)] [string]$Database = "master"
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $Query -ErrorAction Stop
}

function Get-PrimaryAG {
    <#
    .SYNOPSIS
        Détecte le primary AG en interrogeant TOUS les nœuds du cluster.
    .DESCRIPTION
        Cherche dans l'ordre : le nœud local, puis les autres nœuds.
        Le premier qui retourne une valeur valide est le primary AG.
    #>
    param(
        [string]$AGName,
        [string[]]$CandidateNodes
    )

    foreach ($node in $CandidateNodes) {
        try {
            $fqdnNode = "$node.$($script:Domain)"
            $result = Invoke-SqlQuery -ServerInstance $fqdnNode -Query @"
SELECT 
    ags.primary_replica AS PrimaryAG
FROM sys.dm_hadr_availability_group_states ags
JOIN sys.availability_groups ag ON ags.group_id = ag.group_id
WHERE ag.name = '$AGName'
"@
            if ($result -and $result.PrimaryAG) {
                return [PSCustomObject]@{
                    PrimaryAG  = $result.PrimaryAG
                    FoundOn    = $node
                }
            }
        } catch {
            Write-Verbose "Impossible d'interroger $node : $($_.Exception.Message)"
        }
    }
    return $null
}

function Test-LocalReplicaExistsInAG {
    <#
    .SYNOPSIS
        Vérifie que le replica local est bien déclaré dans l'AG (via le primary).
    #>
    param(
        [string]$AGName,
        [string]$PrimaryNode,
        [string]$LocalNode
    )

    try {
        $fqdnPrimary = "$PrimaryNode.$($script:Domain)"
        $result = Invoke-SqlQuery -ServerInstance $fqdnPrimary -Query @"
SELECT COUNT(*) AS ReplicaCount
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AGName'
  AND ar.replica_server_name = '$LocalNode'
"@
        return ($result.ReplicaCount -gt 0)
    } catch {
        return $false
    }
}

function Test-ReplicaJoined {
    param(
        [string]$AGName,
        [string]$PrimaryNode,
        [string]$LocalNode
    )

    try {
        $fqdnPrimary = "$PrimaryNode.$($script:Domain)"
        $result = Invoke-SqlQuery -ServerInstance $fqdnPrimary -Query @"
SELECT 
    ar.replica_server_name AS Replica,
    ars.role_desc AS Role,
    ars.connected_state_desc AS ConnectedState,
    ars.operational_state_desc AS OperationalState
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$AGName'
  AND ar.replica_server_name = '$LocalNode'
"@
        return $result
    } catch {
        return $null
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.4.0 - Joindre l'AG depuis le secondaire ($AGName) - v1.2"
    Write-Host " Serveur local    : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " FQDN             : $script:Fqdn" -ForegroundColor Gray
    Write-Host " Domaine          : $script:Domain" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " AG Name          : $AGName" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Privilèges ---
    Write-Section "Pré-vol 1/5 : Vérification des privilèges"

    if (-not (Test-IsAdministrator)) {
        throw "Ce script doit être exécuté en tant qu'administrateur."
    }
    Write-Step "Privilèges administrateur confirmés" "OK"

    # --- PRÉ-VOL 2 : Module SqlServer ---
    Write-Section "Pré-vol 2/5 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible."
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # --- PRÉ-VOL 3 : Détection du primary AG ---
    Write-Section "Pré-vol 3/5 : Détection du primary AG"

    # Candidats : nœuds probables du cluster
    $candidateNodes = @("SQLS01", "SQLS02") | Where-Object { $_ -ne $env:COMPUTERNAME }
    $candidateNodes = @($env:COMPUTERNAME) + $candidateNodes

    Write-Step "Recherche du primary AG parmi : $($candidateNodes -join ', ')" "INFO"

    $primaryInfo = Get-PrimaryAG -AGName $AGName -CandidateNodes $candidateNodes

    if (-not $primaryInfo) {
        Write-Step "Impossible de trouver le primary AG" "ERROR"
        Write-Host ""
        Write-Host "  Causes possibles :" -ForegroundColor Yellow
        Write-Host "    1. L'AG '$AGName' n'existe sur aucun nœud" -ForegroundColor Gray
        Write-Host "    2. Les nœuds SQL ne sont pas joignables via WinRM/SQL" -ForegroundColor Gray
        Write-Host "    3. Le service SQL Server est arrêté sur un nœud" -ForegroundColor Gray
        throw "Primary AG introuvable."
    }

    Write-Step "Primary AG détecté : $($primaryInfo.PrimaryAG) (trouvé via $($primaryInfo.FoundOn))" "OK"

    # --- PRÉ-VOL 4 : Vérifier que le nœud local est bien le SECONDARY ---
    Write-Section "Pré-vol 4/5 : Vérification du rôle local"

    if ($env:COMPUTERNAME -eq $primaryInfo.PrimaryAG) {
        Write-Step "Ce nœud est le PRIMARY AG ($($primaryInfo.PrimaryAG))" "ERROR"
        Write-Host ""
        Write-Host "  Ce script doit être exécuté sur le SECONDARY (pas le PRIMARY)." -ForegroundColor Yellow
        Write-Host "  Exécutez-le sur l'autre nœud SQL Server du cluster." -ForegroundColor Gray
        throw "Script exécuté sur le PRIMARY AG."
    }

    Write-Step "Ce nœud est un SECONDARY (Primary AG = $($primaryInfo.PrimaryAG))" "OK"

    # --- PRÉ-VOL 5 : Vérifier que le replica local est déclaré dans l'AG ---
    Write-Section "Pré-vol 5/5 : Vérification du replica dans l'AG"

    $replicaExists = Test-LocalReplicaExistsInAG `
        -AGName $AGName `
        -PrimaryNode $primaryInfo.PrimaryAG `
        -LocalNode $env:COMPUTERNAME

    if ($replicaExists) {
        Write-Step "Replica '$env:COMPUTERNAME' est déclaré dans l'AG (vu depuis $($primaryInfo.PrimaryAG))" "OK"
    } else {
        Write-Step "Replica '$env:COMPUTERNAME' n'est PAS déclaré dans l'AG" "ERROR"
        Write-Host ""
        Write-Host "  Vérifiez que 5.3 a bien été exécuté avec ce nœud dans les replicas." -ForegroundColor Yellow
        throw "Replica local non déclaré dans l'AG."
    }

    # --- VÉRIFICATION DE L'ÉTAT ACTUEL ---
    Write-Section "État actuel du replica"

    $currentState = Test-ReplicaJoined `
        -AGName $AGName `
        -PrimaryNode $primaryInfo.PrimaryAG `
        -LocalNode $env:COMPUTERNAME

    if ($currentState) {
        Write-Host ""
        Write-Host "  État du replica local (vu depuis $($primaryInfo.PrimaryAG)) :" -ForegroundColor Cyan
        Write-Host "    Replica          : $($currentState.Replica)" -ForegroundColor Gray
        Write-Host "    Role             : $($currentState.Role)" -ForegroundColor Gray
        Write-Host "    ConnectedState   : $($currentState.ConnectedState)" -ForegroundColor Gray
        Write-Host "    OperationalState : $($currentState.OperationalState)" -ForegroundColor Gray

        if ($currentState.ConnectedState -eq "CONNECTED") {
            Write-Step "Le replica local est DÉJÀ joint" "OK"

            Write-Section "Résumé"
            Write-Host "  Replica '$env:COMPUTERNAME' déjà joint à l'AG '$AGName'" -ForegroundColor Green
            Write-Host "  Aucune action nécessaire." -ForegroundColor Gray
            return
        } else {
            Write-Step "Replica local NON joint - jointure nécessaire" "INFO"
        }
    }

    # --- JOINTURE ---
    Write-Section "Jointure de l'Availability Group"

    $joinQuery = "ALTER AVAILABILITY GROUP [$AGName] JOIN;"
    $grantQuery = "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE;"

    if ($WhatIfPreference) {
        Write-Host ""
        Write-Host "  Requêtes SQL qui seraient exécutées sur $env:COMPUTERNAME :" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  $joinQuery" -ForegroundColor DarkGray
        Write-Host "  $grantQuery" -ForegroundColor DarkGray
        Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        Write-Step "ALTER AVAILABILITY GROUP [$AGName] JOIN (WhatIf)" "SKIP"
        Write-Step "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE (WhatIf)" "SKIP"
    } else {
        # JOIN
        Write-Step "Exécution de ALTER AVAILABILITY GROUP [$AGName] JOIN..." "INFO"
        try {
            Invoke-SqlQuery -Query $joinQuery | Out-Null
            Write-Step "Replica '$env:COMPUTERNAME' joint à l'AG '$AGName'" "OK"
        } catch {
            throw "Échec du JOIN : $($_.Exception.Message)"
        }

        # GRANT CREATE ANY DATABASE
        Write-Step "Exécution de ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE..." "INFO"
        try {
            Invoke-SqlQuery -Query $grantQuery | Out-Null
            Write-Step "GRANT CREATE ANY DATABASE accordé" "OK"
        } catch {
            Write-Step "Échec du GRANT : $($_.Exception.Message)" "WARN"
            $script:Warnings += "GRANT échoué : $($_.Exception.Message)"
        }
    }

    # --- VÉRIFICATION POST-EXÉCUTION ---
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Write-Step "Attente de la synchronisation (15 sec)..." "INFO"
        Start-Sleep -Seconds 15

        $finalState = Test-ReplicaJoined `
            -AGName $AGName `
            -PrimaryNode $primaryInfo.PrimaryAG `
            -LocalNode $env:COMPUTERNAME

        if ($finalState) {
            Write-Host ""
            Write-Host "  État après jointure :" -ForegroundColor Cyan
            Write-Host "    Replica          : $($finalState.Replica)" -ForegroundColor Gray
            Write-Host "    Role             : $($finalState.Role)" -ForegroundColor $(if ($finalState.Role -eq "SECONDARY") { 'Green' } else { 'Yellow' })
            Write-Host "    ConnectedState   : $($finalState.ConnectedState)" -ForegroundColor $(if ($finalState.ConnectedState -eq "CONNECTED") { 'Green' } else { 'Yellow' })
            Write-Host "    OperationalState : $($finalState.OperationalState)" -ForegroundColor Gray

            if ($finalState.ConnectedState -eq "CONNECTED" -and $finalState.Role -eq "SECONDARY") {
                Write-Step "Replica local joint et synchronisé" "OK"
            } elseif ($finalState.ConnectedState -eq "CONNECTED") {
                Write-Step "Replica local joint (rôle : $($finalState.Role))" "OK"
            } else {
                Write-Step "Replica local : $($finalState.ConnectedState)" "WARN"
                $script:Warnings += "État non optimal : $($finalState.ConnectedState)"
            }
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
    Write-Host "  Primary AG       : $($primaryInfo.PrimaryAG)" -ForegroundColor Cyan
    Write-Host "  Action           : Jointure au replica secondaire" -ForegroundColor Cyan
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

    Write-Host "  ✅ Replica '$env:COMPUTERNAME' joint à l'AG '$AGName'" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaine étape : vérifier la synchronisation puis créer le Listener (5.5)" -ForegroundColor Yellow
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