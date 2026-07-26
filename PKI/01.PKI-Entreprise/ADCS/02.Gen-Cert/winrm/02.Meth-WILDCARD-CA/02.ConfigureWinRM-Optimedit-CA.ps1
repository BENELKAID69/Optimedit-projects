
# nom de script : 02.ConfigureWinRM-Optimedit-CA.ps1
# ATTENTION : ce script est utilisable via un autre script nommé : "02.InstallWinRM-Optimedit.ps1"

# Version modifiée pour le projet Optimedit
[CmdletBinding()]
Param (
    [string]$TargetThumbprint = "3EC951E2E2AA838FE7396EAEC1781FDA10B60009", 	# a adapter selon certificat
    [string]$TargetDNS = "citrix.optimedit.eu" 									# a adapter selon certificat
)

# --- Initialisation WinRM standard ---
Write-Host "Vérification du service WinRM..." -ForegroundColor Cyan
Set-Service -Name "WinRM" -StartupType Automatic
Start-Service -Name "WinRM" -ErrorAction SilentlyContinue

# Configuration PSRemoting
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Fix LocalAccountTokenFilterPolicy (Indispensable pour Ansible) # Il débloque la restriction UAC pour les comptes distants
$tokenPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $tokenPath -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord

# --- Bloc Spécifique Certificat ADCS ---
Write-Host "Recherche du certificat ADCS ($TargetDNS)..." -ForegroundColor Cyan
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $TargetThumbprint }

if ($null -eq $cert) {
    Write-Error "Erreur : Le certificat ADCS avec le Thumbprint $TargetThumbprint est introuvable !"
    exit 1
}

# Nettoyage des anciens listeners HTTPS
Write-Host "Nettoyage des anciens listeners..." -ForegroundColor Yellow
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -like "TRANSPORT=HTTPS" } | ForEach-Object {
    Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Address="*";Transport="HTTPS"}
}

# Création du Listener avec ton certificat ADCS
Write-Host "Création du listener HTTPS lié à $TargetDNS..." -ForegroundColor Green
$valueset = @{
    Hostname = $TargetDNS
    CertificateThumbprint = $TargetThumbprint
}
$selectorset = @{
    Transport = "HTTPS"
    Address = "*"
}
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet $selectorset -ValueSet $valueset

# Configuration Firewall
Write-Host "Ouverture du port 5986..." -ForegroundColor Cyan
if (!(Get-NetFirewallRule -Name "AllowWinRMHTTPS" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow WinRM HTTPS" -Name "AllowWinRMHTTPS" -Profile Any -LocalPort 5986 -Protocol TCP -Action Allow -Direction Inbound
}

# Redémarrage asynchrone pour ne pas casser la session WinRM brutalement
Start-Job -ScriptBlock { 
    Sleep 2
    Restart-Service winrm -Force 
} | Out-Null

Write-Host "Configuration terminée pour $TargetDNS, redémarrage du service WinRM programmé..." -ForegroundColor Green
