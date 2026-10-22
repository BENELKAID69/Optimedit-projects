<#
.SYNOPSIS
    Active TDE (Transparent Data Encryption) sur les 13 bases applicatives.

.DESCRIPTION
    Ce script active TDE sur les 13 bases de l'Availability Group AG-OPTIMEDIT :
    1. Crée la Database Master Key (DMK) sur master
    2. Crée le certificat TDE_Cert
    3. Sauvegarde le certificat (.cer) + clé privée (.pvk) sur S:\SQL\Backup
    4. Crée une Database Encryption Key (DEK) AES-256 pour chaque base
    5. Active TDE sur chaque base (ALTER DATABASE ... SET ENCRYPTION ON)

    FONCTIONNALITÉS :
    - Support -WhatIf pour la prévisualisation
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Vérifications préalables :
        * Module SqlServer disponible
        * Connexion SQL Server accessible
        * Fichiers de secrets présents (aes.key, tde-masterkey-pwd.enc, tde-cert-pwd.enc)
        * Chemin S:\SQL\Backup accessible
        * Les 13 bases existent
        * TDE n'est pas déjà activé sur les bases
    - Vérifications post-exécution :
        * Master key présente
        * Certificat TDE_Cert présent
        * Fichiers .cer et .pvk créés
        * DEK créée pour chaque base
        * TDE activé sur chaque base
        * État de chiffrement (encryption_state)
    - Support -Rollback (désactive TDE et supprime les DEK en cas d'erreur)
    - Compatible Windows PowerShell 5.1 et PowerShell 7+

.PARAMETER ServerInstance
    Instance SQL Server cible. Défaut : SQLS01.optimedit.eu

.PARAMETER SecureFolder
    Dossier contenant les secrets (aes.key, *.enc). Défaut : C:\ProgramData\SQLSecrets

.PARAMETER BackupPath
    Chemin de sauvegarde du certificat TDE. Défaut : S:\SQL\Backup\

.PARAMETER Databases
    Liste des bases à chiffrer. Défaut : les 13 bases applicatives.

.PARAMETER RollbackOnError
    Désactive TDE et supprime les DEK en cas d'erreur.

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\7.1.0.enable_tde.log

.EXAMPLE
    # Prévisualisation
    .\7.1.0.enable_tde.ps1 -WhatIf

.EXAMPLE
    # Activation standard
    .\7.1.0.enable_tde.ps1

.EXAMPLE
    # Avec rollback en cas d'erreur
    .\7.1.0.enable_tde.ps1 -RollbackOnError

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 2.0 (améliorée)
    Nœud    : SQLS01 (Primary)
    Prérequis :
        - Clé AES générée (3.0.0.manage_secrets.ps1 -GenerateKey)
        - Secrets 'tde-masterkey-pwd' et 'tde-cert-pwd' chiffrés
        - Les 13 bases existent et sont dans l'AG (synchronisées)
    IMPORTANT :
        Après ce script, exécuter IMPÉRATIVEMENT 7.1.1 sur SQLS02
        pour restaurer le certificat TDE. Sinon, une bascule rendrait
        les bases illisibles.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerInstance = "SQLS01.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SecureFolder = "C:\ProgramData\SQLSecrets",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$BackupPath = "S:\SQL\Backup\",

    [Parameter(Mandatory = $false)]
    [string[]]$Databases = @(
        "DB_Direction", "DB_Comptabilite", "DB_Paie", "DB_RH", "DB_CE",
        "DB_IT", "DB_Production", "DB_Formation", "DB_Achat",
        "DB_Commercial", "DB_Client", "DB_Juridique", "DB_Blog"
    ),

    [Parameter(Mandatory = $false)]
    [switch]$RollbackOnError,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\7.1.0.enable_tde.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:EncryptedDatabases = @()
$script:SkippedDatabases = @()
$script:FailedDatabases = @()
$script:MasterKeyCreated = $false
$script:CertificateCreated = $false
$script:PlainMasterPassword = $null
$script:PlainCertPassword = $null

try {
    Start-Transcript -Path $TranscriptPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de démarrer la transcription : $($_.Exception.Message)"
}

# ============================================================
# FONCTIONS AUXILIAIRES
# ============================================================

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "INFO"  { "Cyan" }
        "SKIP"  { "DarkGray" }
        default { "White" }
    }
    $prefix = switch ($Status) {
        "OK"    { "[OK]   " }
        "WARN"  { "[WARN] " }
        "ERROR" { "[ERR]  " }
        "INFO"  { "[INFO] " }
        "SKIP"  { "[SKIP] " }
        default { "[----] " }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

function Test-SqlServerModule {
    try {
        $null = Get-Module -Name SqlServer -ListAvailable -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Invoke-SqlQuery {
    param(
        [Parameter(Mandatory = $true)] [string]$Query,
        [Parameter(Mandatory = $false)] [string]$ServerInstance = $ServerInstance,
        [Parameter(Mandatory = $false)] [string]$Database = "master"
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database -Query $Query -ErrorAction Stop -TrustServerCertificate
}

function Test-MasterKeyExists {
    try {
        $query = "SELECT COUNT(*) AS MKCount FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##'"
        $result = Invoke-SqlQuery -Query $query
        return ($result.MKCount -gt 0)
    } catch {
        return $false
    }
}

function Test-CertificateExists {
    try {
        $query = "SELECT COUNT(*) AS CertCount FROM sys.certificates WHERE name = 'TDE_Cert'"
        $result = Invoke-SqlQuery -Query $query
        return ($result.CertCount -gt 0)
    } catch {
        return $false
    }
}

function Test-DatabaseExists {
    param([string]$DatabaseName)
    try {
        $query = "SELECT COUNT(*) AS DbCount FROM sys.databases WHERE name = '$DatabaseName'"
        $result = Invoke-SqlQuery -Query $query
        return ($result.DbCount -gt 0)
    } catch {
        return $false
    }
}

function Test-TDEActivated {
    param([string]$DatabaseName)
    try {
        $query = @"
SELECT COUNT(*) AS TdeCount
FROM sys.dm_database_encryption_keys dek
JOIN sys.databases db ON dek.database_id = db.database_id
WHERE db.name = '$DatabaseName' AND dek.encryption_state IN (1, 2, 3, 4, 5)
"@
        $result = Invoke-SqlQuery -Query $query
        return ($result.TdeCount -gt 0)
    } catch {
        return $false
    }
}

function Test-SecretsExist {
    param([string]$Folder)
    $files = @("aes.key", "tde-masterkey-pwd.enc", "tde-cert-pwd.enc")
    $missing = @()
    foreach ($f in $files) {
        $path = Join-Path $Folder $f
        if (-not (Test-Path $path)) {
            $missing += $path
        }
    }
    return $missing
}

function Get-PlainPasswordFromSecret {
    param(
        [string]$KeyPath,
        [string]$SecretPath
    )
    $key = Get-Content $KeyPath -Encoding Byte
    $secure = Get-Content $SecretPath | ConvertTo-SecureString -Key $key
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    return $plain
}

function New-TdeMasterKeyAndCertificate {
    param(
        [string]$MasterPassword,
        [string]$CertPassword,
        [string]$BackupPath
    )

    $cleanBackupPath = $BackupPath.TrimEnd('\')

    $query = @"
USE master;
GO

IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$MasterPassword';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'TDE_Cert')
BEGIN
    CREATE CERTIFICATE TDE_Cert WITH SUBJECT = 'Certificat TDE optimedit.eu';
END
GO

BACKUP CERTIFICATE TDE_Cert
   TO FILE = '$cleanBackupPath\TDE_Cert.cer'
   WITH PRIVATE KEY (
       FILE = '$cleanBackupPath\TDE_Cert.pvk',
       ENCRYPTION BY PASSWORD = '$CertPassword'
   );
GO
"@
    Invoke-SqlQuery -Query $query | Out-Null
}

function Enable-TdeOnDatabase {
    param([string]$DatabaseName)
    $query = @"
USE [$DatabaseName];
IF NOT EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('$DatabaseName'))
BEGIN
    CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256 ENCRYPTION BY SERVER CERTIFICATE TDE_Cert;
END
GO
ALTER DATABASE [$DatabaseName] SET ENCRYPTION ON;
GO
"@
    Invoke-SqlQuery -Query $query | Out-Null
}

function Disable-TdeOnDatabase {
    param([string]$DatabaseName)
    $query = @"
USE [$DatabaseName];
ALTER DATABASE [$DatabaseName] SET ENCRYPTION OFF;
GO
WAITFOR DELAY '00:00:05';
DROP DATABASE ENCRYPTION KEY;
GO
"@
    try {
        Invoke-SqlQuery -Query $query | Out-Null
    } catch {
        # Ignorer les erreurs de rollback (base peut être déjà déchiffrée)
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "7.1.0 - Activation TDE sur les 13 bases"
    Write-Host " Serveur SQL      : $ServerInstance" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Dossier secrets  : $SecureFolder" -ForegroundColor Gray
    Write-Host " Chemin backup    : $BackupPath" -ForegroundColor Gray
    Write-Host " Rollback on err  : $(if ($RollbackOnError) { 'OUI' } else { 'NON' })" -ForegroundColor Gray
    Write-Host " Nombre de bases  : $($Databases.Count)" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Module SqlServer ---
    Write-Section "Pré-vol 1/6 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible. Exécutez d'abord : Install-Module -Name SqlServer -Scope AllUsers -Force"
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # --- PRÉ-VOL 2 : Connexion SQL Server ---
    Write-Section "Pré-vol 2/6 : Vérification de la connexion SQL Server"

    try {
        $version = Invoke-SqlQuery -Query "SELECT @@VERSION AS Version"
        Write-Step "SQL Server accessible : $($version.Version.Split("`n")[0])" "OK"
    } catch {
        throw "Impossible de se connecter à $ServerInstance : $($_.Exception.Message)"
    }

    # --- PRÉ-VOL 3 : Fichiers de secrets ---
    Write-Section "Pré-vol 3/6 : Vérification des fichiers de secrets"

    $missingSecrets = Test-SecretsExist -Folder $SecureFolder
    if ($missingSecrets.Count -gt 0) {
        Write-Step "$($missingSecrets.Count) fichier(s) de secrets MANQUANT(S) :" "ERROR"
        $missingSecrets | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "Exécutez d'abord 3.0.0.manage_secrets.ps1 pour créer les secrets tde-masterkey-pwd et tde-cert-pwd."
    }
    Write-Step "Les 3 fichiers de secrets sont présents" "OK"

    # --- PRÉ-VOL 4 : Existence des bases ---
    Write-Section "Pré-vol 4/6 : Vérification de l'existence des bases"

    $missingDatabases = @()
    foreach ($db in $Databases) {
        if (-not (Test-DatabaseExists -DatabaseName $db)) {
            $missingDatabases += $db
        }
    }
    if ($missingDatabases.Count -gt 0) {
        Write-Step "$($missingDatabases.Count) base(s) MANQUANTE(S) :" "ERROR"
        $missingDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        throw "Exécutez d'abord 6.1.0.create_application_databases.ps1."
    }
    Write-Step "Les $($Databases.Count) bases existent" "OK"

    # --- PRÉ-VOL 5 : État actuel de TDE ---
    Write-Section "Pré-vol 5/6 : Vérification de l'état actuel de TDE"

    $mkExists = Test-MasterKeyExists
    $certExists = Test-CertificateExists
    $alreadyEncrypted = @()
    foreach ($db in $Databases) {
        if (Test-TDEActivated -DatabaseName $db) {
            $alreadyEncrypted += $db
        }
    }

    Write-Step "Master key présente : $mkExists" $(if ($mkExists) { "OK" } else { "INFO" })
    Write-Step "Certificat TDE_Cert présent : $certExists" $(if ($certExists) { "OK" } else { "INFO" })
    if ($alreadyEncrypted.Count -gt 0) {
        Write-Step "$($alreadyEncrypted.Count) base(s) déjà chiffrée(s) (ignorées) :" "WARN"
        $alreadyEncrypted | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    } else {
        Write-Step "Aucune base n'est encore chiffrée" "OK"
    }

    # --- PRÉ-VOL 6 : Chemin de backup ---
    Write-Section "Pré-vol 6/6 : Vérification du chemin de backup"

    if (Test-Path $BackupPath) {
        Write-Step "Chemin backup '$BackupPath' existe" "OK"
    } else {
        Write-Step "Chemin backup '$BackupPath' NON accessible" "WARN"
        $script:Warnings += "Chemin backup non vérifié localement"
    }

    # --- DÉCHIFFREMENT DES SECRETS ---
    Write-Section "Déchiffrement des secrets TDE"

    $keyPath = Join-Path $SecureFolder "aes.key"
    $masterSecretPath = Join-Path $SecureFolder "tde-masterkey-pwd.enc"
    $certSecretPath = Join-Path $SecureFolder "tde-cert-pwd.enc"

    $script:PlainMasterPassword = Get-PlainPasswordFromSecret -KeyPath $keyPath -SecretPath $masterSecretPath
    $script:PlainCertPassword = Get-PlainPasswordFromSecret -KeyPath $keyPath -SecretPath $certSecretPath

    Write-Step "Secrets TDE déchiffrés en mémoire" "OK"

    # --- CRÉATION MASTER KEY + CERTIFICAT ---
    Write-Section "Création de la master key et du certificat TDE"

    if ($WhatIfPreference) {
        Write-Step "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '***' (WhatIf)" "SKIP"
        Write-Step "CREATE CERTIFICATE TDE_Cert WITH SUBJECT = 'Certificat TDE optimedit.eu' (WhatIf)" "SKIP"
        Write-Step "BACKUP CERTIFICATE TDE_Cert TO FILE = '${BackupPath}TDE_Cert.cer' WITH PRIVATE KEY (...)' (WhatIf)" "SKIP"
    } else {
        try {
            New-TdeMasterKeyAndCertificate -MasterPassword $script:PlainMasterPassword -CertPassword $script:PlainCertPassword -BackupPath $BackupPath
            $script:MasterKeyCreated = Test-MasterKeyExists
            $script:CertificateCreated = Test-CertificateExists
            Write-Step "Master key créée : $($script:MasterKeyCreated)" "OK"
            Write-Step "Certificat TDE_Cert créé : $($script:CertificateCreated)" "OK"
            Write-Step "Certificat sauvegardé dans $BackupPath" "OK"
        } catch {
            throw "Échec création master key/certificat : $($_.Exception.Message)"
        }
    }

    # --- ACTIVATION TDE SUR LES BASES ---
    Write-Section "Activation TDE sur les bases"

    foreach ($db in $Databases) {
        Write-Host ""
        Write-Host "  ── $db ──" -ForegroundColor Magenta

        if (Test-TDEActivated -DatabaseName $db) {
            Write-Step "Déjà chiffrée - ignorée" "SKIP"
            $script:SkippedDatabases += $db
            continue
        }

        if ($WhatIfPreference) {
            Write-Step "CREATE DATABASE ENCRYPTION KEY ... (WhatIf)" "SKIP"
            Write-Step "ALTER DATABASE [$db] SET ENCRYPTION ON (WhatIf)" "SKIP"
        } else {
            try {
                Enable-TdeOnDatabase -DatabaseName $db
                Write-Step "TDE activé (chiffrement en cours...)" "OK"
                $script:EncryptedDatabases += $db
            } catch {
                Write-Step "ÉCHEC : $($_.Exception.Message)" "ERROR"
                $script:Errors += "Échec TDE $db : $($_.Exception.Message)"
                $script:FailedDatabases += $db

                if ($RollbackOnError) {
                    Write-Step "Rollback : désactivation TDE sur $db..." "WARN"
                    try {
                        Disable-TdeOnDatabase -DatabaseName $db
                        Write-Step "TDE désactivé sur $db" "OK"
                    } catch {
                        Write-Step "Impossible de désactiver TDE sur $db : $($_.Exception.Message)" "ERROR"
                    }
                }
            }
        }
    }

    # --- VÉRIFICATION POST-EXÉCUTION ---
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Write-Host ""
        Write-Host "  État du chiffrement des bases :" -ForegroundColor Cyan

        $verifyQuery = @"
SELECT 
    db.name AS DatabaseName,
    dek.encryption_state AS EncryptionState,
    CASE dek.encryption_state
        WHEN 0 THEN 'No DB encryption key'
        WHEN 1 THEN 'Unencrypted'
        WHEN 2 THEN 'Encryption in progress'
        WHEN 3 THEN 'Encrypted'
        WHEN 4 THEN 'Key change in progress'
        WHEN 5 THEN 'Decryption in progress'
        WHEN 6 THEN 'Protection change in progress'
    END AS EncryptionStateDesc,
    dek.percent_complete AS PercentComplete,
    dek.key_algorithm AS KeyAlgorithm,
    dek.key_length AS KeyLength
FROM sys.databases db
LEFT JOIN sys.dm_database_encryption_keys dek ON db.database_id = dek.database_id
WHERE db.name IN ('DB_Direction', 'DB_Comptabilite', 'DB_Paie', 'DB_RH', 'DB_CE', 'DB_IT', 'DB_Production', 'DB_Formation', 'DB_Achat', 'DB_Commercial', 'DB_Client', 'DB_Juridique', 'DB_Blog')
ORDER BY db.name
"@
        $tdeState = Invoke-SqlQuery -Query $verifyQuery
        if ($tdeState) {
            $tdeState | Format-Table DatabaseName, EncryptionStateDesc, PercentComplete, KeyAlgorithm, KeyLength -AutoSize

            $totalEncrypted = ($tdeState | Where-Object { $_.EncryptionState -eq 3 }).Count
            Write-Step "Bases chiffrées (state=3) : $totalEncrypted / $($Databases.Count)" "INFO"
        }

        # Vérification des fichiers de sauvegarde du certificat
        Write-Host ""
        Write-Host "  Fichiers de sauvegarde du certificat TDE :" -ForegroundColor Cyan
        $certFile = Join-Path $BackupPath "TDE_Cert.cer"
        $pvkFile = Join-Path $BackupPath "TDE_Cert.pvk"
        if (Test-Path $certFile) {
            Write-Step "TDE_Cert.cer présent ($((Get-Item $certFile).Length) octets)" "OK"
        } else {
            Write-Step "TDE_Cert.cer MANQUANT" "ERROR"
        }
        if (Test-Path $pvkFile) {
            Write-Step "TDE_Cert.pvk présent ($((Get-Item $pvkFile).Length) octets)" "OK"
        } else {
            Write-Step "TDE_Cert.pvk MANQUANT" "ERROR"
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Serveur SQL      : $ServerInstance" -ForegroundColor Cyan
    Write-Host "  Bases chiffrées  : $($script:EncryptedDatabases.Count)" -ForegroundColor Green
    Write-Host "  Bases ignorées   : $($script:SkippedDatabases.Count)" -ForegroundColor Cyan
    Write-Host "  Bases en échec   : $($script:FailedDatabases.Count)" -ForegroundColor $(if ($script:FailedDatabases.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Erreurs          : $($script:Errors.Count)" -ForegroundColor $(if ($script:Errors.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Durée            : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""

    if ($script:EncryptedDatabases.Count -gt 0) {
        Write-Host "  Bases chiffrées :" -ForegroundColor Green
        $script:EncryptedDatabases | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
        Write-Host ""
    }

    if ($script:Warnings.Count -gt 0) {
        Write-Host "  Avertissements :" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        Write-Host ""
    }

    if ($script:Errors.Count -gt 0) {
        Write-Host "  Erreurs :" -ForegroundColor Red
        $script:Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host ""
        exit 1
    }

    Write-Host "  ✅ TDE activé avec succès sur les 13 bases" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ⚠️  IMPORTANT : exécuter maintenant 7.1.1.restore_tde_cert_on_secondary.ps1 sur SQLS02" -ForegroundColor Yellow
    Write-Host "      Sans cette étape, une bascule vers SQLS02 rendrait les bases ILLISIBLES." -ForegroundColor Yellow
    Write-Host ""

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  Message : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Ligne   : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host ""
    if ($_.ScriptStackTrace) {
        Write-Host "  Stack trace :" -ForegroundColor DarkRed
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }

    if ($RollbackOnError -and $script:EncryptedDatabases.Count -gt 0) {
        Write-Section "Rollback TDE des bases chiffrées"
        foreach ($db in $script:EncryptedDatabases) {
            Write-Step "Désactivation TDE sur $db..." "WARN"
            try {
                Disable-TdeOnDatabase -DatabaseName $db
                Write-Step "TDE désactivé sur $db" "OK"
            } catch {
                Write-Step "Impossible de désactiver TDE sur $db : $($_.Exception.Message)" "ERROR"
            }
        }
    }

    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    # Nettoyage mémoire (sécurité)
    if ($script:PlainMasterPassword) { $script:PlainMasterPassword = $null }
    if ($script:PlainCertPassword) { $script:PlainCertPassword = $null }
    [System.GC]::Collect()
    
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}