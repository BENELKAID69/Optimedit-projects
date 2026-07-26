
# 01.Gen_AES-Key.ps1
<#
.SYNOPSIS
    Génération et sécurisation de la clé AES principale.

.DESCRIPTION
    [SYNAPS-INFRA]
    Génère une clé AES 256 bits unique pour le chiffrement des secrets.
    Applique des ACL strictes (SID S-1-5-18 et S-1-5-32-544) pour garantir 
    que seul le service système et les administrateurs peuvent y accéder.
#>

$secureFolder = "C:\CertifyScripts\secure"
$keyPath = Join-Path $secureFolder "aes.key"

# 1. Génération de la clé AES 256 bits
$key = New-Object byte[] 32
[System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($key)
$key | Set-Content -Path $keyPath -Encoding Byte

# 2. Application des droits via SID
if (Test-Path $keyPath) {

    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
    $sidAdmin  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")

    $acl = Get-Acl $keyPath
    $acl.SetAccessRuleProtection($true, $false)

    # IMPORTANT : pas d'héritage sur un fichier
    $rule1 = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidSystem, "FullControl", "None", "None", "Allow"
    )

    $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmin, "FullControl", "None", "None", "Allow"
    )

    $acl.SetAccessRule($rule1)
    $acl.SetAccessRule($rule2)

    Set-Acl -Path $keyPath -AclObject $acl

    Write-Output "Clé AES générée et permissions appliquées avec succès."
}
else {
    Write-Error "Échec : Le fichier $keyPath n'a pas été créé."
}
