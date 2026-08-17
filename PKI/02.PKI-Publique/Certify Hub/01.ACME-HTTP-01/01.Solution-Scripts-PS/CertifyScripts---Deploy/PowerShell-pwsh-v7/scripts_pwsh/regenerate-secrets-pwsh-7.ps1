# ============================================================
# Script : regenerate-secrets.ps1
# Objectif : Générer une clé AES + recréer les secrets .enc
# Compatible : PowerShell 7 (pwsh.exe)
# Auteur : optimed IT
# ============================================================

$secureFolder = "C:\CertifyScripts\secure_pwsh"

if (!(Test-Path $secureFolder)) {
    New-Item -ItemType Directory -Path $secureFolder | Out-Null
}

Write-Host "=== Génération de la clé AES 256 bits ==="

# 1️⃣ Générer une nouvelle clé AES (32 bytes = 256 bits)
$Key = New-Object Byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Key)

# Sauvegarde en binaire
Set-Content -Path "$secureFolder\aes.key" -Value $Key -Encoding Byte
Write-Host "Clé AES générée : $secureFolder\aes.key"

# 2️⃣ Chiffrer le mot de passe du compte svc-certdeploy
Write-Host "`n=== Saisir le mot de passe du compte svc-certdeploy ==="
$SecurePwd = Read-Host "Mot de passe svc-certdeploy" -AsSecureString

$Encrypted = ConvertFrom-SecureString -SecureString $SecurePwd -Key $Key
Set-Content -Path "$secureFolder\deploy-pwd.enc" -Value $Encrypted
Write-Host "Mot de passe svc-certdeploy chiffré : $secureFolder\deploy-pwd.enc"

# 3️⃣ Chiffrer le mot de passe du PFX
Write-Host "`n=== Saisir le mot de passe du PFX ==="
$SecurePfxPwd = Read-Host "Mot de passe du PFX" -AsSecureString

$EncryptedPfx = ConvertFrom-SecureString -SecureString $SecurePfxPwd -Key $Key
Set-Content -Path "$secureFolder\pfx-pwd.enc" -Value $EncryptedPfx
Write-Host "Mot de passe PFX chiffré : $secureFolder\pfx-pwd.enc"

Write-Host "`n=== FIN : Secrets régénérés avec succès ==="
