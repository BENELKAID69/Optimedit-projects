<#
.SYNOPSIS
    Copie sql-service-pwd.enc de SQLS01 vers SQLS02 via WinRM (sans partage intermédiaire).

.DESCRIPTION
    Ce script lit le fichier sql-service-pwd.enc sur SQLS01 via WinRM,
    puis l'écrit localement sur SQLS02. Aucun partage réseau n'est nécessaire.
#>

param(
    [string]$SQLS01 = "SQLS01.optimedit.eu",
    [string]$LocalPath = "C:\ProgramData\SQLSecrets\sql-service-pwd.enc"
)

Write-Host ""
Write-Host "=== Copie de sql-service-pwd.enc : $SQLS01 -> LOCAL ($env:COMPUTERNAME) ===" -ForegroundColor Cyan
Write-Host ""

# Étape 1 : Lire le fichier source sur SQLS01 via WinRM
Write-Host "[1/3] Lecture du fichier source sur $SQLS01..." -ForegroundColor Yellow
try {
    $sourceBytes = Invoke-Command -ComputerName $SQLS01 -ScriptBlock {
        param($p)
        if (-not (Test-Path $p)) {
            throw "Fichier source introuvable : $p"
        }
        return [System.IO.File]::ReadAllBytes($p)
    } -ArgumentList "C:\ProgramData\SQLSecrets\sql-service-pwd.enc" -ErrorAction Stop

    Write-Host "[OK] Fichier lu : $($sourceBytes.Length) octets" -ForegroundColor Green
} catch {
    Write-Host "[ERR] Impossible de lire le fichier sur $SQLS01 : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Étape 2 : Écrire localement sur SQLS02
Write-Host "[2/3] Écriture locale sur $env:COMPUTERNAME..." -ForegroundColor Yellow
try {
    # Sauvegarder l'ancien fichier s'il existe
    if (Test-Path $LocalPath) {
        $backupPath = "$LocalPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -Path $LocalPath -Destination $backupPath -Force
        Write-Host "[INFO] Ancien fichier sauvegardé : $backupPath" -ForegroundColor Gray
    }

    # Écrire le nouveau fichier
    [System.IO.File]::WriteAllBytes($LocalPath, $sourceBytes)
    Write-Host "[OK] Fichier écrit : $LocalPath" -ForegroundColor Green
} catch {
    Write-Host "[ERR] Impossible d'écrire localement : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Étape 3 : Vérifier
Write-Host "[3/3] Vérification..." -ForegroundColor Yellow
$localHash = (Get-FileHash $LocalPath -Algorithm SHA256).Hash
$remoteHash = Invoke-Command -ComputerName $SQLS01 -ScriptBlock {
    (Get-FileHash "C:\ProgramData\SQLSecrets\sql-service-pwd.enc" -Algorithm SHA256).Hash
}

Write-Host "  Hash source (SQLS01) : $remoteHash" -ForegroundColor Gray
Write-Host "  Hash cible  (local)  : $localHash" -ForegroundColor Gray

if ($localHash -eq $remoteHash) {
    Write-Host "[OK] ✅ Hashes identiques - copie réussie" -ForegroundColor Green
} else {
    Write-Host "[ERR] ❌ Hashes différents - copie échouée" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Copie terminée avec succès ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Prochaine étape :" -ForegroundColor Yellow
Write-Host "  Recréer tde-cert-pwd.enc et tde-masterkey-pwd.enc sur SQLS02 :" -ForegroundColor Yellow
Write-Host "    .\3.0.0.manage_secrets.ps1 -SecretName 'tde-cert-pwd' -Force" -ForegroundColor Yellow
Write-Host "    .\3.0.0.manage_secrets.ps1 -SecretName 'tde-masterkey-pwd' -Force" -ForegroundColor Yellow
Write-Host ""