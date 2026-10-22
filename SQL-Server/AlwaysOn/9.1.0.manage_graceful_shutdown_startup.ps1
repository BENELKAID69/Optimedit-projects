<#
.SYNOPSIS
    Orchestre l'arrêt et le démarrage ordonné du PoC Always On.

.DESCRIPTION
    Depuis DC03, ce script gère l'arrêt et le démarrage des serveurs du PoC
    dans un ordre strict, avec confirmation avant chaque arrêt et barre de
    progression visible pendant l'attente de l'extinction.

    ORDRE D'ARRÊT (Inverse du démarrage) :
      1. Frontend (Serveurs IIS + Reverse Proxy) - En premier
      2. Nœud SQL Secondaire (SQLS02)
      3. Nœud SQL Primaire (SQLS01)
      4. Serveur de Fichiers (OPT-FS03)
      5. Contrôleur de domaine (DC03) - EN DERNIER

    ORDRE DE DÉMARRAGE (Délais Hyper-V) :
      1. DC03 (120s)
      2. OPT-FS03 (180s)
      3. SQLS01 (300s)
      4. SQLS02 (600s)
      5. OPT-IIS-01 à 06 (840s)
      6. OPT-RP-01 (900s)

.PARAMETER Action
    OBLIGATOIRE. Action à effectuer : "Stop" ou "Start".

.PARAMETER Force
    Supprime les confirmations interactives. À utiliser avec précaution.

.PARAMETER LogPath
    Chemin du fichier de log. Défaut : .\9.1.0.manage_graceful_shutdown_startup.log

.EXAMPLE
	Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    .\9.1.0.manage_graceful_shutdown_startup.ps1 -Action Stop
    .\9.1.0.manage_graceful_shutdown_startup.ps1 -Action Start
    .\9.1.0.manage_graceful_shutdown_startup.ps1 -Action Stop -Force

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.2
    Nœud    : DC03
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Veuillez spécifier 'Stop' ou 'Start'.")]
    [ValidateSet("Stop", "Start")]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\9.1.0.manage_graceful_shutdown_startup.log"
)

# ============================================================
# CONFIGURATION & DÉLAIS HYPER-V
# ============================================================
$Config = @{
    DC             = "DC03"
    FileServer     = "OPT-FS03"
    SQLPrimary     = "SQLS01"
    SQLSecondary   = "SQLS02"
    ReverseProxy   = "OPT-RP-01"
    IISBackends    = @("OPT-IIS-01", "OPT-IIS-02", "OPT-IIS-03", "OPT-IIS-04", "OPT-IIS-05", "OPT-IIS-06")
    ClusterName    = "CL-SQL-AG"
    ShutdownTimeoutSec = 120
    PollIntervalSec    = 3
}

# Configuration des délais de démarrage automatique (Hyper-V)
$HyperVStartupConfig = @(
    [PSCustomObject]@{ VM = "DC03";      Delay = "120s"; Note = "1. Contrôleur de domaine (AD/DNS)" },
    [PSCustomObject]@{ VM = "OPT-FS03";  Delay = "180s"; Note = "2. Serveur de fichiers (Quorum)" },
    [PSCustomObject]@{ VM = "SQLS01";    Delay = "300s"; Note = "3. Nœud SQL Primaire" },
    [PSCustomObject]@{ VM = "SQLS02";    Delay = "600s"; Note = "4. Nœud SQL Secondaire" },
    [PSCustomObject]@{ VM = "OPT-IIS-01";Delay = "840s"; Note = "5. Web Farm (Backends)" },
    [PSCustomObject]@{ VM = "OPT-IIS-02";Delay = "840s"; Note = "5. Web Farm (Backends)" },
    [PSCustomObject]@{ VM = "OPT-IIS-03";Delay = "840s"; Note = "5. Web Farm (Backends)" },
    [PSCustomObject]@{ VM = "OPT-IIS-04";Delay = "840s"; Note = "5. Web Farm (Backends)" },
    [PSCustomObject]@{ VM = "OPT-IIS-05";Delay = "840s"; Note = "5. Web Farm (Backends)" },
    [PSCustomObject]@{ VM = "OPT-IIS-06";Delay = "840s"; Note = "5. Web Farm (Backends)" },
    [PSCustomObject]@{ VM = "OPT-RP-01"; Delay = "900s"; Note = "6. Reverse Proxy (En dernier)" }
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Results = @()

try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de démarrer la transcription : $($_.Exception.Message)"
}

# ============================================================
# FONCTIONS
# ============================================================
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 75) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 75) -ForegroundColor DarkCyan
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

function Test-ServerOnline {
    param([string]$ComputerName, [int]$TimeoutMs = 2000)
    try {
        return Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction Stop
    } catch {
        return $false
    }
}

function Wait-ServerShutdown {
    param(
        [Parameter(Mandatory = $true)] [string]$ComputerName,
        [int]$TimeoutSec = 120,
        [int]$PollIntervalSec = 3
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        if (-not (Test-ServerOnline -ComputerName $ComputerName)) {
            Write-Progress -Activity "Attente d'arrêt de $ComputerName" -Status "Serveur éteint" -PercentComplete 100
            Start-Sleep -Milliseconds 500
            Write-Progress -Activity "Attente d'arrêt de $ComputerName" -Completed
            return $true
        }

        $percent = [math]::Min(100, [int](($elapsed / $TimeoutSec) * 100))
        Write-Progress -Activity "Attente d'arrêt de $ComputerName" `
            -Status "$elapsed s / $TimeoutSec s - en attente..." `
            -PercentComplete $percent
        Start-Sleep -Seconds $PollIntervalSec
        $elapsed += $PollIntervalSec
    }

    Write-Progress -Activity "Attente d'arrêt de $ComputerName" -Completed
    return $false
}

function Confirm-ServerShutdown {
    param([string]$ComputerName)
    if ($Force) { return $true }
    $answer = Read-Host "  Confirmer l'arrêt de $ComputerName ? (O/N)"
    return ($answer -eq "O" -or $answer -eq "o")
}

function Invoke-ServerShutdown {
    param([string]$ComputerName)
    try {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock { Stop-Computer -Force } -ErrorAction Stop
        return $true
    } catch {
        Write-Verbose "Arrêt de $ComputerName lancé (déconnexion attendue)"
        return $true
    }
}

function Get-ClusterOwnerNode {
    try {
        $owner = (Get-ClusterResource -Name "Nom du cluster" -ErrorAction Stop).OwnerNode.Name
        return $owner
    } catch {
        return $null
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "PoC Always On - Gestion ordonnée ($Action)"
    Write-Host " Exécuté depuis : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " Date           : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode           : $(if ($Force) { 'Forcé (sans confirmation)' } else { 'Interactif (confirmations)' })" -ForegroundColor Gray
    Write-Host " Log            : $LogPath" -ForegroundColor Gray

    # --- Affichage de la configuration Hyper-V ---
    Write-Host ""
    Write-Host "  Plan de démarrage automatique (Hyper-V) :" -ForegroundColor Yellow
    Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
    $HyperVStartupConfig | Format-Table VM, Delay, Note -AutoSize | Out-String | Write-Host -ForegroundColor Gray

    # --------------------------------------------------------
    # ARRÊT (Ordre inverse strict)
    # --------------------------------------------------------
    if ($Action -eq "Stop") {

        Write-Section "Étape 0/5 : Détection du nœud SQL primaire"
        $clusterOwner = Get-ClusterOwnerNode
        if ($clusterOwner -eq "SQLS01") {
            $Config.SQLPrimary = "SQLS01"
            $Config.SQLSecondary = "SQLS02"
        } elseif ($clusterOwner -eq "SQLS02") {
            $Config.SQLPrimary = "SQLS02"
            $Config.SQLSecondary = "SQLS01"
        } else {
            Write-Step "Impossible de déterminer le nœud primaire via le cluster. Utilisation des valeurs par défaut." "WARN"
        }
        Write-Step "Nœud SQL primaire   : $($Config.SQLPrimary)" "OK"
        Write-Step "Nœud SQL secondaire : $($Config.SQLSecondary)" "OK"

        # --- ÉTAPE 1 : Frontend (IIS + RP) ---
        Write-Section "Étape 1/5 : Arrêt du Frontend (Serveurs IIS + Reverse Proxy)"
        
        $frontendToStop = @()
        foreach ($iis in $Config.IISBackends) {
            if (Test-ServerOnline -ComputerName $iis) { $frontendToStop += $iis } else { Write-Step "$iis : déjà éteint" "SKIP" }
        }
        if (Test-ServerOnline -ComputerName $Config.ReverseProxy) { $frontendToStop += $Config.ReverseProxy } else { Write-Step "$($Config.ReverseProxy) : déjà éteint" "SKIP" }

        if ($frontendToStop.Count -gt 0) {
            Write-Step "Serveurs Frontend à arrêter : $($frontendToStop -join ', ')" "INFO"
            foreach ($srv in $frontendToStop) {
                if (Confirm-ServerShutdown -ComputerName $srv) {
                    Write-Step "Arrêt de $srv en cours..." "INFO"
                    Invoke-ServerShutdown -ComputerName $srv | Out-Null
                    $script:Results += [PSCustomObject]@{ Server = $srv; Action = "Stop"; Status = "Lancé" }
                } else {
                    Write-Step "Arrêt de $srv annulé par l'utilisateur" "WARN"
                }
            }
            Write-Step "Attente de l'arrêt effectif du Frontend..." "INFO"
            foreach ($srv in $frontendToStop) {
                $ok = Wait-ServerShutdown -ComputerName $srv -TimeoutSec $Config.ShutdownTimeoutSec
                if ($ok) { Write-Step "$srv : éteint" "OK" } else { Write-Step "$srv : timeout" "WARN"; $script:Errors += "Timeout $srv" }
            }
        }

        # --- ÉTAPE 2 : Nœud SQL secondaire ---
        Write-Section "Étape 2/5 : Arrêt du nœud SQL secondaire ($($Config.SQLSecondary))"
        if (Test-ServerOnline -ComputerName $Config.SQLSecondary) {
            if (Confirm-ServerShutdown -ComputerName $Config.SQLSecondary) {
                Write-Step "Arrêt de $($Config.SQLSecondary) en cours..." "INFO"
                Invoke-ServerShutdown -ComputerName $Config.SQLSecondary | Out-Null
                $script:Results += [PSCustomObject]@{ Server = $Config.SQLSecondary; Action = "Stop"; Status = "Lancé" }
                $ok = Wait-ServerShutdown -ComputerName $Config.SQLSecondary -TimeoutSec $Config.ShutdownTimeoutSec
                if ($ok) { Write-Step "$($Config.SQLSecondary) : éteint" "OK" } else { Write-Step "$($Config.SQLSecondary) : timeout" "WARN"; $script:Errors += "Timeout $($Config.SQLSecondary)" }
            } else { Write-Step "Arrêt annulé" "WARN" }
        } else { Write-Step "$($Config.SQLSecondary) : déjà éteint" "SKIP" }

        # --- ÉTAPE 3 : Nœud SQL primaire ---
        Write-Section "Étape 3/5 : Arrêt du nœud SQL primaire ($($Config.SQLPrimary))"
        if (Test-ServerOnline -ComputerName $Config.SQLPrimary) {
            if (Confirm-ServerShutdown -ComputerName $Config.SQLPrimary) {
                Write-Step "Arrêt de $($Config.SQLPrimary) en cours..." "INFO"
                Invoke-ServerShutdown -ComputerName $Config.SQLPrimary | Out-Null
                $script:Results += [PSCustomObject]@{ Server = $Config.SQLPrimary; Action = "Stop"; Status = "Lancé" }
                $ok = Wait-ServerShutdown -ComputerName $Config.SQLPrimary -TimeoutSec $Config.ShutdownTimeoutSec
                if ($ok) { Write-Step "$($Config.SQLPrimary) : éteint" "OK" } else { Write-Step "$($Config.SQLPrimary) : timeout" "WARN"; $script:Errors += "Timeout $($Config.SQLPrimary)" }
            } else { Write-Step "Arrêt annulé" "WARN" }
        } else { Write-Step "$($Config.SQLPrimary) : déjà éteint" "SKIP" }

        # --- ÉTAPE 4 : Serveur de fichiers ---
        Write-Section "Étape 4/5 : Arrêt du serveur de fichiers ($($Config.FileServer))"
        if (Test-ServerOnline -ComputerName $Config.FileServer) {
            if (Confirm-ServerShutdown -ComputerName $Config.FileServer) {
                Write-Step "Arrêt de $($Config.FileServer) en cours..." "INFO"
                Invoke-ServerShutdown -ComputerName $Config.FileServer | Out-Null
                $script:Results += [PSCustomObject]@{ Server = $Config.FileServer; Action = "Stop"; Status = "Lancé" }
                $ok = Wait-ServerShutdown -ComputerName $Config.FileServer -TimeoutSec $Config.ShutdownTimeoutSec
                if ($ok) { Write-Step "$($Config.FileServer) : éteint" "OK" } else { Write-Step "$($Config.FileServer) : timeout" "WARN"; $script:Errors += "Timeout $($Config.FileServer)" }
            } else { Write-Step "Arrêt annulé" "WARN" }
        } else { Write-Step "$($Config.FileServer) : déjà éteint" "SKIP" }

        # --- ÉTAPE 5 : DC03 ---
        Write-Section "Étape 5/5 : Arrêt du contrôleur de domaine ($($Config.DC))"
        Write-Host ""
        Write-Host "  ⚠️  ATTENTION : Ceci est le DERNIER serveur à éteindre." -ForegroundColor Yellow
        Write-Host "  Après extinction, vous ne pourrez plus utiliser ce script." -ForegroundColor Yellow
        Write-Host ""
        if (Confirm-ServerShutdown -ComputerName $Config.DC) {
            Write-Step "Arrêt de $($Config.DC) dans 10 secondes..." "WARN"
            for ($i = 10; $i -ge 1; $i--) { Write-Host "    $i..." -NoNewline -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            Write-Host ""
            Write-Step "Arrêt de $($Config.DC) en cours..." "INFO"
            Stop-Computer -Force
        } else {
            Write-Step "Arrêt du DC annulé. Le PoC reste partiellement allumé." "WARN"
        }
    }

    # --------------------------------------------------------
    # DÉMARRAGE (Ordre séquentiel selon Hyper-V)
    # --------------------------------------------------------
    elseif ($Action -eq "Start") {
        Write-Host ""
        Write-Host "  ⚠️  Pour le DÉMARRAGE, le script vérifie l'état des serveurs." -ForegroundColor Yellow
        Write-Host "  Vous devez démarrer manuellement (via Hyper-V) :" -ForegroundColor Yellow
        Write-Host "    1. DC03 (si éteint)" -ForegroundColor Gray
        Write-Host "    2. OPT-FS03 (si éteint)" -ForegroundColor Gray
        Write-Host "  Puis relancer ce script pour vérifier la suite." -ForegroundColor Gray
        Write-Host ""

        Write-Section "Étape 1/5 : Vérification du contrôleur de domaine"
        if (Test-ServerOnline -ComputerName $Config.DC) {
            Write-Step "$($Config.DC) : en ligne" "OK"
        } else {
            Write-Step "$($Config.DC) : ÉTEINT - Démarrez-le manuellement puis relancez ce script" "ERROR"
            exit 1
        }

        Write-Section "Étape 2/5 : Vérification du serveur de fichiers"
        if (Test-ServerOnline -ComputerName $Config.FileServer) {
            Write-Step "$($Config.FileServer) : déjà en ligne" "OK"
        } else {
            Write-Step "$($Config.FileServer) : ÉTEINT - Démarrez-le manuellement (Hyper-V) puis relancez" "ERROR"
            Write-Host "    Commande Hyper-V : Start-VM -Name '$($Config.FileServer)'" -ForegroundColor Gray
            exit 1
        }

        Write-Section "Étape 3/5 : Démarrage du nœud SQL primaire ($($Config.SQLPrimary))"
        if (-not (Test-ServerOnline -ComputerName $Config.SQLPrimary)) {
            Write-Step "$($Config.SQLPrimary) est éteint. Démarrage via Hyper-V requis." "WARN"
            Write-Host "    Commande Hyper-V : Start-VM -Name '$($Config.SQLPrimary)'" -ForegroundColor Gray
            Write-Host "    Puis relancez ce script." -ForegroundColor Gray
            exit 1
        } else {
            Write-Step "$($Config.SQLPrimary) : déjà en ligne" "OK"
        }

        Write-Section "Étape 4/5 : Démarrage du nœud SQL secondaire ($($Config.SQLSecondary))"
        if (-not (Test-ServerOnline -ComputerName $Config.SQLSecondary)) {
            Write-Step "$($Config.SQLSecondary) est éteint. Démarrage via Hyper-V requis." "WARN"
            Write-Host "    Commande Hyper-V : Start-VM -Name '$($Config.SQLSecondary)'" -ForegroundColor Gray
        } else {
            Write-Step "$($Config.SQLSecondary) : déjà en ligne" "OK"
        }

        Write-Section "Étape 5/5 : Démarrage du Frontend (IIS + RP)"
        foreach ($srv in ($Config.IISBackends + $Config.ReverseProxy)) {
            if (-not (Test-ServerOnline -ComputerName $srv)) {
                Write-Step "$srv : éteint - Démarrage via Hyper-V requis" "WARN"
                Write-Host "    Commande Hyper-V : Start-VM -Name '$srv'" -ForegroundColor Gray
            } else {
                Write-Step "$srv : déjà en ligne" "OK"
            }
        }

        Write-Section "Vérification finale du cluster"
        try {
            Import-Module FailoverClusters -ErrorAction Stop
            $cluster = Get-Cluster -ErrorAction Stop
            Write-Step "Cluster $($cluster.Name) accessible" "OK"
            $quorum = Get-ClusterQuorum
            Write-Step "Quorum : $($quorum.QuorumResource)" "OK"
            $nodes = Get-ClusterNode
            foreach ($node in $nodes) {
                $state = $node.State
                $color = if ($state -eq "Up") { "OK" } else { "WARN" }
                Write-Step "Nœud $($node.Name) : $state" $color
            }
        } catch {
            Write-Step "Cluster non accessible : $($_.Exception.Message)" "WARN"
        }
    }

    # --------------------------------------------------------
    # RÉSUMÉ
    # --------------------------------------------------------
    $duration = (Get-Date) - $script:StartTime
    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Action    : $Action" -ForegroundColor Cyan
    Write-Host "  Durée     : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""

    if ($script:Results.Count -gt 0) {
        Write-Host "  Détail :" -ForegroundColor Cyan
        $script:Results | Format-Table Server, Action, Status -AutoSize
    }

    if ($script:Errors.Count -gt 0) {
        Write-Host "  Erreurs :" -ForegroundColor Red
        $script:Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "  Log complet : $LogPath" -ForegroundColor DarkGray

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  Message : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Ligne   : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}