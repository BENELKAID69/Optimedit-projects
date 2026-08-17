# ==================================================================================================
# Nom script : 4.3.6.2..Audit-ScheduledTasks-Backends-RP.ps1
# Objet      : Audite l'état des tâches planifiées sur les backends et le Reverse-Proxy
# Exécution  : Sur OPT-RP-01 (Reverse-Proxy)
# Auteur     : Optimedit
# Date       : 13/08/2026
#
# SIMPLIFICATION V4 :
#   - Un nom de tâche pour tous les serveurs : "IIS-SAN-Cert-Renewal"
#   - Plus besoin de $TaskMapping
# ==================================================================================================

# ==================================================================================================
# SECTION 1 : CONFIGURATION
# ==================================================================================================

$Servers = @(
    "OPT-IIS-01",
    "OPT-IIS-02",
    "OPT-IIS-03",
    "OPT-IIS-04",
    "OPT-IIS-05",
    "OPT-IIS-06",
    "OPT-RP-01"
)

$Domain = "optimedit.eu"
$TaskName = "IIS-SAN-Cert-Renewal"  

$LogPath = "C:\Scripts\ADCS\logs"
$OutputFile = "$LogPath\Audit-ScheduledTasks-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$LogFile = "$LogPath\Audit-ScheduledTasks-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

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

function Write-Header {
    Write-Log "" "INFO" "White"
    Write-Log "╔═══════════════════════════════════════════════════════════════╗" "INFO" "Cyan"
    Write-Log "║        AUDIT TÂCHES PLANIFIÉES - BACKENDS ET RP             ║" "INFO" "Cyan"
    Write-Log "╚═══════════════════════════════════════════════════════════════╝" "INFO" "Cyan"
    Write-Log "  Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" "Gray"
    Write-Log "  Serveurs : $($Servers.Count) (6 backends + 1 RP)" "INFO" "Gray"
    Write-Log "  Tâche : $TaskName" "INFO" "Gray"
    Write-Log "  Output : $OutputFile" "INFO" "Gray"
    Write-Log "  Log : $LogFile" "INFO" "Gray"
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

# ==================================================================================================
# SECTION 3 : RÉCUPÉRATION DES INFOS DE LA TÂCHE
# ==================================================================================================

function Get-ScheduledTaskInfo {
    param(
        [string]$ComputerName,
        [string]$TaskName
    )
    
    $scriptBlock = {
        param([string]$TaskName, [string]$ComputerName)
        
        $result = [PSCustomObject]@{
            Server = $ComputerName
            TaskName = $TaskName
            State = "N/A"
            Enabled = "N/A"
            LastRunTime = "N/A"
            NextRunTime = "N/A"
            LastTaskResult = "N/A"
            Trigger = "N/A"
            Action = "N/A"
            UserId = "N/A"
            Exists = $false
            Error = $null
        }
        
        try {
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            
            if (-not $task) {
                $result.Error = "Tâche non trouvée"
                return $result
            }
            
            $result.Exists = $true
            $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            
            if ($taskInfo) {
                $result.State = $task.State.ToString()
                $result.LastRunTime = if ($taskInfo.LastRunTime) { $taskInfo.LastRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Jamais exécutée" }
                $result.NextRunTime = if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Non planifiée" }
                $result.LastTaskResult = $taskInfo.LastTaskResult
            }
            
            # Déclencheurs
            $triggers = $task.Triggers
            if ($triggers -and $triggers.Count -gt 0) {
                $triggerInfo = @()
                foreach ($trigger in $triggers) {
                    $triggerType = $trigger.GetType().Name
                    if ($triggerType -eq "DailyTrigger") {
                        $triggerInfo += "Quotidien à $($trigger.StartBoundary)"
                    } else {
                        $triggerInfo += $triggerType
                    }
                }
                $result.Trigger = $triggerInfo -join "; "
            } else {
                $result.Trigger = "Aucun déclencheur"
            }
            
            # Actions
            $actions = $task.Actions
            if ($actions -and $actions.Count -gt 0) {
                $actionInfo = @()
                foreach ($action in $actions) {
                    if ($action.GetType().Name -eq "ExecAction") {
                        $actionInfo += "$($action.Execute) $($action.Arguments)"
                    } else {
                        $actionInfo += $action.GetType().Name
                    }
                }
                $result.Action = $actionInfo -join "; "
            } else {
                $result.Action = "Aucune action"
            }
            
            # Utilisateur
            $principal = $task.Principal
            if ($principal) {
                $result.UserId = $principal.UserId
            }
            
            # Activée
            $settings = $task.Settings
            if ($settings) {
                $result.Enabled = $settings.Enabled
            }
            
            if ($task.State -eq "Disabled") {
                $result.Enabled = $false
            }
            
        } catch {
            $result.Error = $_.Exception.Message
            $result.Exists = $false
        }
        
        return $result
    }
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        $result = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $TaskName, $ComputerName -ErrorAction Stop
        Remove-PSSession $session
        return $result
    } catch {
        return [PSCustomObject]@{
            Server = $ComputerName
            TaskName = $TaskName
            State = "N/A"
            Enabled = "N/A"
            LastRunTime = "N/A"
            NextRunTime = "N/A"
            LastTaskResult = "N/A"
            Trigger = "N/A"
            Action = "N/A"
            UserId = "N/A"
            Exists = $false
            Error = "Erreur WinRM: $($_.Exception.Message)"
        }
    }
}

# ==================================================================================================
# SECTION 4 : MAIN
# ==================================================================================================

Write-Header

Write-Log "=== DÉMARRAGE DE L'AUDIT ===" "INFO" "Cyan"

$AllResults = @()
$SuccessCount = 0
$FailCount = 0
$MissingTasks = 0
$DisabledTasks = 0

foreach ($server in $Servers) {
    $fqdn = "$server.$Domain"
    $isLocal = ($server -eq "OPT-RP-01")
    
    # Affichage
    if ($isLocal) {
        Write-Log "`n--- LOCAL (RP) ---" "INFO" "Yellow"
    } else {
        Write-Log "`n--- BACKEND $server ---" "INFO" "Yellow"
    }
    
    Write-Log "  Recherche de la tâche '$TaskName' sur $fqdn..." "INFO" "Gray"
    
    if ($isLocal) {
        $result = Get-ScheduledTaskInfo -ComputerName $env:COMPUTERNAME -TaskName $TaskName
    } else {
        # Test WinRM
        if (-not (Test-WinRMConnection -ComputerName $fqdn)) {
            Write-Log "    ❌ Connexion WinRM impossible" "ERROR" "Red"
            $AllResults += [PSCustomObject]@{
                Server = $fqdn
                TaskName = $TaskName
                State = "N/A"
                Enabled = "N/A"
                LastRunTime = "N/A"
                NextRunTime = "N/A"
                LastTaskResult = "N/A"
                Trigger = "N/A"
                Action = "N/A"
                UserId = "N/A"
                Exists = $false
                Error = "WinRM impossible"
            }
            $FailCount++
            continue
        }
        
        $result = Get-ScheduledTaskInfo -ComputerName $fqdn -TaskName $TaskName
    }
    
    if ($result) {
        $AllResults += $result
        if ($result.Exists) {
            $SuccessCount++
            Write-Log "    ✅ Tâche trouvée : $($result.State)" "SUCCESS" "Green"
            if ($result.State -eq "Disabled") {
                $DisabledTasks++
                Write-Log "       ⚠️ ATTENTION : Tâche désactivée !" "WARNING" "Yellow"
            }
        } else {
            $MissingTasks++
            $FailCount++
            Write-Log "    ⚠️ Tâche non trouvée" "WARNING" "Yellow"
        }
    } else {
        $FailCount++
        Write-Log "    ❌ Échec de la récupération" "ERROR" "Red"
    }
}

# ==================================================================================================
# SECTION 5 : EXPORT CSV
# ==================================================================================================

Write-Log "`n=== EXPORT DES RÉSULTATS ===" "INFO" "Cyan"

if ($AllResults.Count -gt 0) {
    $AllResults | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8 -Delimiter ";"
    Write-Log "  ✅ CSV exporté : $OutputFile" "SUCCESS" "Green"
    Write-Log "     $($AllResults.Count) lignes" "INFO" "Gray"
}

# ==================================================================================================
# SECTION 6 : RAPPORT DÉTAILLÉ
# ==================================================================================================

Write-Log "`n=== RAPPORT DÉTAILLÉ ===" "INFO" "Cyan"

# Synthèse
Write-Log "`n--- SYNTHÈSE DES TÂCHES ---" "INFO" "Yellow"
$taskStates = $AllResults | Group-Object State
foreach ($group in $taskStates) {
    $state = $group.Name
    $count = $group.Count
    $icon = if ($state -eq "Ready") { "✅" } elseif ($state -eq "Disabled") { "⚠️" } else { "❓" }
    $color = if ($state -eq "Ready") { "Green" } elseif ($state -eq "Disabled") { "Yellow" } else { "Red" }
    Write-Log "  $icon $state : $count tâche(s)" "INFO" $color
}

# Détail
Write-Log "`n--- DÉTAIL DES TÂCHES ---" "INFO" "Yellow"

foreach ($result in $AllResults) {
    $statusIcon = if ($result.State -eq "Ready") { "✅" } else { "❌" }
    $statusColor = if ($result.State -eq "Ready") { "Green" } else { "Red" }
    
    Write-Log "`n  $statusIcon $($result.TaskName) ($($result.Server))" "INFO" $statusColor
    
    if (-not $result.Exists) {
        Write-Log "      ❌ Tâche non trouvée" "ERROR" "Red"
        if ($result.Error) {
            Write-Log "      Erreur : $($result.Error)" "ERROR" "Red"
        }
        continue
    }
    
    Write-Log "      État : $($result.State)" "INFO" "Gray"
    Write-Log "      Activée : $($result.Enabled)" "INFO" "Gray"
    Write-Log "      Dernière exécution : $($result.LastRunTime)" "INFO" "Gray"
    Write-Log "      Prochaine exécution : $($result.NextRunTime)" "INFO" "Gray"
    Write-Log "      Résultat : $($result.LastTaskResult)" "INFO" "Gray"
    
    if ($result.LastTaskResult -ne "N/A" -and $result.LastTaskResult -ne $null) {
        if ($result.LastTaskResult -eq 0) {
            Write-Log "      📌 SUCCÈS (0)" "SUCCESS" "Green"
        } else {
            Write-Log "      📌 ÉCHEC ($($result.LastTaskResult))" "ERROR" "Red"
        }
    }
    
    Write-Log "      Déclencheur : $($result.Trigger)" "INFO" "Gray"
    Write-Log "      Utilisateur : $($result.UserId)" "INFO" "Gray"
}

# Anomalies
Write-Log "`n--- ANOMALIES ---" "INFO" "Yellow"

$anomalies = $AllResults | Where-Object { 
    -not $_.Exists -or 
    $_.State -eq "Disabled" -or 
    ($_.LastTaskResult -ne "N/A" -and $_.LastTaskResult -ne 0 -and $_.LastTaskResult -ne $null)
}

if ($anomalies.Count -gt 0) {
    Write-Log "  ⚠️ $($anomalies.Count) anomalie(s) détectée(s) :" "WARNING" "Yellow"
    foreach ($item in $anomalies) {
        if (-not $item.Exists) {
            Write-Log "      ❌ $($item.Server) : Tâche non trouvée" "ERROR" "Red"
        } elseif ($item.State -eq "Disabled") {
            Write-Log "      ⚠️ $($item.Server) : Tâche désactivée" "WARNING" "Yellow"
        } elseif ($item.LastTaskResult -ne "N/A" -and $item.LastTaskResult -ne 0) {
            Write-Log "      ❌ $($item.Server) : Échec (Code: $($item.LastTaskResult))" "ERROR" "Red"
        }
    }
} else {
    Write-Log "  ✅ Aucune anomalie" "SUCCESS" "Green"
}

# ==================================================================================================
# SECTION 7 : RAPPORT FINAL
# ==================================================================================================

Write-Log "`n========================================" "INFO" "Cyan"
Write-Log "RAPPORT FINAL" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"
Write-Log "  ✅ Tâches trouvées : $SuccessCount" "SUCCESS" "Green"
Write-Log "  ❌ Tâches manquantes : $MissingTasks" "ERROR" "Red"
Write-Log "  ⚠️ Tâches désactivées : $DisabledTasks" "WARNING" "Yellow"
Write-Log "  📊 Total serveurs : $($Servers.Count)" "INFO" "Cyan"
Write-Log "  📁 CSV : $OutputFile" "INFO" "Gray"

if ($MissingTasks -eq 0 -and $DisabledTasks -eq 0) {
    Write-Log "`n  🎉 TOUTES LES TÂCHES SONT CORRECTEMENT CONFIGURÉES !" "SUCCESS" "Green"
} elseif ($MissingTasks -gt 0) {
    Write-Log "`n  ⚠️ Des tâches sont manquantes." "WARNING" "Yellow"
} else {
    Write-Log "`n  ⚠️ Des tâches sont désactivées." "WARNING" "Yellow"
}

Write-Log "`n✅ Audit terminé" "SUCCESS" "Green"
Write-Log "========================================" "INFO" "Cyan"

Write-Log "`nAppuyez sur Entrée pour fermer..." "INFO" "Yellow"
Read-Host