
# 03.secure-enc-file.ps1
<#
.SYNOPSIS
    Sécurisation des fichiers de secrets chiffrés.

.DESCRIPTION
    [SYNAPS-INFRA]
    Applique les permissions NTFS (ACL) strictes aux fichiers .enc générés.
    Verrouille l'accès aux comptes SYSTEM et Administrateurs uniquement.
    
.NOTES
    IMPORTANT : Supprimer ce script immédiatement après exécution.
#>

$secureFolder = "C:\CertifyScripts\secure"

$deployPwdEncPath = Join-Path $secureFolder "deploy-pwd.enc"
$pfxPwdEncPath    = Join-Path $secureFolder "pfx-pwd.enc"

# Vérification des fichiers
foreach ($file in @($deployPwdEncPath, $pfxPwdEncPath)) {
    if (!(Test-Path $file)) {
        Write-Error "Fichier introuvable : $file. Exécutez d'abord 02.ConvertTo-SecureString-aes.ps1."
        exit 1
    }
}

# SID SYSTEM + Administrateurs
$sidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
$sidAdmin  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")

foreach ($file in @($deployPwdEncPath, $pfxPwdEncPath)) {

    $acl = Get-Acl $file
    $acl.SetAccessRuleProtection($true, $false)

    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidSystem, "FullControl", "None", "None", "Allow"
    )

    $ruleAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmin, "FullControl", "None", "None", "Allow"
    )

    $acl.SetAccessRule($ruleSystem)
    $acl.SetAccessRule($ruleAdmin)

    Set-Acl -Path $file -AclObject $acl

    Write-Output "Permissions sécurisées appliquées à : $file"
}

Write-Output "ACL appliquées avec succès aux fichiers chiffrés."
