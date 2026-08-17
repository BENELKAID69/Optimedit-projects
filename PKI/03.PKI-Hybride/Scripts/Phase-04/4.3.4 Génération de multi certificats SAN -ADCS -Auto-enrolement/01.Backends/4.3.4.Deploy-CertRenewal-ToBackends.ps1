# ==================================================================================================
# Nom script : 4.3.4.Deploy-CertRenewal-ToBackends-V2.ps1
# Objet      : Déploie le script V20.2 sur les 6 backends IIS via WinRM
# Exécution  : Sur OPT-RP-01 (Reverse-Proxy)
# Auteur     : Optimedit
# Date       : 10/08/2026
#
# CORRECTIONS :
#   - Si la tâche existe déjà, elle est supprimée puis recréée avec la bonne heure
#   - Correction du parsing du résultat
#   - Meilleure gestion des logs
# ==================================================================================================

# ==================================================================================================
# SECTION 1 : CONFIGURATION
# ==================================================================================================

$Backends = @(
    "OPT-IIS-01",
    "OPT-IIS-02",
    "OPT-IIS-03",
    "OPT-IIS-04",
    "OPT-IIS-05",
    "OPT-IIS-06"
)

$Domain = "optimedit.eu"
$LocalScriptSource = "C:\Scripts\ADCS\4.3.4.Generate-CERTS-IIS-SAN-FQDN-Auto-enrolement-V20.2.ps1"
$RemoteScriptPath = "C:\Scripts\ADCS\4.3.4.Generate-CERTS-IIS-SAN-FQDN-Auto-enrolement-V20.2.ps1"
$RemoteScriptDir = "C:\Scripts\ADCS"

# Logs sur le Reverse-Proxy
$LogPath = "C:\Scripts\ADCS\logs"
$LogFile = "$LogPath\Deploy-CertRenewal-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ==================================================================================================
# SECTION 2 : FONCTIONS
# ==================================================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White"
    )
    
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    
    if ($Color -ne "White") {
        Write-Host $logEntry -ForegroundColor $Color
    } else {
        Write-Host $logEntry
    }
}

function Write-Section {
    param([string]$Title)
    
    Write-Log "" "INFO" "White"
    Write-Log "========================================" "INFO" "Cyan"
    Write-Log $Title "INFO" "Cyan"
    Write-Log "========================================" "INFO" "Cyan"
}

function Write-Header {
    Write-Log "" "INFO" "White"
    Write-Log "╔═══════════════════════════════════════════════════════════════╗" "INFO" "Cyan"
    Write-Log "║           DEPLOIEMENT CERTIFICAT ADCS - BACKENDS             ║" "INFO" "Cyan"
    Write-Log "╚═══════════════════════════════════════════════════════════════╝" "INFO" "Cyan"
    Write-Log "  Log : $LogFile" "INFO" "Gray"
    Write-Log "  Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" "Gray"
    Write-Log "" "INFO" "White"
}

function Test-WinRMConnection {
    param([string]$ComputerName)
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        Remove-PSSession $session
        return $true
    } catch {
        return $false
    }
}

function Invoke-RemoteScriptBlock {
    param(
        [string]$ComputerName,
        [scriptblock]$ScriptBlock,
        [array]$ArgumentList = @()
    )
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        $result = Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        Remove-PSSession $session
        return $result
    } catch {
        Write-Log "  ❌ Erreur sur $ComputerName : $($_.Exception.Message)" "ERROR" "Red"
        return $null
    }
}

# ==================================================================================================
# SECTION 3 : VÉRIFICATION DU SCRIPT SOURCE
# ==================================================================================================

Write-Header

Write-Section "VÉRIFICATION DU SCRIPT SOURCE"

if (-not (Test-Path $LocalScriptSource)) {
    Write-Log "  ❌ Script source introuvable !" "ERROR" "Red"
    Write-Log "  $LocalScriptSource" "ERROR" "Red"
    Write-Log "" "INFO" "White"
    Write-Log "Appuyez sur Entrée pour fermer..." "INFO" "Yellow"
    Read-Host
    exit 1
}

Write-Log "  ✅ Script source trouvé" "SUCCESS" "Green"
$scriptHash = (Get-FileHash $LocalScriptSource).Hash
Write-Log "  Hash SHA256 : $scriptHash" "INFO" "Gray"

# ==================================================================================================
# SECTION 4 : DÉPLOIEMENT SUR LES BACKENDS
# ==================================================================================================

Write-Section "DÉPLOIEMENT SUR LES $($Backends.Count) BACKENDS"

$Results = @()
$SuccessCount = 0
$FailCount = 0

foreach ($backend in $Backends) {
    $fqdn = "$backend.$Domain"
    Write-Log "`n╔═══════════════════════════════════════════════════════════════╗" "INFO" "Yellow"
    Write-Log "║  Traitement de $fqdn" "INFO" "Yellow"
    Write-Log "╚═══════════════════════════════════════════════════════════════╝" "INFO" "Yellow"
    
    # Test WinRM
    Write-Log "  [1/3] Test de la connexion WinRM..." "INFO" "Gray"
    if (-not (Test-WinRMConnection -ComputerName $fqdn)) {
        Write-Log "  ❌ Connexion WinRM impossible sur $fqdn" "ERROR" "Red"
        $Results += "$fqdn|FAILED|WinRM impossible"
        $FailCount++
        continue
    }
    Write-Log "  ✅ Connexion WinRM OK" "SUCCESS" "Green"
    
    # Copie du script
    $scriptBlock = {
        param(
            [string]$RemoteScriptDir,
            [string]$RemoteScriptPath,
            [string]$ScriptContent
        )
        
        $log = @()
        $success = $true
        
        if (-not (Test-Path "C:\Scripts")) {
            New-Item -ItemType Directory -Path "C:\Scripts" -Force | Out-Null
            $log += "✅ Dossier C:\Scripts créé"
        } else {
            $log += "✅ Dossier C:\Scripts existe déjà"
        }
        
        if (-not (Test-Path $RemoteScriptDir)) {
            New-Item -ItemType Directory -Path $RemoteScriptDir -Force | Out-Null
            $log += "✅ Dossier $RemoteScriptDir créé"
        } else {
            $log += "✅ Dossier $RemoteScriptDir existe déjà"
        }
        
        try {
            $bytes = [Convert]::FromBase64String($ScriptContent)
            $content = [System.Text.Encoding]::UTF8.GetString($bytes)
            Set-Content -Path $RemoteScriptPath -Value $content -Encoding UTF8 -Force
            $log += "✅ Script copié vers $RemoteScriptPath"
            
            if (Test-Path $RemoteScriptPath) {
                $fileInfo = Get-Item $RemoteScriptPath
                $log += "   Taille : $($fileInfo.Length) octets"
            } else {
                $log += "❌ Fichier non trouvé après copie"
                $success = $false
            }
        } catch {
            $log += "❌ Erreur copie : $($_.Exception.Message)"
            $success = $false
        }
        
        return @{
            Logs = $log
            Success = $success
        }
    }
    
    $scriptContent = Get-Content -Path $LocalScriptSource -Raw -Encoding UTF8
    $scriptContentBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptContent))
    
    Write-Log "  [2/3] Copie du script V20.2..." "INFO" "Gray"
    $remoteResult = Invoke-RemoteScriptBlock -ComputerName $fqdn -ScriptBlock $scriptBlock -ArgumentList $RemoteScriptDir, $RemoteScriptPath, $scriptContentBase64
    
    if ($remoteResult -eq $null) {
        Write-Log "  ❌ Échec de la copie sur $fqdn" "ERROR" "Red"
        $Results += "$fqdn|FAILED|Copie échouée"
        $FailCount++
        continue
    }
    
    foreach ($logLine in $remoteResult.Logs) {
        Write-Log "    $logLine" "INFO" "Gray"
    }
    
    if ($remoteResult.Success) {
        Write-Log "  ✅ Script déployé avec succès sur $fqdn" "SUCCESS" "Green"
        $Results += "$fqdn|SUCCESS|OK"
        $SuccessCount++
    } else {
        Write-Log "  ❌ Échec du déploiement sur $fqdn" "ERROR" "Red"
        $Results += "$fqdn|FAILED|Copie échouée"
        $FailCount++
    }
}

# ==================================================================================================
# SECTION 5 : RAPPORT DE DÉPLOIEMENT
# ==================================================================================================

Write-Section "RAPPORT DE DÉPLOIEMENT"

Write-Log "  --- STATUT DES BACKENDS ---" "INFO" "Cyan"
foreach ($result in $Results) {
    $parts = $result -split "\|"
    $server = $parts[0]
    $status = $parts[1]
    $detail = $parts[2]
    
    $icon = if ($status -eq "SUCCESS") { "✅" } else { "❌" }
    $color = if ($status -eq "SUCCESS") { "Green" } else { "Red" }
    Write-Log "    $icon $server : $status" "INFO" $color
    Write-Log "        $detail" "INFO" "Gray"
}

Write-Log "" "INFO" "White"
Write-Log "  --- RÉSUMÉ ---" "INFO" "Cyan"
Write-Log "    ✅ Succès : $SuccessCount" "SUCCESS" "Green"
Write-Log "    ❌ Échecs : $FailCount" "ERROR" "Red"

# ==================================================================================================
# SECTION 6 : OPTION - CRÉATION DE LA TÂCHE PLANIFIÉE À 22H00 (AVEC SUPPRESSION SI EXISTE)
# ==================================================================================================

Write-Log "" "INFO" "White"
Write-Log "--- OPTION : TÂCHE PLANIFIÉE À 22H00 ---" "INFO" "Cyan"
Write-Log "  Souhaitez-vous créer la tâche planifiée sur les backends ?" "INFO" "Yellow"
Write-Log "  [Y] Oui - Créer la tâche planifiée (exécution à 22h00)" "INFO" "Gray"
Write-Log "  [N] Non - La tâche sera créée lors de la prochaine exécution du script" "INFO" "Gray"
$responseTask = Read-Host "  Votre choix (Y/N)"

if ($responseTask -eq "Y" -or $responseTask -eq "y") {
    Write-Section "CRÉATION DE LA TÂCHE PLANIFIÉE À 22H00 (10 PM)"
    
    $TaskSuccess = 0
    $TaskFail = 0
    $TaskResults = @()
    
    foreach ($backend in $Backends) {
        $fqdn = "$backend.$Domain"
        Write-Log "`n╔═══════════════════════════════════════════════════════════════╗" "INFO" "Yellow"
        Write-Log "║  Création de la tâche sur $fqdn" "INFO" "Yellow"
        Write-Log "╚═══════════════════════════════════════════════════════════════╝" "INFO" "Yellow"
        
        $taskScriptBlock = {
            param([string]$RemoteScriptPath)
            
            $log = @()
            $success = $true
            $taskName = "IIS-SAN-Cert-Renewal"
            
            try {
                # Vérifier si la tâche existe
                $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                
                if ($existingTask) {
                    # Supprimer l'ancienne tâche
                    $log += "⚠️ La tâche '$taskName' existe déjà, suppression en cours..."
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                    $log += "✅ Ancienne tâche supprimée"
                }
                
                # Créer la nouvelle tâche à 22h00 (10 PM)
                $log += "Création de la nouvelle tâche à 22h00..."
                
                $action = New-ScheduledTaskAction -Execute "powershell.exe" `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RemoteScriptPath`""
                
                $trigger = New-ScheduledTaskTrigger -Daily -At 10pm
                
                $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
                
                $settings = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries `
                    -StartWhenAvailable `
                    -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 1)
                
                Register-ScheduledTask -TaskName $taskName `
                    -Action $action `
                    -Trigger $trigger `
                    -Principal $principal `
                    -Settings $settings `
                    -Force
                
                $log += "✅ Tâche '$taskName' créée avec succès"
                $log += "   Exécution quotidienne à 22h00 (10 PM)"
                
            } catch {
                $log += "❌ Erreur : $($_.Exception.Message)"
                $success = $false
            }
            
            return @{
                Logs = $log
                Success = $success
            }
        }
        
        $taskResult = Invoke-RemoteScriptBlock -ComputerName $fqdn -ScriptBlock $taskScriptBlock -ArgumentList $RemoteScriptPath
        
        if ($taskResult -eq $null) {
            Write-Log "  ❌ Échec de la création sur $fqdn" "ERROR" "Red"
            $TaskFail++
            $TaskResults += "$fqdn|FAILED|Exécution distante échouée"
            continue
        }
        
        foreach ($logLine in $taskResult.Logs) {
            Write-Log "  $logLine" "INFO" "Gray"
        }
        
        if ($taskResult.Success) {
            Write-Log "  ✅ Tâche configurée avec succès sur $fqdn" "SUCCESS" "Green"
            $TaskSuccess++
            $TaskResults += "$fqdn|SUCCESS|Créée à 22h00"
        } else {
            Write-Log "  ❌ Échec sur $fqdn" "ERROR" "Red"
            $TaskFail++
            $TaskResults += "$fqdn|FAILED|Erreur création"
        }
    }
    
    Write-Log "`n  --- RÉSULTAT CRÉATION TÂCHE ---" "INFO" "Cyan"
    foreach ($result in $TaskResults) {
        $parts = $result -split "\|"
        $server = $parts[0]
        $status = $parts[1]
        $detail = $parts[2]
        
        $icon = if ($status -eq "SUCCESS") { "✅" } else { "❌" }
        $color = if ($status -eq "SUCCESS") { "Green" } else { "Red" }
        Write-Log "    $icon $server : $status - $detail" "INFO" $color
    }
    
    Write-Log "`n  Résultat création tâche : $TaskSuccess succès, $TaskFail échecs" "INFO" "Cyan"
}

# ==================================================================================================
# SECTION 7 : FIN
# ==================================================================================================

Write-Section "FIN DU SCRIPT"

Write-Log "  Log complet : $LogFile" "INFO" "Gray"
Write-Log "  ✅ Script terminé avec succès" "SUCCESS" "Green"

Write-Log "" "INFO" "White"
Write-Log "Appuyez sur Entrée pour fermer..." "INFO" "Yellow"
Read-Host