<#
.SYNOPSIS
    Envoie un email d'alerte SQL Server via Send-MailMessage (contourne Database Mail).

.DESCRIPTION
    Appele par le job SQL Agent "DBA - Send Alert Email" declenche par les alertes.
    Le mot de passe SMTP est lu depuis le secret chiffre smtp-ovh-pwd.enc
    (cree par 3.0.0.manage_secrets.ps1).
#>
[CmdletBinding()]
param(
    [string]$To = "optimedit.fr@gmail.com"
)

$ErrorActionPreference = "Stop"

# --- TLS 1.2 ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Lecture du secret chiffre ---
$SecureFolder = "C:\ProgramData\SQLSecrets"
$keyFile = "$SecureFolder\aes.key"
$encFile = "$SecureFolder\smtp-ovh-pwd.enc"

if (-not (Test-Path $keyFile)) { throw "Cle AES introuvable : $keyFile" }
if (-not (Test-Path $encFile)) { throw "Secret chiffre introuvable : $encFile" }

$key = Get-Content $keyFile -Encoding Byte
$securePwd = Get-Content $encFile | ConvertTo-SecureString -Key $key

# --- Construction du message ---
$subject = "[ALERTE SQL Server] " + $env:COMPUTERNAME + " - " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$body = @"
Alerte SQL Server declenchee sur $env:COMPUTERNAME.

Date    : $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")
Serveur : $env:COMPUTERNAME

Consultez l'historique SQL Agent pour plus de details :
- SSMS > SQL Server Agent > Alertes > Historique

--
Message automatique du systeme d'alertes SQL Server Always On
"@

# --- Envoi ---
$cred = New-Object System.Management.Automation.PSCredential("contact@optimedit.eu", $securePwd)

try {
    Send-MailMessage `
        -SmtpServer "smtp.mail.ovh.net" `
        -Port 587 `
        -UseSsl `
        -Credential $cred `
        -From "contact@optimedit.eu" `
        -To $To `
        -Subject $subject `
        -Body $body `
        -Encoding UTF8 `
        -ErrorAction Stop

    Write-Host "[OK] Email envoye a $To" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "[ERR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}