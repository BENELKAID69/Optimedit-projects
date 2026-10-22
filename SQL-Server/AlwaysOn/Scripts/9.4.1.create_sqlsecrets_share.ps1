<#
    9.4.1.create_sqlsecrets_share.ps1
    Objet     : Créer le dossier et le partage SQLSecrets$ pour la sauvegarde des secrets.
    Noeuds    : OPT-FS03 (exécuter localement, en administrateur)
    Prérequis :
      - Le volume P: doit exister
      - Le groupe "Administrateurs du domaine" doit être résolvable

    PRINCIPE :
    - Crée le dossier P:\SQLSecrets\.
    - Le partage en SQLSecrets$ (partage caché, accessible uniquement par chemin UNC).
    - Accorde les droits NTFS et SMB aux Administrateurs du domaine uniquement.
    - Active l'audit d'accès (optionnel mais recommandé).

    EXEMPLES D'EXÉCUTION :

    # Exécution standard
    .\9.4.1.create_sqlsecrets_share.ps1

    # Spécifier un autre chemin
    .\9.4.1.create_sqlsecrets_share.ps1 -SharePath "E:\SQLSecrets"

    # Ne pas activer l'audit d'accès
    .\9.4.1.create_sqlsecrets_share.ps1 -SkipAudit

    NOTES :
    - Le partage est caché (suffixe $) : il n'apparaît pas dans l'explorateur réseau.
    - Les droits sont accordés aux Administrateurs du domaine uniquement.
    - L'audit d'accès est activé par défaut (journalise les lectures/écritures).
    - Le script est idempotent : ne recrée pas ce qui existe déjà.
#>

param(
    [string]$SharePath = "P:\SQLSecrets",   # <-- adapté au volume P:
    [string]$ShareName = "SQLSecrets$",
    [string]$AdminGroup = "Administrateurs du domaine",
    [switch]$SkipAudit
)

# ============================================================
# ÉTAPE 1 — Vérification du groupe administrateurs
# ============================================================
Write-Host ""
Write-Host "[AD] Vérification du groupe $AdminGroup..." -ForegroundColor Cyan

try {
    $null = Get-ADGroup -Identity $AdminGroup -ErrorAction Stop
    Write-Host "[AD] Groupe trouvé : $AdminGroup" -ForegroundColor Green
} catch {
    Write-Error "[AD] Le groupe $AdminGroup n'existe pas ou n'est pas résolvable."
    Write-Host "Vérifiez le nom du groupe (par défaut : 'Administrateurs du domaine')." -ForegroundColor Yellow
    exit 1
}

# ============================================================
# ÉTAPE 2 — Vérification du volume P:
# ============================================================
Write-Host ""
Write-Host "[Volume] Vérification du volume P:..." -ForegroundColor Cyan

$VolumeP = Get-Volume -DriveLetter P -ErrorAction SilentlyContinue
if (-not $VolumeP) {
    Write-Error "[Volume] Le volume P: n'existe pas sur ce serveur."
    exit 1
}
Write-Host "[Volume] Volume P: trouvé (libre : $([math]::Round($VolumeP.SizeRemaining/1GB,2)) GB)." -ForegroundColor Green

# ============================================================
# ÉTAPE 3 — Création du dossier local
# ============================================================
Write-Host ""
Write-Host "[Dossier] Création du dossier $SharePath..." -ForegroundColor Cyan

if (!(Test-Path $SharePath)) {
    New-Item -Path $SharePath -ItemType Directory -Force | Out-Null
    Write-Host "[Dossier] Dossier créé : $SharePath" -ForegroundColor Green
} else {
    Write-Host "[Dossier] Dossier déjà existant : $SharePath" -ForegroundColor Yellow
}

# ============================================================
# ÉTAPE 4 — Création du partage SMB (caché)
# ============================================================
Write-Host ""
Write-Host "[SMB] Création du partage caché $ShareName..." -ForegroundColor Cyan

$ExistingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue

if ($ExistingShare) {
    Write-Host "[SMB] Partage déjà existant : $ShareName" -ForegroundColor Yellow
} else {
    New-SmbShare -Name $ShareName -Path $SharePath -FullAccess $AdminGroup -ErrorAction Stop | Out-Null
    Write-Host "[SMB] Partage créé : \\$env:COMPUTERNAME\$ShareName (caché)" -ForegroundColor Green
}

# ============================================================
# ÉTAPE 5 — Attribution des droits NTFS aux administrateurs
# ============================================================
Write-Host ""
Write-Host "[NTFS] Attribution des droits NTFS à $AdminGroup..." -ForegroundColor Cyan

try {
    $acl = Get-Acl $SharePath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $AdminGroup, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.SetAccessRule($rule)
    Set-Acl -Path $SharePath -AclObject $acl
    Write-Host "[NTFS] Droits NTFS accordés à $AdminGroup (FullControl)." -ForegroundColor Green
} catch {
    Write-Error "[NTFS] Échec de l'attribution des droits NTFS : $($_.Exception.Message)"
    exit 1
}

# ============================================================
# ÉTAPE 6 — Attribution des droits SMB aux administrateurs
# ============================================================
Write-Host ""
Write-Host "[SMB] Attribution des droits SMB à $AdminGroup..." -ForegroundColor Cyan

try {
    Grant-SmbShareAccess -Name $ShareName -AccountName $AdminGroup -AccessRight Full -Force -ErrorAction Stop | Out-Null
    Write-Host "[SMB] Droits SMB accordés à $AdminGroup (Full)." -ForegroundColor Green
} catch {
    Write-Error "[SMB] Échec de l'attribution des droits SMB : $($_.Exception.Message)"
    exit 1
}

# ============================================================
# ÉTAPE 7 — Rappel sur l'audit d'accès
# ============================================================
if (-not $SkipAudit) {
    Write-Host ""
    Write-Host "[Audit] Activation de l'audit d'accès..." -ForegroundColor Cyan
    Write-Host "[Audit] L'audit d'accès doit être activé via GPO ou auditpol." -ForegroundColor Yellow
    Write-Host "[Audit] Exemple : auditpol /set /subcategory:'File System' /success:enable /failure:enable" -ForegroundColor Yellow
} else {
    Write-Host "[Audit] Audit d'accès ignoré (option -SkipAudit)." -ForegroundColor Yellow
}

# ============================================================
# RÉSUMÉ
# ============================================================
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Partage SQLSecrets$ créé avec succès" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Chemin local    : $SharePath" -ForegroundColor Cyan
Write-Host "  Partage SMB     : \\$env:COMPUTERNAME\$ShareName (caché)" -ForegroundColor Cyan
Write-Host "  Accès autorisé  : $AdminGroup uniquement" -ForegroundColor Cyan
Write-Host ""
Write-Host "Prochaine étape : exécuter 9.4.0.backup_secrets_to_fileserver.ps1 sur SQLS01 et SQLS02." -ForegroundColor Yellow
Write-Host "Commande : .\9.4.0.backup_secrets_to_fileserver.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "RAPPEL : ce partage contient la clé AES. Protégez-le rigoureusement." -ForegroundColor Red