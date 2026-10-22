<#
.SYNOPSIS
    Restaure le certificat TDE sur SQLS02 (réplica secondaire).

.DESCRIPTION
    Ce script restaure le certificat TDE (TDE_Cert) sur SQLS02 depuis les
    fichiers TDE_Cert.cer et TDE_Cert.pvk. Cette étape est INDISPENSABLE
    pour que SQLS02 puisse déchiffrer les bases en cas de bascule (failover).

    ÉTAPES :
    1. Vérification du module SqlServer
    2. Vérification de la connexion SQL Server
    3. Vérification des fichiers requis
    4. Vérification de l'état actuel de TDE_Cert (idempotence)
    5. Récupération du thumbprint de SQLS01 (référence)
    6. Déchiffrement des mots de passe TDE (cert + master key)
    7. Création de la Database Master Key (DMK) sur SQLS02 si absente
    8. Restauration du certificat TDE_Cert
    9. Vérification post-exécution (présence + thumbprint identique)

    ⚠️ CLARIFICATION SUR LES MOTS DE PASSE :
    - Le mot de passe du CERTIFICAT (tde-cert-pwd) DOIT être identique à SQLS01.
    - Le mot de passe de la DMK (tde-masterkey-pwd) peut être DIFFÉRENT de SQLS01.
      Par convention, ce script utilise le même mot de passe que SQLS01.

    FONCTIONNALITÉS :
    - Support -WhatIf (prévisualisation)
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Échappement des apostrophes (sécurité SQL)
    - Conversion des thumbprints en hexadécimal (comparaison fiable)
    - Nettoyage mémoire (ZeroFreeBSTR)

.PARAMETER ServerInstance
    Instance SQL Server cible. Défaut : SQLS02.optimedit.eu

.PARAMETER SecureFolder
    Dossier contenant les secrets. Défaut : C:\ProgramData\SQLSecrets

.PARAMETER CertFolder
    Dossier contenant TDE_Cert.cer et TDE_Cert.pvk. Défaut : C:\Certs

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\7.1.1.restore_tde_cert_on_secondary.log

.EXAMPLE
    .\7.1.1.restore_tde_cert_on_secondary.ps1 -WhatIf
    .\7.1.1.restore_tde_cert_on_secondary.ps1

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 2.3 (corrigée - conversion thumbprint hex)
    Nœud    : SQLS02 (Secondary)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerInstance = "SQLS02.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SecureFolder = "C:\ProgramData\SQLSecrets",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CertFolder = "C:\Certs",

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\7.1.1.restore_tde_cert_on_secondary.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:PlainPwd = $null
$script:PlainMasterPwd = $null

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
        [Parameter(Mandatory = $false)] [string]$ServerInstance = $ServerInstance
    )
    return Invoke-Sqlcmd -ServerInstance $ServerInstance -Database "master" -Query $Query -ErrorAction Stop -TrustServerCertificate
}

function Test-CertificateRestored {
    try {
        $query = "SELECT COUNT(*) AS CertCount FROM sys.certificates WHERE name = 'TDE_Cert'"
        $result = Invoke-SqlQuery -Query $query
        return ($result.CertCount -gt 0)
    } catch {
        return $false
    }
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

function ConvertTo-ThumbprintHex {
    param([byte[]]$Bytes)
    if (-not $Bytes) { return $null }
    return (($Bytes | ForEach-Object { $_.ToString("X2") }) -join '')
}

function Get-CertificateThumbprint {
    param([string]$ServerInstance)
    try {
        $query = "SELECT thumbprint AS Thumbprint FROM sys.certificates WHERE name = 'TDE_Cert'"
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database "master" -Query $query -ErrorAction Stop -TrustServerCertificate
        return ConvertTo-ThumbprintHex -Bytes $result.Thumbprint
    } catch {
        return $null
    }
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

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "7.1.1 - Restauration du certificat TDE sur SQLS02"
    Write-Host " Serveur SQL      : $ServerInstance" -ForegroundColor Gray
    Write-Host " Dossier secrets  : $SecureFolder" -ForegroundColor Gray
    Write-Host " Dossier certs    : $CertFolder" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- PRÉ-VOL 1 : Module SqlServer ---
    Write-Section "Pré-vol 1/5 : Vérification du module SqlServer"

    if (-not (Test-SqlServerModule)) {
        throw "Module SqlServer non disponible. Exécutez : Install-Module -Name SqlServer -Scope AllUsers -Force"
    }
    $module = Get-Module -Name SqlServer -ListAvailable | Select-Object -First 1
    Write-Step "Module SqlServer : v$($module.Version)" "OK"

    # --- PRÉ-VOL 2 : Connexion SQL Server ---
    Write-Section "Pré-vol 2/5 : Vérification de la connexion SQL Server"

    try {
        $version = Invoke-SqlQuery -Query "SELECT @@VERSION AS Version"
        Write-Step "SQL Server accessible : $($version.Version.Split("`n")[0])" "OK"
    } catch {
        throw "Impossible de se connecter à $ServerInstance : $($_.Exception.Message)"
    }

    # --- PRÉ-VOL 3 : Fichiers requis ---
    Write-Section "Pré-vol 3/5 : Vérification des fichiers requis"

    $keyPath = Join-Path $SecureFolder "aes.key"
    $certEncPath = Join-Path $SecureFolder "tde-cert-pwd.enc"
    $masterKeyEncPath = Join-Path $SecureFolder "tde-masterkey-pwd.enc"
    $cerFile = Join-Path $CertFolder "TDE_Cert.cer"
    $pvkFile = Join-Path $CertFolder "TDE_Cert.pvk"

    $requiredFiles = @(
        @{ Path = $keyPath;          Name = "aes.key" },
        @{ Path = $certEncPath;      Name = "tde-cert-pwd.enc" },
        @{ Path = $masterKeyEncPath; Name = "tde-masterkey-pwd.enc" },
        @{ Path = $cerFile;          Name = "TDE_Cert.cer" },
        @{ Path = $pvkFile;          Name = "TDE_Cert.pvk" }
    )

    foreach ($f in $requiredFiles) {
        if (Test-Path $f.Path) {
            $size = (Get-Item $f.Path).Length
            Write-Step "$($f.Name) présent ($size octets)" "OK"
        } else {
            throw "Fichier requis introuvable : $($f.Path)"
        }
    }

    # --- PRÉ-VOL 4 : Certificat pas déjà restauré ---
    Write-Section "Pré-vol 4/5 : Vérification de l'état actuel de TDE_Cert"

    if (Test-CertificateRestored) {
        Write-Step "Certificat 'TDE_Cert' DÉJÀ restauré sur $ServerInstance" "WARN"
        Write-Step "Le script ne fera rien (idempotence)." "INFO"

        $thumbprint = Get-CertificateThumbprint -ServerInstance $ServerInstance
        Write-Host "  Thumbprint : $thumbprint" -ForegroundColor Gray

        Write-Host ""
        Write-Host "  ✅ Aucune action nécessaire - le certificat est déjà en place" -ForegroundColor Green
        exit 0
    } else {
        Write-Step "Certificat 'TDE_Cert' NON présent - restauration nécessaire" "INFO"
    }

    # --- PRÉ-VOL 5 : Thumbprint de SQLS01 pour comparaison ---
    Write-Section "Pré-vol 5/5 : Récupération du thumbprint de SQLS01 (référence)"

    $thumbprintS01 = Get-CertificateThumbprint -ServerInstance "SQLS01.optimedit.eu"
    if ($thumbprintS01) {
        Write-Step "Thumbprint SQLS01 : $thumbprintS01" "OK"
    } else {
        Write-Step "Impossible de récupérer le thumbprint de SQLS01" "WARN"
        $script:Warnings += "Thumbprint SQLS01 non disponible pour comparaison"
    }

    # --- DÉCHIFFREMENT DES SECRETS ---
    Write-Section "Déchiffrement des mots de passe TDE"

    $script:PlainPwd = Get-PlainPasswordFromSecret -KeyPath $keyPath -SecretPath $certEncPath
    Write-Step "Mot de passe certificat déchiffré en mémoire" "OK"

    $script:PlainMasterPwd = Get-PlainPasswordFromSecret -KeyPath $keyPath -SecretPath $masterKeyEncPath
    Write-Step "Mot de passe DMK déchiffré en mémoire" "OK"

    # --- CRÉATION DE LA MASTER KEY (si absente) ---
    Write-Section "Vérification et création de la Database Master Key (DMK)"

    if (Test-MasterKeyExists) {
        Write-Step "Database Master Key DÉJÀ présente sur $ServerInstance" "OK"
    } else {
        Write-Step "Database Master Key ABSENTE - création en cours..." "INFO"

        if ($WhatIfPreference) {
            Write-Step "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '***' (WhatIf)" "SKIP"
        } else {
            try {
                $safeMasterPwd = $script:PlainMasterPwd -replace "'", "''"
                $query = "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$safeMasterPwd'"
                Invoke-SqlQuery -Query $query | Out-Null
                Write-Step "Database Master Key créée sur $ServerInstance" "OK"
            } catch {
                throw "Échec de la création de la DMK : $($_.Exception.Message)"
            }
        }
    }

    # --- RESTAURATION DU CERTIFICAT ---
    Write-Section "Restauration du certificat TDE"

    if ($WhatIfPreference) {
        Write-Step "CREATE CERTIFICATE TDE_Cert FROM FILE = '$cerFile' WITH PRIVATE KEY (...) (WhatIf)" "SKIP"
    } else {
        try {
            $safeCertPwd = $script:PlainPwd -replace "'", "''"
            $query = @"
USE master;
GO

IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'TDE_Cert')
BEGIN
    CREATE CERTIFICATE TDE_Cert
    FROM FILE = '$cerFile'
    WITH PRIVATE KEY (
        FILE = '$pvkFile',
        DECRYPTION BY PASSWORD = '$safeCertPwd'
    );
END
GO
"@
            Invoke-SqlQuery -Query $query | Out-Null
            Write-Step "Certificat TDE_Cert restauré sur $ServerInstance" "OK"
        } catch {
            throw "Échec de la restauration du certificat : $($_.Exception.Message)"
        }
    }

    # --- VÉRIFICATION POST-EXÉCUTION ---
    Write-Section "Vérification post-exécution"

    if (-not $WhatIfPreference) {
        Write-Host ""
        Write-Host "  Vérification du certificat restauré :" -ForegroundColor Cyan

        if (Test-CertificateRestored) {
            Write-Step "Certificat 'TDE_Cert' présent dans sys.certificates" "OK"

            $thumbprintS02 = Get-CertificateThumbprint -ServerInstance $ServerInstance
            Write-Host "  Thumbprint SQLS02 : $thumbprintS02" -ForegroundColor Gray

            if ($thumbprintS01 -and ($thumbprintS01 -eq $thumbprintS02)) {
                Write-Step "Thumbprint IDENTIQUE à SQLS01 - certificat cohérent" "OK"
            } elseif ($thumbprintS01) {
                Write-Step "Thumbprint DIFFÉRENT de SQLS01 - problème potentiel" "ERROR"
                $script:Errors += "Thumbprint différent entre SQLS01 et SQLS02"
            }

            $query = @"
SELECT 
    name AS CertName,
    subject AS Subject,
    expiry_date AS ExpiryDate,
    pvt_key_encryption_type_desc AS KeyEncryption
FROM sys.certificates
WHERE name = 'TDE_Cert'
"@
            $certInfo = Invoke-SqlQuery -Query $query
            $certInfo | Format-List

        } else {
            Write-Step "Certificat 'TDE_Cert' TOUJOURS ABSENT après restauration" "ERROR"
            $script:Errors += "Certificat non restauré"
        }

        Write-Host ""
        Write-Host "  Vérification de la Database Master Key :" -ForegroundColor Cyan
        if (Test-MasterKeyExists) {
            Write-Step "Database Master Key présente dans master" "OK"
        } else {
            Write-Step "Database Master Key ABSENTE" "ERROR"
            $script:Errors += "DMK absente après création"
        }
    } else {
        Write-Step "Vérifications post-exécution ignorées (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  Serveur SQL      : $ServerInstance" -ForegroundColor Cyan
    Write-Host "  Certificat       : TDE_Cert" -ForegroundColor Green
    Write-Host "  Erreurs          : $($script:Errors.Count)" -ForegroundColor $(if ($script:Errors.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Durée            : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""

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

    Write-Host "  ✅ Restauration du certificat TDE terminée avec succès" -ForegroundColor Green
    Write-Host ""
    Write-Host "  📌 Prochaine étape : 7.2.0 (création des jobs SQL Agent)" -ForegroundColor Yellow
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

    $script:Errors += $_.Exception.Message
    exit 1
} finally {
    if ($script:PlainPwd) { $script:PlainPwd = $null }
    if ($script:PlainMasterPwd) { $script:PlainMasterPwd = $null }
    [System.GC]::Collect()

    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}