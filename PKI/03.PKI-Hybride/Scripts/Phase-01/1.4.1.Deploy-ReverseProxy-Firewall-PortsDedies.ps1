<# 
    Script : 1.4.1.Deploy-ReverseProxy-Firewall-PortsDedies.ps1
    Objectif : Autoriser OPT-RP-01 sur les ports dédiés 8060–8072
    Auteur : Driss / Optimedit
    Version : 1.0
#>

$Backends = @(
    "OPT-IIS-01.optimedit.eu",
    "OPT-IIS-02.optimedit.eu",
    "OPT-IIS-03.optimedit.eu",
    "OPT-IIS-04.optimedit.eu",
    "OPT-IIS-05.optimedit.eu",
    "OPT-IIS-06.optimedit.eu"
)

$rpName  = "OPT-RP-01.optimedit.eu"
$ports   = 8060..8072
$logFile = "C:\Logs\Deploy-ReverseProxy-Firewall-PortsDedies.log"

if (!(Test-Path "C:\Logs")) {
    New-Item -ItemType Directory -Path "C:\Logs" -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    Add-Content -Path $logFile -Value "$(Get-Date) - $Message"
}

Write-Log "----- DÉBUT DU DÉPLOIEMENT PORTS DÉDIÉS -----"

try {
    $rpIP = (Resolve-DnsName $rpName -Type A -ErrorAction Stop).IPAddress
    Write-Log "IP du reverse-proxy résolue : $rpIP"
}
catch {
    Write-Log "ERREUR : Impossible de résoudre $rpName"
    throw
}

$ScriptBlock = {
    param($rpIP, $ports)

    $remoteLog = "C:\Logs\ReverseProxy-Firewall-PortsDedies.log"

    if (!(Test-Path "C:\Logs")) {
        New-Item -ItemType Directory -Path "C:\Logs" -Force | Out-Null
    }

    function Write-RemoteLog {
        param([string]$Message)
        Add-Content -Path $remoteLog -Value "$(Get-Date) - $Message"
    }

    Write-RemoteLog "----- DÉBUT -----"
    Write-RemoteLog "Reverse Proxy IP : $rpIP"

    foreach ($p in $ports) {

        $ruleName = "Allow-ReverseProxy-Port-$p-From-RP01"
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

        if ($existing) {
            Write-RemoteLog "Règle déjà présente : $ruleName"
        }
        else {
            New-NetFirewallRule `
                -DisplayName $ruleName `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $p `
                -RemoteAddress $rpIP `
                -Action Allow `
                -Profile Domain

            Write-RemoteLog "Règle créée : $ruleName (Port $p, Source $rpIP)"
        }
    }

    Write-RemoteLog "----- FIN -----"
}

foreach ($server in $Backends) {
    Write-Log "Déploiement sur $server..."

    try {
        Invoke-Command -ComputerName $server -ScriptBlock $ScriptBlock -ArgumentList $rpIP, $ports -ErrorAction Stop
        Write-Log "Succès sur $server"
    }
    catch {
        Write-Log "ERREUR sur $server : $_"
    }
}

Write-Log "----- FIN DU DÉPLOIEMENT PORTS DÉDIÉS -----"
