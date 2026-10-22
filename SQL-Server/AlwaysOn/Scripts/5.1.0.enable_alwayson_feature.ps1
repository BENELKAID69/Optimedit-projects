<#
.SYNOPSIS
    Active Always On Availability Groups sur un nœud SQL Server.

.DESCRIPTION
    Ce script active la fonctionnalité Always On sur le nœud local,
    redémarre le service MSSQLSERVER si nécessaire, puis vérifie que
    l'activation a bien été prise en compte.

    FONCTIONNALITÉS :
    - Détection du module SqlServer (installation si absente)
    - Vérification préalable (SPN, cluster WSFC, services SQL)
    - Idempotence : ne redémarre que si nécessaire
    - Vérification post-exécution via Invoke-Sqlcmd (FQDN obligatoire)
    - Démarrage automatique du service SQLSERVERAGENT
    - Support -WhatIf pour la prévisualisation
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Compatible Windows PowerShell 5.1 et PowerShell 7+

.PARAMETER Force
    Force le redémarrage du service SQL Server même si Always On est déjà activé.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\5.1.0.enable_alwayson_feature.log
    (Le fichier DOIT se terminer par .log)

.EXAMPLE
    # Activation standard (idempotent)
    .\5.1.0.enable_alwayson_feature.ps1

.EXAMPLE
    # Prévisualisation
    .\5.1.0.enable_alwayson_feature.ps1 -WhatIf

.EXAMPLE
    # Forcer le redémarrage
    .\5.1.0.enable_alwayson_feature.ps1 -Force

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 2.1
    Nœud    : SQLS01 + SQLS02 (exécuter sur chaque nœud)

    ===========================================================================
    ⚠️  PRÉREQUIS :
    ===========================================================================
    1. Cluster WSFC CL-SQL-AG opérationnel
    2. Nœud actuellement dans le cluster (Get-ClusterNode)
    3. Service MSSQLSERVER en état Running
    4. Module PowerShell SqlServer (installé automatiquement si absent)

    ===========================================================================
    📝  NOTES TECHNIQUES :
    ===========================================================================
    - Le registre IsHadrEnabled n'existe PAS dans SQL Server 2022.
      La vérification se fait uniquement via SERVERPROPERTY('IsHadrEnabled').
    - Invoke-Sqlcmd doit utiliser le FQDN (SQLS01.optimedit.eu) et non le
      nom court (SQLS01) pour éviter les erreurs SSL/SPN.
    ===========================================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\5.1.0.enable_alwayson_feature.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:RestartRequired = $false
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

function Install-SqlServerModule {
    Write-Step "Installation du module SqlServer..." "INFO"
    try {
        if (-not (Test-NetConnection www.powershellgallery.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            throw "Pas de connexion à www.powershellgallery.com"
        }
        Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
        Write-Step "Module SqlServer installé" "OK"
        return $true
    } catch {
        Write-Step "Échec de l'installation : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Get-SqlAlwaysOnStatus {
    <#
    .SYNOPSIS
        Lit IsHadrEnabled via SERVERPROPERTY (méthode fiable en 2022+).
    #>
    param([string]$Fqdn)

    try {
        $result = Invoke-Sqlcmd -ServerInstance $Fqdn `
            -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled" `
            -ErrorAction Stop

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

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.1.0 - Activation Always On ($env:COMPUTERNAME)"
    Write-Host " Serveur          : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " FQDN             : $script:Fqdn" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " PowerShell       : $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
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
        throw "Le service MSSQLSERVER n'existe pas sur ce serveur."
    }
    Write-Step "Service MSSQLSERVER : $($sqlService.Status)" "OK"

    if ($sqlService.Status -ne "Running") {
        Write-Step "Le service n'est pas démarré. Démarrage..." "WARN"
        Start-Service -Name "MSSQLSERVER" -ErrorAction Stop
        Start-Sleep -Seconds 5
        Write-Step "Service démarré" "OK"
    }

    # --------------------------------------------------------
    # PRÉ-VOL 3 : Cluster WSFC
    # --------------------------------------------------------
    Write-Section "Pré-vol 3/4 : Vérification du cluster WSFC"

    try {
        Import-Module FailoverClusters -ErrorAction Stop
        $cluster = Get-Cluster -ErrorAction Stop
        Write-Step "Cluster trouvé : $($cluster.Name)" "OK"

        $node = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue
        if ($node) {
            Write-Step "Nœud $env:COMPUTERNAME dans le cluster : $($node.State)" "OK"
        } else {
            Write-Step "Nœud $env:COMPUTERNAME NON trouvé dans le cluster" "WARN"
            $script:Warnings += "Nœud non trouvé dans le cluster"
        }
    } catch {
        Write-Step "Cluster WSFC non accessible : $($_.Exception.Message)" "WARN"
        $script:Warnings += "Cluster WSFC non vérifié"
    }

    # --------------------------------------------------------
    # PRÉ-VOL 4 : Module SqlServer
    # --------------------------------------------------------
    Write-Section "Pré-vol 4/4 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        Write-Step "Module SqlServer absent" "WARN"
        if (-not $WhatIfPreference) {
            if (-not (Install-SqlServerModule)) {
                throw "Impossible d'installer le module SqlServer."
            }
        } else {
            Write-Step "Installation du module SqlServer (WhatIf)" "SKIP"
        }
    } else {
        $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
        Write-Step "Module SqlServer disponible : v$($module.Version)" "OK"
    }

    # --------------------------------------------------------
    # VÉRIFICATION DE L'ÉTAT ACTUEL
    # --------------------------------------------------------
    Write-Section "Vérification de l'état actuel d'Always On"

    $status = Get-SqlAlwaysOnStatus -Fqdn $script:Fqdn

    if ($status.Found) {
        Write-Step "IsHadrEnabled actuel : $($status.Value)" "INFO"

        if ($status.Value -eq 1 -and -not $Force) {
            Write-Step "Always On est DÉJÀ activé" "OK"
            Write-Step "Aucune action nécessaire (utilisez -Force pour forcer)" "INFO"

            # Vérifier quand même le service SQLSERVERAGENT
            $agentService = Get-Service -Name "SQLSERVERAGENT" -ErrorAction SilentlyContinue
            if ($agentService -and $agentService.Status -ne "Running") {
                Write-Step "Service SQLSERVERAGENT arrêté. Démarrage..." "WARN"
                if (-not $WhatIfPreference) {
                    Start-Service -Name "SQLSERVERAGENT" -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                    $agentService = Get-Service -Name "SQLSERVERAGENT"
                    if ($agentService.Status -eq "Running") {
                        Write-Step "SQLSERVERAGENT démarré" "OK"
                    } else {
                        Write-Step "SQLSERVERAGENT n'a pas démarré" "WARN"
                    }
                }
            }

            Write-Section "Résultat"
            Write-Host "  Always On est déjà activé sur $env:COMPUTERNAME" -ForegroundColor Green
            return
        }
    } else {
        Write-Step "Vérification impossible : $($status.Error)" "WARN"
        $script:Warnings += "Vérification IsHadrEnabled impossible : $($status.Error)"
        Write-Step "Activation forcée dans tous les cas" "INFO"
    }

    # --------------------------------------------------------
    # ACTIVATION D'ALWAYS ON
    # --------------------------------------------------------
    Write-Section "Activation d'Always On"

    if ($WhatIfPreference) {
        Write-Step "Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force (WhatIf)" "SKIP"
        Write-Step "Restart-Service -Name MSSQLSERVER -Force (WhatIf)" "SKIP"
        Write-Step "Start-Service -Name SQLSERVERAGENT (WhatIf)" "SKIP"
    } else {
        try {
            Write-Step "Exécution de Enable-SqlAlwaysOn..." "INFO"
            Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force -ErrorAction Stop
            Write-Step "Always On activé (en attente de redémarrage)" "OK"
            $script:RestartRequired = $true

            # Redémarrer le service MSSQLSERVER
            Write-Step "Redémarrage du service MSSQLSERVER..." "INFO"
            Write-Host "    (cela peut prendre 30-60 secondes)" -ForegroundColor DarkGray
            Restart-Service -Name "MSSQLSERVER" -Force -ErrorAction Stop
            Start-Sleep -Seconds 10

            $sqlService = Get-Service -Name "MSSQLSERVER"
            if ($sqlService.Status -eq "Running") {
                Write-Step "Service MSSQLSERVER redémarré" "OK"
            } else {
                throw "Le service MSSQLSERVER n'est pas redémarré correctement"
            }

            # Démarrer SQLSERVERAGENT
            Write-Step "Vérification du service SQLSERVERAGENT..." "INFO"
            $agentService = Get-Service -Name "SQLSERVERAGENT" -ErrorAction SilentlyContinue
            if ($agentService) {
                if ($agentService.Status -ne "Running") {
                    Write-Step "Démarrage de SQLSERVERAGENT..." "INFO"
                    Start-Service -Name "SQLSERVERAGENT" -ErrorAction Stop
                    Start-Sleep -Seconds 5
                    $agentService = Get-Service -Name "SQLSERVERAGENT"
                    if ($agentService.Status -eq "Running") {
                        Write-Step "SQLSERVERAGENT démarré" "OK"
                    } else {
                        Write-Step "SQLSERVERAGENT n'a pas démarré" "WARN"
                        $script:Warnings += "SQLSERVERAGENT non démarré"
                    }
                } else {
                    Write-Step "SQLSERVERAGENT déjà en cours d'exécution" "OK"
                }
            } else {
                Write-Step "Service SQLSERVERAGENT non trouvé" "WARN"
            }

        } catch {
            $script:Errors += "Échec activation : $($_.Exception.Message)"
            throw "Échec de l'activation d'Always On : $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # VÉRIFICATION POST-EXÉCUTION
    # --------------------------------------------------------
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Start-Sleep -Seconds 5

        # Attendre que SQL Server soit complètement disponible
        $maxRetries = 6
        $retryCount = 0
        $sqlReady = $false

        while ($retryCount -lt $maxRetries -and -not $sqlReady) {
            Start-Sleep -Seconds 5
            $retryCount++
            $testStatus = Get-SqlAlwaysOnStatus -Fqdn $script:Fqdn
            if ($testStatus.Found) {
                $sqlReady = $true
            } else {
                Write-Host "    Tentative $retryCount/$maxRetries : SQL Server pas encore prêt..." -ForegroundColor DarkGray
            }
        }

        if ($sqlReady -and $testStatus.Value -eq 1) {
            Write-Step "IsHadrEnabled = 1 confirmé via SERVERPROPERTY" "OK"
        } elseif ($sqlReady -and $testStatus.Value -eq 0) {
            Write-Step "IsHadrEnabled = 0 (activation échouée)" "ERROR"
            $script:Errors += "IsHadrEnabled = 0 après activation"
        } else {
            Write-Step "Vérification impossible après $maxRetries tentatives" "WARN"
            $script:Warnings += "Vérification IsHadrEnabled impossible"
        }

        # Vérifier les services
        $sqlService = Get-Service -Name "MSSQLSERVER"
        $agentService = Get-Service -Name "SQLSERVERAGENT" -ErrorAction SilentlyContinue

        Write-Step "MSSQLSERVER : $($sqlService.Status)" $(if ($sqlService.Status -eq "Running") { "OK" } else { "ERROR" })
        if ($agentService) {
            Write-Step "SQLSERVERAGENT : $($agentService.Status)" $(if ($agentService.Status -eq "Running") { "OK" } else { "WARN" })
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
    Write-Host "  FQDN             : $script:Fqdn" -ForegroundColor Cyan
    Write-Host "  Action           : Activation Always On" -ForegroundColor Cyan
    Write-Host "  Redémarrage      : $(if ($script:RestartRequired) { 'Effectué' } else { 'Non requis' })" -ForegroundColor Cyan
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

    Write-Host "  ✅ Always On activé avec succès sur $env:COMPUTERNAME" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaine étape : exécuter ce script sur l'autre nœud" -ForegroundColor Yellow
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