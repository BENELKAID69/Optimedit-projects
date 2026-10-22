<#
    3.0.0.manage_secrets.ps1
    Objet     : Générer la clé AES, chiffrer un secret nommé, appliquer les ACL.
    Noeuds    : SQLS01 + SQLS02 (exécuter sur chaque nœud localement)
    Prérequis : PowerShell 5.1

    PRINCIPE :
    - La clé AES 256 bits est générée LOCALEMENT sur chaque nœud.
    - Les secrets sont chiffrés dans des fichiers .enc nommés par usage.
    - Les ACL appliquées : SYSTEM + Administrateurs (FullControl) 
                          + OPTIMEDIT\SVC_SQL_Agent (Read uniquement).
    - Aucun mot de passe en clair n'est jamais écrit sur disque.

    EXEMPLES D'EXÉCUTION :
    .\3.0.0.manage_secrets.ps1 -GenerateKey
    .\3.0.0.manage_secrets.ps1 -SecretName "sql-service-pwd"
    .\3.0.0.manage_secrets.ps1 -ListSecrets
#>

param(
    [string]$SecureFolder = "C:\ProgramData\SQLSecrets",
    [switch]$GenerateKey,
    [string]$SecretName,
    [switch]$Force,
    [switch]$ListSecrets
)

# --- Constantes ---
$KeyPath = Join-Path $SecureFolder "aes.key"

# --- SID bien connus ---
$SidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
$SidAdmin  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")

# --- Compte de service SQL Agent (lecture seule sur les secrets) ---
# Necessaire pour que le job PowerShell "DBA - Send Alert Email" puisse lire
# le secret smtp-ovh-pwd.enc sous l'identite SVC_SQL_Agent.
$AgentAccount = "OPTIMEDIT\SVC_SQL_Agent"

# --- Fonction : appliquer des ACL strictes ---
function Set-StrictAcl {
    param(
        [string]$Path,
        [switch]$IsFolder
    )

    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)   # desactive l'heritage

    # SYSTEM : controle total
    $ruleSys = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $SidSystem, "FullControl", "None", "None", "Allow"
    )
    $acl.SetAccessRule($ruleSys)

    # Administrateurs : controle total
    $ruleAdm = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $SidAdmin, "FullControl", "None", "None", "Allow"
    )
    $acl.SetAccessRule($ruleAdm)

    # SVC_SQL_Agent : lecture seule (dossier : herite, fichier : direct)
    try {
        if ($IsFolder) {
            $ruleAgent = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $AgentAccount, "ReadAndExecute", "ContainerInherit, ObjectInherit", "None", "Allow"
            )
        } else {
            $ruleAgent = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $AgentAccount, "Read", "None", "None", "Allow"
            )
        }
        $acl.SetAccessRule($ruleAgent)
    }
    catch {
        Write-Warning "ACL SQL Agent non appliquee sur $Path : $($_.Exception.Message)"
    }

    Set-Acl -Path $Path -AclObject $acl
}

# --- Étape 0 : création du dossier sécurisé ---
if (!(Test-Path $SecureFolder)) {
    New-Item -Path $SecureFolder -ItemType Directory -Force | Out-Null
    Set-StrictAcl -Path $SecureFolder -IsFolder
    Write-Host "Dossier créé et sécurisé : $SecureFolder" -ForegroundColor Green
}

# --- Étape 1 : génération de la clé AES 256 bits ---
if ($GenerateKey) {
    if (Test-Path $KeyPath) {
        Write-Host "Clé AES déjà présente : $KeyPath (ignorée)" -ForegroundColor Yellow
        # Reapplique les ACL pour etre sur que SVC_SQL_Agent peut lire
        Set-StrictAcl -Path $KeyPath
        Write-Host "ACL reappliquees sur $KeyPath" -ForegroundColor Cyan
    } else {
        $key = New-Object byte[] 32
        [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($key)
        $key | Set-Content -Path $KeyPath -Encoding Byte
        Set-StrictAcl -Path $KeyPath
        Write-Host "Clé AES générée et sécurisée : $KeyPath" -ForegroundColor Green
    }
}

# --- Étape 2 : listage des secrets existants ---
if ($ListSecrets) {
    Write-Host "Secrets chiffrés présents dans $SecureFolder :" -ForegroundColor Cyan
    Get-ChildItem -Path $SecureFolder -Filter "*.enc" |
        Select-Object Name, Length, LastWriteTime |
        Format-Table -AutoSize
    return
}

# --- Étape 3 : chiffrement d'un secret nommé ---
if ($SecretName) {

    if (!(Test-Path $KeyPath)) {
        Write-Error "Clé AES introuvable. Exécuter avec -GenerateKey d'abord."
        exit 1
    }

    $key = Get-Content $KeyPath -Encoding Byte
    if ($key.Length -ne 32) {
        Write-Error "Clé AES invalide : taille incorrecte ($($key.Length) bytes)."
        exit 1
    }

    $EncPath = Join-Path $SecureFolder "$SecretName.enc"

    if ((Test-Path $EncPath) -and (-not $Force)) {
        Write-Error "Le secret '$SecretName' existe déjà : $EncPath. Utiliser -Force pour écraser."
        exit 1
    }

    $securePwd = Read-Host -Prompt "Saisir la valeur du secret '$SecretName'" -AsSecureString

    $securePwd | ConvertFrom-SecureString -Key $key | Set-Content $EncPath

    # ACL : SYSTEM + Admin (FullControl) + SVC_SQL_Agent (Read)
    Set-StrictAcl -Path $EncPath

    Write-Host "Secret chiffré : $EncPath" -ForegroundColor Green
    Write-Host "  -> ACL appliquees : SYSTEM, Administrateurs, $AgentAccount (Read)" -ForegroundColor Cyan
}

Write-Host "Gestion des secrets terminée." -ForegroundColor Cyan