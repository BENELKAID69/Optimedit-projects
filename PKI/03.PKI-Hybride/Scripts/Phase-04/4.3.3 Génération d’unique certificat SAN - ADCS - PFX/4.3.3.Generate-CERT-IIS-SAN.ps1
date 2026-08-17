# ===============================================================================================================
# Nom script : 4.3.3.Generate-CERT-IIS-SAN.ps1
# Usage : POC Infrastructure IIS - Génération du Certificat SAN et FQDN de l'ensemble des serveurs backends IIS
# Rôle : À exécuter sur le DC ou une machine d'administration
# Version 3
# Date 07/08/2026
# ===============================================================================================================

# --- SECTION À ADAPTER POUR AUTRE CLIENT ------------------
$TargetCN   = "iis.optimedit.eu"  # Doit correspondre au CN de fichier .inf
$FqdnCa     = "DC03.optimedit.eu"  
$CaName     = "Optimedit-CA3"   # Corrigé d'après tes logs de certification actifs
$InfPath    = "C:\Scripts\ADCS\4.3.3.IIS-CERT-SAN\IIS-CERT-SAN-Certificat.inf"    
$ClearPwd   = "Mot_de_passe_PFX"     # Ton mot de passe PFX
# ----------------------------------------------------------

#Test-Path $InfPath

Write-Host "--- PRÉPARATION DU FICHIER CONFIGURATION ---" -ForegroundColor Cyan

# Lecture et réécriture en ASCII pour garantir la compatibilité certreq
if (Test-Path $InfPath) {
    $infContent = Get-Content -Path $InfPath -Raw
    Set-Content -Path $InfPath -Value $infContent -Encoding ASCII
    Write-Host "[OK] Fichier .INF préparé en ASCII." -ForegroundColor Green
} else {
    Write-Error "[STOP] Fichier source $InfPath introuvable !"; break
}

$ReqPath = $InfPath.Replace(".inf", ".req")
$CerPath = $InfPath.Replace(".inf", ".cer")
$PfxPath = $InfPath.Replace(".inf", ".pfx")
$ConfigString = "$FqdnCa\$CaName"

Write-Host "--- DÉBUT DU PROCESSUS DE CERTIFICATION ---" -ForegroundColor Cyan

# 1. Génération de la requête (CSR) avec argument -f pour écraser automatiquement l'ancien fichier
Write-Host "[EXEC] Génération de la requête .req..." -ForegroundColor Yellow
certreq -new -f $InfPath $ReqPath

# 2. Soumission à l'Autorite de Certification avec argument -f
Write-Host "[EXEC] Soumission au CA ($ConfigString)..." -ForegroundColor Yellow
certreq -submit -f -config $ConfigString $ReqPath $CerPath

if (-not (Test-Path $CerPath)) {
    Write-Error "[STOP] La CA a refusé la demande ou n'a pas généré le fichier .cer. Arrêt."; break
}

# 3. Acceptation du certificat
Write-Host "[EXEC] Installation locale du certificat..." -ForegroundColor Yellow
certreq -accept $CerPath

# 4. Exportation PFX automatique
Write-Host "`n--- EXPORTATION PFX ---" -ForegroundColor Cyan
$SecurePwd = ConvertTo-SecureString $ClearPwd -AsPlainText -Force

# Recherche stricte basée sur la clé privée présente
$cert = Get-ChildItem Cert:\LocalMachine\My | 
        Where-Object { $_.Subject -match [regex]::Escape($TargetCN) -and $_.HasPrivateKey } | 
        Sort-Object NotBefore -Descending | Select-Object -First 1

if ($cert) {
    Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $SecurePwd -Force
    Write-Host "[SUCCÈS] Certificat PFX prêt et exporté : $PfxPath" -ForegroundColor Green
    Write-Host "Action : Tu peux maintenant transférer ce fichier PFX sur tes serveurs cibles." -ForegroundColor White
} else {
    Write-Host "[ERREUR] Nouveau certificat avec clé privée non trouvé dans le magasin local." -ForegroundColor Red
}