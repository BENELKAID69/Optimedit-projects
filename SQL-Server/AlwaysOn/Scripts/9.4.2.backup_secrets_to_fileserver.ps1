<#
    9.4.2.backup_secrets_to_fileserver.ps1
    Objet     : Sauvegarder la clé AES et les secrets chiffrés vers OPT-FS03,
                dans un sous-dossier par nœud.
    Noeuds    : SQLS01 + SQLS02 (exécuter sur chaque nœud localement)
    Prérequis : 
      - Partage \\OPT-FS03\SQLSecrets$ créé avec ACL strictes
      - Clé AES et fichiers .enc présents sur le nœud local
      - Droits d'écriture sur le partage de sauvegarde

    PRINCIPE :
    - Crée un sous-dossier par nœud : \\OPT-FS03\SQLSecrets$\SQLS01\
    - Copie la clé AES et les fichiers .enc dans ce sous-dossier,
      en conservant leur nom d'origine (aes.key, sql-service-pwd.enc, etc.).
    - Par défaut, ne copie pas un fichier déjà présent (protection).
    - Le paramètre -Force force la copie (écrasement).

    STRUCTURE DE SAUVEGARDE :

    \\OPT-FS03\SQLSecrets$\
    ├── SQLS01\
    │   ├── aes.key
    │   ├── sql-service-pwd.enc
    │   ├── tde-masterkey-pwd.enc
    │   ├── tde-cert-pwd.enc
    │   └── iis-svc-pwd.enc
    └── SQLS02\
        ├── aes.key
        ├── sql-service-pwd.enc
        ├── tde-masterkey-pwd.enc
        ├── tde-cert-pwd.enc
        └── iis-svc-pwd.enc

    EXEMPLES D'EXÉCUTION :

    # Sauvegarde standard (copie les fichiers absents ou modifiés)
    .\9.4.0.backup_secrets_to_fileserver.ps1

    # Forcer la copie (écrase les fichiers existants côté serveur)
    .\9.4.0.backup_secrets_to_fileserver.ps1 -Force

    # Spécifier un autre partage de sauvegarde
    .\9.4.0.backup_secrets_to_fileserver.ps1 -BackupShare "\\OPT-FS03\AutrePartage$"

    NOTES :
    - Cette sauvegarde est un acte DÉLIBÉRÉ de l'administrateur.
    - Ne pas automatiser : la clé AES ne doit pas circuler sans contrôle.
    - Voir section 9.5 pour la sauvegarde alternative dans KeePass.
    - Voir section 9.4.1 (à venir) pour la procédure de restauration.
#>

param(
    [string]$SecureFolder = "C:\ProgramData\SQLSecrets",
    [string]$BackupShare  = "\\OPT-FS03\SQLSecrets$",
    [switch]$Force
)

# --- Vérification du dossier local ---
if (!(Test-Path $SecureFolder)) {
    Write-Error "Dossier local introuvable : $SecureFolder"
    exit 1
}

# --- Vérification du partage de sauvegarde ---
if (!(Test-Path $BackupShare)) {
    Write-Error "Partage introuvable : $BackupShare. Vérifier les droits d'accès."
    exit 1
}

# --- Création du sous-dossier par nœud ---
# Objectif : isoler les sauvegardes de SQLS01 et SQLS02 dans des dossiers
# distincts, pour éviter tout écrasement entre les deux nœuds.
$NodeFolder = Join-Path $BackupShare $env:COMPUTERNAME
if (!(Test-Path $NodeFolder)) {
    New-Item -Path $NodeFolder -ItemType Directory -Force | Out-Null
    Write-Host "Sous-dossier créé : $NodeFolder" -ForegroundColor Green
} else {
    Write-Host "Sous-dossier existant : $NodeFolder" -ForegroundColor Yellow
}

# --- Copie des fichiers ---
# Tous les fichiers du dossier local sont copiés :
#   - aes.key (clé AES 256 bits)
#   - *.enc (secrets chiffrés nommés explicitement)
# Les fichiers conservent leur nom d'origine.
$Files = Get-ChildItem -Path $SecureFolder -File

if ($Files.Count -eq 0) {
    Write-Warning "Aucun fichier à sauvegarder dans $SecureFolder."
    exit 0
}

$CountCopied = 0
$CountSkipped = 0

foreach ($File in $Files) {

    $Destination = Join-Path $NodeFolder $File.Name

    # Protection contre l'écrasement accidentel
    if ((Test-Path $Destination) -and (-not $Force)) {
        Write-Host "Déjà présent (ignoré) : $($File.Name)" -ForegroundColor Yellow
        $CountSkipped++
        continue
    }

    # Copie du fichier avec son nom d'origine
    Copy-Item -Path $File.FullName -Destination $Destination -Force
    Write-Host "Sauvegardé : $($File.Name) -> $Destination" -ForegroundColor Green
    $CountCopied++
}

# --- Résumé ---
Write-Host ""
Write-Host "Sauvegarde des secrets terminée." -ForegroundColor Cyan
Write-Host "  Nœud source       : $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "  Fichiers copiés   : $CountCopied" -ForegroundColor Cyan
Write-Host "  Fichiers ignorés  : $CountSkipped" -ForegroundColor Cyan
Write-Host "  Destination       : $NodeFolder" -ForegroundColor Cyan

# --- Avertissement de sécurité ---
Write-Host ""
Write-Host "RAPPEL : le partage $BackupShare contient la clé AES." -ForegroundColor Yellow
Write-Host "         Vérifier régulièrement les ACL et l'audit d'accès." -ForegroundColor Yellow
Write-Host "         La clé AES de SQLS01 ne peut PAS déchiffrer les .enc de SQLS02." -ForegroundColor Yellow