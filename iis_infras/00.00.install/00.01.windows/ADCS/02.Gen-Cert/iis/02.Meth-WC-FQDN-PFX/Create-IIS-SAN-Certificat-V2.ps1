# ===============================================================================================================
# POC Infrastructure IIS - Génération du Certificat SAN Wildcard (phase 1)
# Rôle : À exécuter sur la PASSERELLE / l'autorité de certification (OPT-DC02.optimedit.eu)
# ===============================================================================================================

# --- SECTION CONFIGURATION INFRASTRUCTURE -----------------
$FqdnCa   = "OPT-DC02.optimedit.eu"  
#$CaName   = "Optimedit-CA"   
$CaName = (Get-ADObject -SearchBase "CN=Certification Authorities,CN=Public Key Services,CN=Services,$((Get-ADRootDSE).configurationNamingContext)" -Filter *).name
$InfPath  = "C:\temp\IIS-SAN-Certificat-V2.inf"    
# ----------------------------------------------------------

Write-Host "--- PRÉPARATION DU FICHIER CONFIGURATION ---" -ForegroundColor Cyan

# 1. Lecture et réécriture en ASCII obligatoire pour certreq.exe
if (Test-Path $InfPath) {
    $infContent = Get-Content -Path $InfPath -Raw
    Set-Content -Path $InfPath -Value $infContent -Encoding ASCII
    Write-Host "[OK] Fichier .INF converti et validé en encodage ASCII." -ForegroundColor Green
} else {
    Write-Error "[STOP] Fichier source $InfPath introuvable !"; break
}

# 2. Extraction dynamique du Subject (CN) depuis le fichier .inf pour éviter les erreurs de filtrage
$SubjectLine = Get-Content $InfPath | Where-Object { $_ -match "^Subject\s*=" }
$TargetCN = ($SubjectLine -split "=")[1].Trim().Replace('"', '') # Extrait proprement (ex: CN=iis.optimedit.eu)

# Définition des chemins des artefacts de certification
$ReqPath = $InfPath.Replace(".inf", ".req")
$CerPath = $InfPath.Replace(".inf", ".cer")
$PfxPath = $InfPath.Replace(".inf", ".pfx")
$ConfigString = "$FqdnCa\$CaName"

Write-Host "--- DÉBUT DU PROCESSUS DE CERTIFICATION ADCS ---" -ForegroundColor Cyan

# 3. Génération de la requête CSR (PKCS10)
Write-Host "[EXEC] Génération de la requête de certificat (.req)..." -ForegroundColor Yellow
certreq.exe -new -f $InfPath $ReqPath

# 4. Soumission automatique à l'Autorité de Certification (CA)
Write-Host "[EXEC] Soumission de la requête au CA ($ConfigString)..." -ForegroundColor Yellow
certreq.exe -submit -config $ConfigString $ReqPath $CerPath | Out-Null

# 5. Acceptation et installation du certificat dans le magasin LocalMachine\My
Write-Host "[EXEC] Installation du certificat dans le magasin Personnel de la machine..." -ForegroundColor Yellow
certreq.exe -accept $CerPath

# 6. Exportation du package sécurisé PFX
Write-Host "`n--- EXPORTATION ET SÉCURISATION DU FICHIER PFX ---" -ForegroundColor Cyan

# Définition du mot de passe (Modifiable par une variable sécurisée si intégré dans Ansible)
$ClearPassword = "Dr/*-101977"
$SecurePwd = ConvertTo-SecureString $ClearPassword -AsPlainText -Force

# Recherche ultra-précise du certificat fraîchement installé basé sur le Subject exact extrait du .inf
$cert = Get-ChildItem Cert:\LocalMachine\My | 
        Where-Object { $_.Subject -replace ' ', '' -match $TargetCN } | 
        Sort-Object NotBefore -Descending | Select-Object -First 1

if ($cert) {
    # Exportation incluant la clé privée exportable (grâce à Exportable = TRUE dans le .inf)
    Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $SecurePwd -Force
    Write-Host "[SUCCÈS] Le certificat PFX a été généré avec succès !" -ForegroundColor Green
    Write-Host "Fichier disponible : $PfxPath" -ForegroundColor Green
    Write-Host "Action requise : Transférez ce fichier sur votre Broker / Serveurs IIS cibles." -ForegroundColor White
} else {
    Write-Host "[ERREUR CRITIQUE] Impossible de localiser le certificat avec le sujet '$TargetCN' dans le magasin local." -ForegroundColor Red
}