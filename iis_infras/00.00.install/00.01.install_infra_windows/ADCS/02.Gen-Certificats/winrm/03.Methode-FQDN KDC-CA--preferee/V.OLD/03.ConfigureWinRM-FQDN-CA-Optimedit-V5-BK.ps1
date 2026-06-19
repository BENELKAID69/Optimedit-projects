# nom de script : 03.ConfigureWinRM-FQDN-CA-Optimedit.ps1
# V5 - Identification par OID immuable (Blindage Optimedit)

# --- Variables de référence -----------------------------
# TargetOID = 
$CurrentFQDN = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()
$TargetOID = "1.3.6.1.4.1.311.21.8.7103102.15251863.2049408.3177376.8187667.136.12355323.6820193" # entré en dur

# Récupération dynamique de l'OID sur le DC ou poste Admin
# $TemplateName = "Ansible-WinRM-FQDN-SERVERS" 					# a adapter
# On peut trouver TemplateName avec cette commande:
# Get-ADObject -SearchBase "CN=Certificate Templates,CN=Public Key Services,CN=Services,$((Get-ADRootDSE).configurationNamingContext)" -Filter * -Properties displayName, msPKI-Cert-Template-OID | Select-Object displayName, msPKI-Cert-Template-OID
# $PathTemplate = "CN=$TemplateName,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=optimedit,DC=eu"
# $TargetOID = (Get-ADObject -Identity $PathTemplate -Properties "msPKI-Cert-Template-OID")."msPKI-Cert-Template-OID"
# ------------------------------------------------------

# --- 7. LOGGING LOCAL (C:\temp\) ----------------------
$LogLocalDir = "C:\temp"
$LogLocalFile = Join-Path $LogLocalDir "WinRM_Config_History.log"
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Création du dossier temp s'il n'existe pas
if (!(Test-Path $LogLocalDir)) {
    New-Item -Path $LogLocalDir -ItemType Directory -Force | Out-Null
}

# --- Initialisation WinRM ----------------------------------
Set-Service -Name "WinRM" -StartupType Automatic
Start-Service -Name "WinRM" -ErrorAction SilentlyContinue

# --- Recherche par OID de modèle ---
Write-Host "Analyse du magasin par OID de modèle..." -ForegroundColor Cyan

$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    $isMatch = $false
    # L'extension "Template" possède l'OID 1.3.6.1.4.1.311.21.7
    $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
    
    if ($null -ne $templateExt) {
        # On compare l'OID brut contenu dans l'extension au lieu du nom texte
        # Cela évite les erreurs de résolution de nom "disponible/indisponible"
        if ($templateExt.Format(0) -match $TargetOID) {
            $isMatch = $true
        }
    }
    return $isMatch
} | Sort-Object NotBefore -Descending | Select-Object -First 1

if ($null -eq $cert) {
    Write-Error "CRITIQUE : Aucun certificat correspondant à l'OID $TargetOID trouvé !"
    exit 1
}

$CurrentThumbprint = $cert.Thumbprint
Write-Host "Certificat conforme identifié : $CurrentFQDN ($CurrentThumbprint)" -ForegroundColor Green

# --- Nettoyage et Création du Listener ------------------------------
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -like "TRANSPORT=HTTPS" } | ForEach-Object {
    Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue
}

$valueset = @{ Hostname = $CurrentFQDN; CertificateThumbprint = $CurrentThumbprint }
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Transport="HTTPS"; Address="*"} -ValueSet $valueset | Out-Null

# Configuration Firewall
if (!(Get-NetFirewallRule -Name "AllowWinRMHTTPS" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow WinRM HTTPS" -Name "AllowWinRMHTTPS" -Profile Any -LocalPort 5986 -Protocol TCP -Action Allow -Direction Inbound | Out-Null
}

# --- REDEMARRAGE ASYNCHRONE -----------------------------------------
Start-Job -ScriptBlock { 
    Start-Sleep -Seconds 2
    Restart-Service winrm -Force 
} | Out-Null

# Écriture dans le fichier (mode Append pour garder l'historique)
# Préparation du message de log
if ($null -ne $cert) {
    $LogMessage = "[$Timestamp] SUCCESS: WinRM configuré avec le certificat $CurrentThumbprint (OID: $TargetOID)"
} else {
    $LogMessage = "[$Timestamp] ERROR: Échec de configuration WinRM - Certificat introuvable pour OID $TargetOID"
}

$LogMessage | Out-File -FilePath $LogLocalFile -Append -Encoding UTF8

Write-Host "Log local mis à jour : $LogLocalFile" -ForegroundColor Gray

Write-Host "Configuration terminée. Le Listener utilise désormais l'OID immuable." -ForegroundColor Green

# recuperer le contenu de log :
# Invoke-Command -ComputerName "OPT-IIS-04","OPT-IIS-05","OPT-IIS-06" { Get-Content "C:\temp\WinRM_Config_History.log" -Tail 1 }
