<#
    3.3.3.3.CheckPrivateKeyPermissions.ps1
    Objet   : Vérifier les permissions sur la clé privée du certificat SSL.
    Noeuds  : SQLS01 + SQLS02
    Prérequis : Certificat SSL présent dans LocalMachine\My

    PRINCIPE :
    - Détecte automatiquement le type de clé (CNG ou CSP).
    - Récupère le nom du fichier de clé privée.
    - Affiche les permissions (ACL) sur ce fichier.
    - Vérifie que SVC_SQL_Engine a bien accès.

    EXEMPLES D'EXÉCUTION :

    .\3.3.3.3.CheckPrivateKeyPermissions.ps1
#>

$Hostname = $env:COMPUTERNAME
$Cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*$Hostname.optimedit.eu*" }  #  domaine a adapter
if (-not $Cert) {
    Write-Host "[ECHEC] Certificat introuvable pour $Hostname.optimedit.eu" -ForegroundColor Red
    exit 1
}

Write-Host "Certificat : $($Cert.Subject)"
Write-Host "Thumbprint : $($Cert.Thumbprint)"
Write-Host ""

# --- Détecter le type de clé (CNG ou CSP) ---
$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)

if ($rsa -is [System.Security.Cryptography.RSACng]) {
    Write-Host "Type : CNG (Key Storage Provider)" -ForegroundColor Cyan
    $uniqueName = $rsa.Key.UniqueName
    $keyFolder = "C:\ProgramData\Microsoft\Crypto\Keys"
} else {
    Write-Host "Type : CSP (Cryptographic Service Provider)" -ForegroundColor Cyan
    $uniqueName = $rsa.CspKeyContainerInfo.UniqueKeyContainerName
    $keyFolder = "C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys"
}

Write-Host "Nom de clé : $uniqueName"
Write-Host ""

$keyFile = Join-Path $keyFolder $uniqueName
Write-Host "Fichier de clé : $keyFile"
Write-Host "Existe : $(Test-Path $keyFile)"
Write-Host ""

if (Test-Path $keyFile) {
    Write-Host "Permissions :" -ForegroundColor Yellow
    $permissions = Get-Acl $keyFile | Select-Object -ExpandProperty Access | 
        Where-Object { $_.IdentityReference -like "*SVC_SQL_Engine*" }

    if ($permissions) {
        Write-Host "  [OK] Permissions trouvées pour SVC_SQL_Engine :" -ForegroundColor Green
        $permissions | Format-Table IdentityReference, FileSystemRights, AccessControlType -AutoSize
    } else {
        Write-Host "  [AVERTISSEMENT] Aucune permission explicite pour SVC_SQL_Engine" -ForegroundColor Yellow
        Write-Host "         → Vérifier manuellement via certlm.msc" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Toutes les permissions :" -ForegroundColor Gray
        Get-Acl $keyFile | Select-Object -ExpandProperty Access | 
            Format-Table IdentityReference, FileSystemRights, AccessControlType -AutoSize
    }
} else {
    Write-Host "  [ECHEC] Fichier de clé introuvable" -ForegroundColor Red
}