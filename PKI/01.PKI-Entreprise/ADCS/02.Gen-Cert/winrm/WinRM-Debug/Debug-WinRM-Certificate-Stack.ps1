<#
.SYNOPSIS
    Outil de diagnostic pour l'infrastructure WinRM HTTPS d'Optimedit.
    Analyse les 4 couches : Magasin Certificat, HTTP.sys, ACL Système et WinRM.
#>

$TargetThumbprint = "56739F8CEF6E7766D9EC9B2DC5A3C6CA17949759"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   DIAGNOSTIC DE LA CHAÎNE WINRM HTTPS - OPTIMEDIT            " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# --- 1. COUCHE CERTIFICAT (Magasin LocalMachine) ---
Write-Host "`n[1] INSPECTION DU MAGASIN DE CERTIFICATS" -ForegroundColor Yellow
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $TargetThumbprint }

if ($null -eq $cert) {
    Write-Host "[-] ERREUR : Certificat introuvable dans LocalMachine\My." -ForegroundColor Red
} else {
    Write-Host "[+] Certificat trouvé : $($cert.Subject)" -ForegroundColor Green
    $cert | Select-Object Subject, HasPrivateKey, Thumbprint, NotAfter | Format-List | Out-String | Write-Host
    
    Write-Host "[*] Détails techniques (Fournisseur & Conteneur) :" -ForegroundColor Gray
    certutil -v -store my "$TargetThumbprint" | Select-String "Fournisseur", "Conteneur", "Hachage" | Write-Host
}

# --- 2. COUCHE RÉSEAU BASSE (HTTP.SYS) ---
Write-Host "`n[2] INSPECTION DES BINDINGS HTTP.SYS (Netsh)" -ForegroundColor Yellow
$netshSsl = netsh http show sslcert ipport=0.0.0.0:5986
if ($netshSsl -match $TargetThumbprint) {
    Write-Host "[+] Le port 5986 est correctement lié au Thumbprint cible." -ForegroundColor Green
} else {
    Write-Host "[-] Le port 5986 n'est pas lié ou utilise un autre certificat." -ForegroundColor Red
}
Write-Host "[*] État actuel du port 5986 :" -ForegroundColor Gray
$netshSsl | Write-Host

Write-Host "`n[*] Vérification des sockets TCP actives (Port 5986) :" -ForegroundColor Gray
$connection = Get-NetTCPConnection -LocalPort 5986 -ErrorAction SilentlyContinue
if ($null -ne $connection) {
    $connection | Select-Object LocalAddress, LocalPort, State, OwningProcess | Write-Host
} else {
    Write-Host "[i] Aucune application n'écoute activement sur le port 5986." -ForegroundColor Gray
}

# --- 3. COUCHE IDENTITÉ ET DROITS (ACL de la clé privée) ---
Write-Host "`n[3] INSPECTION DES PERMISSIONS SUR LA CLÉ PRIVÉE" -ForegroundColor Yellow
try {
    $rsaCert = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $keyName = $rsaCert.Properties.Key.UniqueName
    
    # Chemins probables (KSP ou RSA MachineKeys)
    $paths = @(
        "$env:ProgramData\Microsoft\Crypto\Keys\$keyName",
        "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys\$keyName",
        "$env:ProgramData\Microsoft\Crypto\SystemKeys\$keyName"
    )

    $keyFound = $false
    foreach ($path in $paths) {
        if (Test-Path $path) {
            Write-Host "[+] Fichier de clé identifié : $path" -ForegroundColor Green
            Get-Acl $path | Select-Object -ExpandProperty Access | Format-Table IdentityReference, AccessControlType, FileSystemRights -AutoSize | Out-String | Write-Host
            $keyFound = $true
            break
        }
    }
    
    if (-not $keyFound) {
        Write-Host "[-] ALERTE : Impossible de localiser physiquement le fichier de clé sur le disque." -ForegroundColor Red
    }
} catch {
    Write-Host "[-] ERREUR : Impossible d'extraire les propriétés de la clé privée." -ForegroundColor Red
}

# --- 4. COUCHE APPLICATIVE (Service WinRM) ---
Write-Host "`n[4] CONFIGURATION LOGIQUE WINRM" -ForegroundColor Yellow
Write-Host "[*] Listeners enregistrés :" -ForegroundColor Gray
winrm enumerate winrm/config/listener | Write-Host

Write-Host "`n[*] Paramètres du service WinRM :" -ForegroundColor Gray
winrm get winrm/config/service | Select-String "AllowUnencrypted", "Auth", "CertificateThumbprint" | Write-Host

Write-Host "`n[*] Mappings de certificats (si existants) :" -ForegroundColor Gray
winrm enumerate winrm/config/service/certmapping 2>$null | Write-Host

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "               FIN DU DIAGNOSTIC                              " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan


<#
Comment interpréter les résultats:

    Dans la section [2] (Netsh) : Si netsh montre le certificat mais que la section [4] (WinRM) ne montre pas de Listener Transport=HTTPS, c'est que WinRM ignore le binding du système.

    Dans la section [3] (ACL) : C'est le point critique. Cherche NT AUTHORITY\NETWORK SERVICE (ou SERVICE RÉSEAU).

        S'il n'est pas dans la liste avec Read (Lecture), WinRM ne pourra jamais "voir" le certificat, d'où l'erreur "Certificat introuvable".

    Dans la section [4] (WinRM) : Si CertificateThumbprint sous service est rempli avec une ancienne valeur, cela peut créer un conflit majeur avec le listener que tu essaies de créer.

Ce script te donnera une "photo" exacte de l'état du serveur sans rien casser.

#>