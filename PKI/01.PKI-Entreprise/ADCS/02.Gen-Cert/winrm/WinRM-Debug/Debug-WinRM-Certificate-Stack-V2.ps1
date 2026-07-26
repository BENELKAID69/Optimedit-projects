<#
.SYNOPSIS
    Outil de diagnostic AVANCÉ pour l'infrastructure WinRM HTTPS d'Optimedit.
    Détection automatique par OID et Inventaire du magasin.
#>

# --- Configuration Optimedit ---
$TargetOID = "1.3.6.1.4.1.311.21.8.221933.7254082.8798593.2679569.10943928.7.13152591.13092389"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "    DIAGNOSTIC AUTO-IDENTIFIÉ WINRM HTTPS - OPTIMEDIT            " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# --- 0. RÉCUPÉRATION AUTOMATIQUE DU CERTIFICAT CIBLE ---
Write-Host "[0] RECHERCHE DU CERTIFICAT PAR OID" -ForegroundColor Yellow
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
    $templateExt.Format(0) -match $TargetOID
} | Sort-Object NotBefore -Descending | Select-Object -First 1

if ($null -eq $cert) {
    Write-Host "[-] ERREUR CRITIQUE : Aucun certificat avec l'OID $TargetOID trouvé !" -ForegroundColor Red
    Write-Host "[!] Arrêt du diagnostic spécifique. Passage à l'inventaire final." -ForegroundColor Gray
} else {
    $TargetThumbprint = $cert.Thumbprint
    Write-Host "[+] Certificat cible identifié : $($cert.Subject) ($TargetThumbprint)" -ForegroundColor Green

    # --- 1. COUCHE CERTIFICAT (Détails) ---
    Write-Host "`n[1] INSPECTION DU CERTIFICAT" -ForegroundColor Yellow
    $cert | Select-Object Subject, HasPrivateKey, Thumbprint, NotAfter | Format-List | Out-String | Write-Host
    certutil -v -store my "$TargetThumbprint" | Select-String "Fournisseur", "Conteneur", "Hachage" | Write-Host

    # --- 2. COUCHE RÉSEAU (HTTP.SYS) ---
    Write-Host "`n[2] BINDINGS HTTP.SYS (Port 5986)" -ForegroundColor Yellow
    $netshSsl = netsh http show sslcert ipport=0.0.0.0:5986
    if ($netshSsl -match $TargetThumbprint) {
        Write-Host "[+] Binding OK : Le port est lié à la bonne empreinte." -ForegroundColor Green
    } else {
        Write-Host "[-] ERREUR BINDING : Le port 5986 est mal lié !" -ForegroundColor Red
    }

    # --- 3. COUCHE IDENTITÉ (ACL) ---
    Write-Host "`n[3] PERMISSIONS CLÉ PRIVÉE" -ForegroundColor Yellow
    try {
        $rsaCert = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        $keyName = $rsaCert.Properties.Key.UniqueName
        $path = "$env:ProgramData\Microsoft\Crypto\Keys\$keyName"
        if (Test-Path $path) {
            Write-Host "[+] Clé : $path" -ForegroundColor Gray
            Get-Acl $path | Select-Object -ExpandProperty Access | Format-Table IdentityReference, FileSystemRights -AutoSize | Out-String | Write-Host
        }
    } catch { Write-Host "[-] Impossible d'analyser les ACL." -ForegroundColor Red }

    # --- 4. COUCHE WINRM (Listener) ---
    Write-Host "`n[4] CONFIGURATION WINRM" -ForegroundColor Yellow
    winrm enumerate winrm/config/listener | Select-String "Transport = HTTPS", "CertificateThumbprint", "Hostname" | Write-Host
}

# --- SYNTHÈSE DU MAGASIN (AUDIT FINAL) ---
Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "    INVENTAIRE COMPLET DU MAGASIN PERSONNEL (LocalMachine\My)     " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$allCerts = Get-ChildItem Cert:\LocalMachine\My
$count = $allCerts.Count

Write-Host "[i] Nombre total de certificats trouvés : $count" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------------"

$allCerts | Select-Object @{N="Sujet";E={$_.Subject}}, 
                         @{N="Empreinte";E={$_.Thumbprint}}, 
                         @{N="Expiration";E={$_.NotAfter}},
                         @{N="Cible_WinRM";E={if($_.Thumbprint -eq $TargetThumbprint){"OUI"}else{"non"}}} | 
          Sort-Object Expiration | Format-Table -AutoSize

Write-Host "==================================================================" -ForegroundColor Cyan