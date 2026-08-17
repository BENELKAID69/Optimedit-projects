# 02.ConvertTo-SecureString-aes.ps1
<#
.SYNOPSIS
    Chiffrement initial des secrets de service.

.DESCRIPTION
    [SYNAPS-INFRA]
    Chiffre les mots de passe (Compte de déploiement et PFX) à l'aide de la clé AES.
    Les résultats sont stockés dans des fichiers .enc.
    
.NOTES
    IMPORTANT : Supprimer ce script immédiatement après exécution (contient des secrets en clair).
#>
$keyPath = "C:\CertifyScripts\secure\aes.key"
$secureFolder = "C:\CertifyScripts\secure"

if (!(Test-Path $keyPath)) {
    Write-Error "Fichier aes.key introuvable. Exécutez d'abord 01.Gen_AES-Key.ps11."
    exit 1
}

# Chargement de la clé AES 256 bits
$key = Get-Content $keyPath -Encoding Byte

# Vérification de la taille de la clé
if ($key.Length -ne 32) {
    Write-Error "Clé AES invalide : taille incorrecte ($($key.Length) bytes)."
    exit 1
}

# Chiffrement du mot de passe du compte de déploiement
$deployPwd = 'Password_SVC_Ici' | ConvertTo-SecureString -AsPlainText -Force
$deployPwdEncPath = Join-Path $secureFolder "deploy-pwd.enc"
$deployPwd | ConvertFrom-SecureString -Key $key | Set-Content $deployPwdEncPath

# Chiffrement du mot de passe PFX
$pfxPwd = 'Password_PFX_Ici' | ConvertTo-SecureString -AsPlainText -Force
$pfxPwdEncPath = Join-Path $secureFolder "pfx-pwd.enc"
$pfxPwd | ConvertFrom-SecureString -Key $key | Set-Content $pfxPwdEncPath

Write-Output "Secrets générés et chiffrés avec succès."
