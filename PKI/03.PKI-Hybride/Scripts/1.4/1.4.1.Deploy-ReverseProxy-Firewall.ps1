<# 
    Script : Deploy-ReverseProxy-Firewall.ps1
    Objectif : Déployer les règles firewall Reverse Proxy sur les 6 backends IIS
    Auteur : Driss / Optimedit
    Version : 1.1
#>

# ============================
# CONFIGURATION
# ============================
$Backends = @(
    "OPT-IIS-01.optimedit.eu",
    "OPT-IIS-02.optimedit.eu",
    "OPT-IIS-03.optimedit.eu",
    "OPT-IIS-04.optimedit.eu",
    "OPT-IIS-05.optimedit.eu",
    "OPT-IIS-06.optimedit.eu"
)

$rpName  = "OPT-RP-01.optimedit.eu"
$logFile = "C:\Logs\Deploy-ReverseProxy-Firewall.log"

# ============================
# CRÉATION DU DOSSIER DE LOGS
# ============================
if (!(Test-Path "C:\Logs")) {
    New-Item -ItemType Directory -Path "C:\Logs" -Force | Out-Null
}

# ============================
# LOG LOCAL
# ============================
function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "$timestamp - $Message"
}

Write-Log "----- DÉBUT DU DÉPLOIEMENT -----"

# ============================
# RÉSOLUTION DNS DU RP
# ============================
try {
    $rpIP = (Resolve-DnsName $rpName -Type A -ErrorAction Stop).IPAddress
    Write-Log "IP du reverse-proxy résolue : $rpIP"
}
catch {
    Write-Log "ERREUR : Impossible de résoudre $rpName"
    throw "Impossible de résoudre $rpName"
}

# ============================
# SCRIPT BLOCK POUR LES BACKENDS
# ============================
$ScriptBlock = {
    param($rpIP)

    $remoteLog = "C:\Logs\ReverseProxy-Firewall.log"

    # Création dossier logs backend
    if (!(Test-Path "C:\Logs")) {
        New-Item -ItemType Directory -Path "C:\Logs" -Force | Out-Null
    }

    function Write-RemoteLog {
        param([string]$Message)
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $remoteLog -Value "$timestamp - $Message"
    }

    Write-RemoteLog "----- DÉBUT -----"
    Write-RemoteLog "Reverse Proxy IP : $rpIP"

    function Ensure-FirewallRule {
        param(
            [string]$RuleName,
            [int]$Port
        )

        $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

        if ($existing) {
            Write-RemoteLog "Règle déjà présente : $RuleName"
        }
        else {
            New-NetFirewallRule `
                -DisplayName $RuleName `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $Port `
                -RemoteAddress $rpIP `
                -Action Allow `
                -Profile Domain

            Write-RemoteLog "Règle créée : $RuleName (Port $Port, Source $rpIP)"
        }
    }

    Ensure-FirewallRule -RuleName "Allow-ReverseProxy-HTTP-From-RP01" -Port 80
    Ensure-FirewallRule -RuleName "Allow-ReverseProxy-HTTPS-From-RP01" -Port 443

    Write-RemoteLog "----- FIN -----"
}

# ============================
# EXÉCUTION SUR LES BACKENDS
# ============================
foreach ($server in $Backends) {
    Write-Log "Déploiement sur $server..."

    try {
        Invoke-Command -ComputerName $server -ScriptBlock $ScriptBlock -ArgumentList $rpIP -ErrorAction Stop
        Write-Log "Succès sur $server"
    }
    catch {
        Write-Log "ERREUR sur $server : $_"
    }
}

Write-Log "----- FIN DU DÉPLOIEMENT -----"
