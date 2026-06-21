<#
.SYNOPSIS
    Configuration WinRM HTTPS par OID strict et provisionnement du compte de service Ansible.
.DESCRIPTION
    1. Crée/Vérifie le compte AD admin_ansible avec durcissement AES256.
    2. Vérifie la présence du certificat via son OID. Si absent, le demande à la CA.
    3. Nettoie les anciens listeners HTTPS via le provider WSMan.
    4. Crée le listener sécurisé et ouvre le pare-feu.
#>

# ==============================================================================
# 1. Variables d'Environnement et OID cible
# ==============================================================================
$CurrentFQDN = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()
$TemplateName = "Ansible-WinRM-FQDN-SERVERS"
$TargetOID = "1.3.6.1.4.1.311.21.8.221933.7254082.8798593.2679569.10943928.7.13152591.13092389"

$UserName   = "admin_ansible"
$DomainName = "OPTIMEDIT.EU"

# Génération d'un mot de passe sécurisé pour le compte s'il doit être créé
$PasswordPlain = "SecureAnsiblePassword2026!"
$Password = ConvertTo-SecureString $PasswordPlain -AsPlainText -Force

# ==============================================================================
# 2. Gestion du Compte de Service dans l'Active Directory
# ==============================================================================
Write-Host "--- Vérification du compte AD : $UserName ---" -ForegroundColor Cyan

if (-not (Get-ADUser -Filter "SamAccountName -eq '$UserName'")) {
    New-ADUser -Name $UserName -SamAccountName $UserName `
               -AccountPassword $Password -Enabled $true `
               -PasswordNeverExpires $true `
               -DisplayName "Ansible Root Account"
    
    # Sécurisation Kerberos et délégation
    Set-ADUser -Identity $UserName -KerberosEncryptionType AES256
    Set-ADUser -Identity $UserName -AccountNotDelegated $false
    Write-Host "[OK] Compte $UserName créé avec succès." -ForegroundColor Green
} else {
    Write-Host "Le compte $UserName existe déjà." -ForegroundColor Yellow
}

# ==============================================================================
# 3. Recherche ou Demande Immédiate du Certificat par OID (Méthode Forte)
# ==============================================================================
Write-Host "`nAnalyse du magasin pour localiser le modèle par OID..." -ForegroundColor Cyan

$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    $isMatch = $false
    $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
    if ($null -ne $templateExt) {
        if ($templateExt.Format(0) -match $TargetOID) { $isMatch = $true }
    }
    return $isMatch
} | Sort-Object NotBefore -Descending | Select-Object -First 1

# Si le certificat n'existe pas, on le demande immédiatement à la CA
if ($null -eq $cert) {
    Write-Host "Aucun certificat trouvé pour l'OID $TargetOID. Demande immédiate à la CA..." -ForegroundColor Yellow
    try {
        Get-Certificate -Template $TemplateName -Url "LDAP:" -CertStoreLocation "Cert:\LocalMachine\My" | Out-Null
        
        # Ré-interrogation du magasin après génération
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
            $isMatch = $false
            $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
            if ($null -ne $templateExt) {
                if ($templateExt.Format(0) -match $TargetOID) { $isMatch = $true }
            }
            return $isMatch
        } | Sort-Object NotBefore -Descending | Select-Object -First 1
    } catch {
        Write-Error "CRITIQUE : Échec lors de la demande automatique du certificat à la CA !"
        exit 1
    }
}

if ($null -eq $cert) {
    Write-Error "CRITIQUE : Impossible de valider le certificat même après tentative de génération !"
    exit 1
}

$CurrentThumbprint = $cert.Thumbprint
Write-Host "[OK] Certificat conforme identifié : $CurrentFQDN ($CurrentThumbprint)" -ForegroundColor Green

# ==============================================================================
# 4. Nettoyage et Création du Listener HTTPS
# ==============================================================================
Write-Host "`nNettoyage des anciens écouteurs HTTPS via WSMan..." -ForegroundColor Blue

Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -like "TRANSPORT=HTTPS" } | ForEach-Object {
    Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue
}

Write-Host "Création du nouveau Listener WinRM HTTPS..." -ForegroundColor Blue
$valueset = @{ Hostname = $CurrentFQDN; CertificateThumbprint = $CurrentThumbprint }
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Transport="HTTPS"; Address="*"} -ValueSet $valueset | Out-Null

# ==============================================================================
# 5. Configuration du Pare-feu Windows
# ==============================================================================
if (!(Get-NetFirewallRule -Name "AllowWinRMHTTPS" -ErrorAction SilentlyContinue)) {
    Write-Host "Ouverture du port pare-feu 5986..." -ForegroundColor Blue
    New-NetFirewallRule -DisplayName "Allow WinRM HTTPS" -Name "AllowWinRMHTTPS" -Profile Any -LocalPort 5986 -Protocol TCP -Action Allow -Direction Inbound | Out-Null
}

# ==============================================================================
# 6. Finalisation
# ==============================================================================
Restart-Service winrm -Force
Write-Host "`n=== ARCHITECTURE ET WINRM CONFIGURÉS AVEC SUCCÈS ===" -ForegroundColor Green