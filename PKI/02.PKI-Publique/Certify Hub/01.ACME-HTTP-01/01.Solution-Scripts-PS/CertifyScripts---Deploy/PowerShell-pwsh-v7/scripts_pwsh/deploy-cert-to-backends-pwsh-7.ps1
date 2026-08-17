# Nom script : deploy-cert-to-backends.ps1
<#
.SYNOPSIS
    Script de déploiement automatique de certificats PFX sur serveurs IIS distants.
    Version optimisée pour PowerShell 7 (pwsh.exe).

.DESCRIPTION
    [SYNAPS-INFRA]
    Ce script automatise la distribution d'un certificat PFX depuis le hub central vers 
    les serveurs web (SRV-WEB-02, SRV-WEB-03). Il gère le déchiffrement sécurisé des 
    secrets (via clé AES), la copie distante, l'importation du certificat, la mise 
    à jour des bindings IIS et le nettoyage des anciens certificats expirés.

    --- PRÉREQUIS POUR EXÉCUTION AVEC POWERSHELL 7 (RECOMMANDÉ) ---

    1. Installer PowerShell 7 (pwsh.exe) sur le serveur HUB :
       Téléchargement officiel Microsoft :
       https://github.com/PowerShell/PowerShell/releases/latest

       Fichier recommandé :
       PowerShell-7.x.x-win-x64.msi

       Chemin d'installation par défaut :
       C:\Program Files\PowerShell\7\pwsh.exe

    2. Configurer la tâche planifiée Certify Management Hub pour utiliser pwsh.exe :
       Dans Certify → Managed Certificate → Tasks → PowerShell Task → Advanced :
       
       Custom PowerShell Executable :
       C:\Program Files\PowerShell\7\pwsh.exe

       Cela garantit :
       - Encodage UTF‑8 correct (aucun caractère cassé)
       - Compatibilité totale avec ConvertTo-SecureString -Key
       - Exécution stable et moderne du script

.PARAMETER LocalPfxPath
    Chemin local du fichier PFX à déployer. (Défaut : C:\CertifyScripts\export\latest.pfx)

.PARAMETER RemoteTempPath
    Chemin temporaire sur le serveur distant pour le transfert. (Défaut : C:\Windows\Temp\latest.pfx)

.PARAMETER SiteName
    Nom du site IIS cible. (Défaut : Default Web Site)

.PARAMETER ExpectedThumbprint
    Thumbprint attendu pour validation post-déploiement.

.NOTES
    Auteur  : Optimed IT
    Date    : 17/07/2026
    Version : 4.3 (Optimisée PowerShell 7)
    Usage   : Script de déploiement et automatisation de renouvellement HTTPS 
              via tâche planifiée dans le Certify Management Hub.
#>


param(
    [string]$LocalPfxPath = "C:\CertifyScripts\export\latest.pfx",
    [string]$RemoteTempPath = "C:\Windows\Temp\latest.pfx",
    [string]$SiteName = "Default Web Site",
    [string]$ExpectedThumbprint = ""
)

# Vérification version PowerShell
Write-Host "Version PowerShell utilisée : $($PSVersionTable.PSVersion)"

# === LOGGING ===
$logFolder = "C:\CertifyScripts\logs_pwsh"
if (!(Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder | Out-Null }

# Rotation : garder 50 logs
$logFiles = Get-ChildItem -Path $logFolder -Filter "*.log" | Sort-Object LastWriteTime -Descending
if ($logFiles.Count -gt 50) {
    $logFiles | Select-Object -Skip 50 | Remove-Item -Force
}

$logFile = Join-Path $logFolder ("deploy_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"

    # UTF-8 sans BOM (PS7)
    [System.IO.File]::AppendAllText(
        $logFile,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host $line
}

Write-Log "=== DÉBUT DU DÉPLOIEMENT ==="

# === CHARGEMENT DES SECRETS AES ===
$secureFolder = "C:\CertifyScripts\secure_pwsh"

try {
    Write-Log "Chargement de la clé AES..."

    # Lire la clé AES en binaire
    $aesKey = [System.IO.File]::ReadAllBytes("$secureFolder\aes.key")

    Write-Log "Chargement des secrets chiffrés..."

    # Lire les secrets en texte (PAS en bytes)
    $deployPwdEnc = Get-Content "$secureFolder\deploy-pwd.enc"
    $deploySecurePwd = ConvertTo-SecureString $deployPwdEnc -Key $aesKey
    $deployCred = New-Object System.Management.Automation.PSCredential("OPTIMEDIT\svc-certdeploy", $deploySecurePwd)

    $pfxPwdEnc = Get-Content "$secureFolder\pfx-pwd.enc"
    $pfxSecurePwd = ConvertTo-SecureString $pfxPwdEnc -Key $aesKey

    Write-Log "Secrets chargés avec succès."
}
catch {
    Write-Log "ÉCHEC CRITIQUE : impossible de charger les secrets. $($_.Exception.Message)" "ERROR"
    exit 1
}

# === SERVEURS CIBLES ===
$servers = @("SRV-WEB-02", "SRV-WEB-03")

foreach ($srv in $servers) {

    Write-Log "=== Déploiement vers $srv ==="

    try {
        Write-Log "Ouverture de la session distante..."
        $session = New-PSSession -ComputerName $srv -Credential $deployCred -ErrorAction Stop
        Write-Log "Session ouverte."

        Write-Log "Suppression ancien PFX temporaire..."
        Invoke-Command -Session $session -ScriptBlock {
            param($path)
            if (Test-Path $path) {
                Remove-Item $path -Force
                "Ancien PFX temporaire supprimé."
            }
        } -ArgumentList $RemoteTempPath | Write-Log

        Write-Log "Copie du nouveau PFX..."
        Copy-Item -Path $LocalPfxPath -Destination $RemoteTempPath -ToSession $session -Force
        Write-Log "Copie OK."

        Write-Log "Import du certificat + mise à jour IIS..."

        $result = Invoke-Command -Session $session -ScriptBlock {
            param($pfxPath, $pfxPwd, $site)

            Import-Module WebAdministration

            "Import du certificat..."
            $cert = Import-PfxCertificate -FilePath $pfxPath `
                -CertStoreLocation Cert:\LocalMachine\My `
                -Password $pfxPwd -Exportable

            if (-not $cert) { throw "Import-PfxCertificate a retourné NULL." }

            "Certificat importé : $($cert.Thumbprint)"

            "Suppression des anciens bindings HTTPS..."
            Get-WebBinding -Name $site -Protocol https | Where-Object { $_.bindingInformation -match ":443:" } | ForEach-Object {
                $parts = $_.bindingInformation -split ":"
                $hostHeader = $parts[2]

                if ($hostHeader) {
                    Remove-WebBinding -Name $site -Protocol https -Port 443 -HostHeader $hostHeader
                    "Binding supprimé : $hostHeader"
                }
                else {
                    Remove-WebBinding -Name $site -Protocol https -Port 443
                    "Binding sans host header supprimé."
                }
            }

            if (-not (Get-WebBinding -Name $site -Protocol https -Port 443)) {
                New-WebBinding -Name $site -Protocol https -Port 443 -IPAddress "*"
                "Binding HTTPS recréé."
            }

            "Application du certificat au binding..."
            (Get-WebBinding -Name $site -Protocol https).AddSslCertificate($cert.Thumbprint, "my")

            "Nettoyage anciens certificats..."
            Get-ChildItem Cert:\LocalMachine\My |
                Where-Object { $_.Subject -like "*api-rest.optimedit.eu*" -and $_.Thumbprint -ne $cert.Thumbprint } |
                Remove-Item -Force

            "Suppression du PFX temporaire..."
            Remove-Item $pfxPath -Force

            return $cert.Thumbprint
        } -ArgumentList $RemoteTempPath, $pfxSecurePwd, $SiteName

        Write-Log "Binding mis à jour avec thumbprint : $result"

        Remove-PSSession $session
        Write-Log "Session fermée."
    }
    catch {
        Write-Log "ÉCHEC sur $srv : $($_.Exception.Message)" "ERROR"
    }
}

Write-Log "=== DÉPLOIEMENT TERMINÉ SUR TOUS LES SERVEURS ==="
Write-Log "Log complet disponible : $logFile"
