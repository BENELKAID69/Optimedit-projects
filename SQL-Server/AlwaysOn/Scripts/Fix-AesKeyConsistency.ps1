<#
.SYNOPSIS
    Corrige l'incohérence de aes.key entre SQLS01 et SQLS02.

.DESCRIPTION
    Ce script copie le fichier aes.key depuis SQLS01 vers SQLS02 via WinRM,
    puis vérifie que les hashes SHA256 sont identiques.

    FONCTIONNALITÉS :
    - Support -WhatIf (prévisualisation)
    - Gestion d'erreurs robuste
    - Logging complet
    - Vérification du hash avant/après
    - Application des ACL strictes sur SQLS02

.PARAMETER SQLS01
    Nœud source. Défaut : SQLS01.optimedit.eu

.PARAMETER SQLS02
    Nœud destination. Défaut : SQLS02.optimedit.eu

.PARAMETER TranscriptPath
    Chemin du fichier de log. Défaut : .\Fix-AesKeyConsistency.log

.EXAMPLE
    .\Fix-AesKeyConsistency.ps1 -WhatIf
    .\Fix-AesKeyConsistency.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string]$SQLS01 = "SQLS01.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [string]$SQLS02 = "SQLS02.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if ($_ -notmatch "\.log$") {
            throw "Le chemin de log doit se terminer par .log (reçu : $_)"
        }
        return $true
    })]
    [string]$TranscriptPath = ".\Fix-AesKeyConsistency.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date

try {
    Start-Transcript -Path $TranscriptPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de démarrer la transcription : $($_.Exception.Message)"
}

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

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    $aesKeyPath = "C:\ProgramData\SQLSecrets\aes.key"

    Write-Section "Fix - Cohérence de aes.key entre SQLS01 et SQLS02"
    Write-Host " SQLS01 (source)  : $SQLS01" -ForegroundColor Gray
    Write-Host " SQLS02 (dest)    : $SQLS02" -ForegroundColor Gray
    Write-Host " Fichier          : $aesKeyPath" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode             : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Log              : $TranscriptPath" -ForegroundColor Gray

    # --- ÉTAPE 1 : Hash avant ---
    Write-Section "Étape 1/4 : Hash avant modification"

    $hashS01Before = Invoke-Command -ComputerName $SQLS01 -ScriptBlock {
        param($p)
        return (Get-FileHash -Path $p -Algorithm SHA256).Hash
    } -ArgumentList $aesKeyPath

    $hashS02Before = Invoke-Command -ComputerName $SQLS02 -ScriptBlock {
        param($p)
        return (Get-FileHash -Path $p -Algorithm SHA256).Hash
    } -ArgumentList $aesKeyPath

    Write-Host "  SQLS01 (source)      : $hashS01Before" -ForegroundColor Gray
    Write-Host "  SQLS02 (avant)       : $hashS02Before" -ForegroundColor Gray

    if ($hashS01Before -eq $hashS02Before) {
        Write-Step "Les hashes sont DÉJÀ identiques - rien à faire" "OK"
        exit 0
    }
    Write-Step "Les hashes sont différents - correction nécessaire" "WARN"

    # --- ÉTAPE 2 : Sauvegarde de l'ancien aes.key sur SQLS02 ---
    Write-Section "Étape 2/4 : Sauvegarde de l'ancien aes.key sur SQLS02"

    $backupPath = "C:\ProgramData\SQLSecrets\aes.key.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    if ($WhatIfPreference) {
        Write-Step "Backup de aes.key vers $backupPath (WhatIf)" "SKIP"
    } else {
        Invoke-Command -ComputerName $SQLS02 -ScriptBlock {
            param($src, $dst)
            Copy-Item -Path $src -Destination $dst -Force
        } -ArgumentList $aesKeyPath, $backupPath

        Write-Step "Ancien aes.key sauvegardé : $backupPath" "OK"
    }

    # --- ÉTAPE 3 : Copie de aes.key de SQLS01 vers SQLS02 ---
    Write-Section "Étape 3/4 : Copie de aes.key via WinRM"

    if ($WhatIfPreference) {
        Write-Step "Copie de aes.key depuis $SQLS01 vers $SQLS02 (WhatIf)" "SKIP"
    } else {
        # Étape 3a : Lire le contenu de aes.key sur SQLS01
        $aesKeyBytes = Invoke-Command -ComputerName $SQLS01 -ScriptBlock {
            param($p)
            return [System.IO.File]::ReadAllBytes($p)
        } -ArgumentList $aesKeyPath

        Write-Step "aes.key lu sur SQLS01 ($($aesKeyBytes.Length) octets)" "OK"

        # Étape 3b : Écrire le contenu sur SQLS02
        Invoke-Command -ComputerName $SQLS02 -ScriptBlock {
            param($p, $bytes)
            [System.IO.File]::WriteAllBytes($p, $bytes)
        } -ArgumentList $aesKeyPath, $aesKeyBytes

        Write-Step "aes.key écrit sur SQLS02" "OK"

        # Étape 3c : Réappliquer les ACL strictes sur SQLS02
        Invoke-Command -ComputerName $SQLS02 -ScriptBlock {
            param($p)
            $acl = Get-Acl $p
            $acl.SetAccessRuleProtection($true, $false)
            
            $sidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
            $sidAdmin  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
            
            $ruleSys = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sidSystem, "FullControl", "None", "None", "Allow"
            )
            $ruleAdm = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sidAdmin, "FullControl", "None", "None", "Allow"
            )
            
            $acl.SetAccessRule($ruleSys)
            $acl.SetAccessRule($ruleAdm)
            Set-Acl -Path $p -AclObject $acl
        } -ArgumentList $aesKeyPath

        Write-Step "ACL strictes réappliquées sur aes.key (SQLS02)" "OK"
    }

    # --- ÉTAPE 4 : Vérification ---
    Write-Section "Étape 4/4 : Vérification finale"

    if (-not $WhatIfPreference) {
        $hashS01After = Invoke-Command -ComputerName $SQLS01 -ScriptBlock {
            param($p)
            return (Get-FileHash -Path $p -Algorithm SHA256).Hash
        } -ArgumentList $aesKeyPath

        $hashS02After = Invoke-Command -ComputerName $SQLS02 -ScriptBlock {
            param($p)
            return (Get-FileHash -Path $p -Algorithm SHA256).Hash
        } -ArgumentList $aesKeyPath

        Write-Host "  SQLS01 (source)      : $hashS01After" -ForegroundColor Gray
        Write-Host "  SQLS02 (après)       : $hashS02After" -ForegroundColor Gray

        if ($hashS01After -eq $hashS02After) {
            Write-Step "✅ Les hashes sont maintenant IDENTIQUES" "OK"
        } else {
            throw "Les hashes sont toujours différents après copie. Vérifiez manuellement."
        }

        # Vérification de la taille
        $sizeS01 = Invoke-Command -ComputerName $SQLS01 -ScriptBlock {
            param($p) (Get-Item $p).Length
        } -ArgumentList $aesKeyPath
        $sizeS02 = Invoke-Command -ComputerName $SQLS02 -ScriptBlock {
            param($p) (Get-Item $p).Length
        } -ArgumentList $aesKeyPath

        Write-Step "Taille SQLS01 : $sizeS01 octets / SQLS02 : $sizeS02 octets" "OK"

        if ($sizeS01 -ne 32 -or $sizeS02 -ne 32) {
            Write-Step "⚠️  La taille n'est pas de 32 octets (256 bits)" "WARN"
        } else {
            Write-Step "✅ Taille valide (32 octets = AES 256 bits)" "OK"
        }
    } else {
        Write-Step "Vérification ignorée (WhatIf)" "SKIP"
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"
    Write-Host ""
    Write-Host "  SQLS01 (source)      : $SQLS01" -ForegroundColor Cyan
    Write-Host "  SQLS02 (dest)        : $SQLS02" -ForegroundColor Cyan
    Write-Host "  Hash avant           : $hashS01Before (S01) vs $hashS02Before (S02)" -ForegroundColor Gray
    if (-not $WhatIfPreference) {
        Write-Host "  Hash après           : $hashS01After (S01) vs $hashS02After (S02)" -ForegroundColor Green
    }
    Write-Host "  Durée                : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""
       if ($WhatIfPreference) {
        Write-Host "  ⚠️  WhatIf : aucune modification effectuée" -ForegroundColor Yellow
        Write-Host "     Relancez sans -WhatIf pour appliquer la correction." -ForegroundColor Yellow
    } else {
        Write-Host "  ✅ Cohérence de aes.key rétablie" -ForegroundColor Green
    }
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
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}