# --- CONFIGURATION DE LA DEMANDE ---
$FqdnLocal = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()
$TemplateName = "IIS-SAN-Auto-Enrollment" # Votre nouveau modèle ADCS
$FqdnCa   = "OPT-DC02.optimedit.eu"  
#$CaName   = "Optimedit-CA"    
$CaName = (Get-ADObject -SearchBase "CN=Certification Authorities,CN=Public Key Services,CN=Services,$((Get-ADRootDSE).configurationNamingContext)" -Filter *).name

# Vos 13 domaines métiers fixes
$MetierDomains = @(
    "direction.optimedit.eu", "comptabilite.optimedit.eu", "paie.optimedit.eu",
    "rh.optimedit.eu", "ce.optimedit.eu", "it.optimedit.eu", 
    "production.optimedit.eu", "formation.optimedit.eu", "achat.optimedit.eu",
    "commercial.optimedit.eu", "client.optimedit.eu", "juridique.optimedit.eu",
    "blog.optimedit.eu", "optimedit.eu"
)

# On fusionne le FQDN réel de la machine + les 13 domaines
$AllSANs = @($FqdnLocal) + $MetierDomains

Write-Host "Préparation de la requête pour $FqdnLocal avec les 13 SAN..." -ForegroundColor Cyan

# Génération dynamique des extensions SAN pour la commande PowerShell
$AlternativeNames = $AllSANs | ForEach-Object { "dns=$_" }
$SanExtension = [string]::Join("&", $AlternativeNames)

# Utilisation de la commande moderne PowerShell de demande de certificat
$CertRequest = New-CertificateRequest -Subject "CN=$FqdnLocal" `
                                      -AlternativeName $AllSANs `
                                      -KeyExportable $true `
                                      -Type Machine `
                                      -Template $TemplateName `
                                      -CertStoreLocation "Cert:\LocalMachine\My"

# Soumission directe et automatique à la CA
$ConfigString = "$FqdnCa\$CaName"
$RequestPath = "C:\temp\request_local.req"
$ResponsePath = "C:\temp\response_local.cer"

# Export de la requête générée vers un fichier temporaire
[File]::WriteAllText($RequestPath, $CertRequest)

# Envoi à la CA et récupération du certificat
certreq.exe -submit -config $ConfigString $RequestPath $ResponsePath
certreq.exe -accept $ResponsePath

Write-Host "[SUCCÈS] Certificat individuel installé pour $FqdnLocal avec ses 13 SAN." -ForegroundColor Green