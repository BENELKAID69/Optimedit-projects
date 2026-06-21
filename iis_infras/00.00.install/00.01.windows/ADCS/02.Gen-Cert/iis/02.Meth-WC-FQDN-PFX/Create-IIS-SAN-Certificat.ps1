# ===============================================================================================================
# POC Infrastructure IIS - Génération du Certificat SAN Wildcard (phase 1) avec ce script
# POC Infrastructure IIS - Génération du Certificat SAN Multidomaines (non Wildcard) (phase 2) avec script adapté
# Rôle : À exécuter sur la PASSERELLE (OPT-DC02.optimedit.eu)
# ===============================================================================================================

# --- SECTION À ADAPTER POUR AUTRE CLIENT ------------------
$TargetCN   = "iis.optimedit.eu"           
$FqdnCa   = "OPT-DC02.optimedit.eu"  # 
$CaName   = "Optimedit-CA"           #
$InfPath  = "C:\temp\IIS-SAN-Certificat-V2.inf"    
# ----------------------------------------------------------

# Lecture et réécriture en ASCII pour garantir la compatibilité certreq
if (Test-Path $InfPath) {
    $infContent = Get-Content -Path $InfPath -Raw
    Set-Content -Path $InfPath -Value $infContent -Encoding ASCII
    Write-Host "Fichier .INF préparé en ASCII." -ForegroundColor Green
} else {
    Write-Error "Fichier source $InfPath introuvable !"; break
}

$ReqPath = $InfPath.Replace(".inf", ".req")
$CerPath = $InfPath.Replace(".inf", ".cer")
$PfxPath = $InfPath.Replace(".inf", ".pfx")
$ConfigString = "$FqdnCa\$CaName"

Write-Host "--- DÉBUT DU PROCESSUS DE CERTIFICATION ---" -ForegroundColor Cyan

# 1. Génération de la requête (CSR)
Write-Host "Génération de la requête .req..." -ForegroundColor Yellow
certreq -new $InfPath $ReqPath

# 2. Soumission à l'Autorité de Certification
Write-Host "Soumission au CA ($ConfigString)..." -ForegroundColor Yellow
certreq -submit -config $ConfigString $ReqPath $CerPath

# 3. Acceptation du certificat
Write-Host "Installation locale du certificat..." -ForegroundColor Yellow
certreq -accept $CerPath

# 4. Exportation PFX
Write-Host "--- EXPORTATION PFX ---" -ForegroundColor Cyan
$pwd = Read-Host "Définissez un mot de passe pour le fichier PFX" -AsSecureString

$cert = Get-ChildItem Cert:\LocalMachine\My | 
        Where-Object { $_.Subject -match "CN=$TargetCN" } | 
        Sort-Object NotBefore -Descending | Select-Object -First 1

if ($cert) {
    Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $pwd
    Write-Host "[SUCCÈS] Certificat prêt : $PfxPath" -ForegroundColor Green
    Write-Host "Action : Transférez ce fichier sur OPT-BKR01." -ForegroundColor White
} else {
    Write-Host "[ERREUR] Certificat non trouvé dans le magasin Personnel." -ForegroundColor Red
}