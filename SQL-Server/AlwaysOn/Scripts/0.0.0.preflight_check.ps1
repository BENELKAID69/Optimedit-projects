<#
    0.0.0.preflight_check.ps1
    Objet     : Pré-vol global — vérifie WinRM puis l'état système de tous les serveurs.
    Noeuds    : Exécuter depuis un poste d'administration (ou depuis SQLS01)
    Prérequis : 
      - WinRM configuré sur tous les serveurs cibles
      - Compte administrateur du domaine (ou compte avec droits WinRM)
      - Module ActiveDirectory disponible si vérification AD souhaitée

    PRINCIPE :
    - Phase A : vérifie la résolution DNS, la connexion TCP et WinRM.
    - Phase B : vérifie l'état système (OS, RAM, CPU, disque, services).
    - Rapport final : tableau récapitulatif + alertes + export CSV optionnel.

    EXEMPLES D'EXÉCUTION :

    # Vérification standard (liste de serveurs par défaut)
    .\0.0.0.preflight_check.ps1

    # Vérification d'une liste personnalisée
    .\0.0.0.preflight_check.ps1 -Servers "SQLS01","SQLS02"

    # Inclure les 6 serveurs IIS
    .\0.0.0.preflight_check.ps1 -IncludeIIS

    # Export CSV du rapport
    .\0.0.0.preflight_check.ps1 -ExportCsv "C:\Rapports\preflight.csv"

    # Combinaison : tous les serveurs + export
    .\0.0.0.preflight_check.ps1 -IncludeIIS -ExportCsv "C:\Rapports\preflight_complet.csv"

    NOTES SUR LE CPU ET HYPER-V :
    - Sur Hyper-V, le "nombre de processeurs virtuels" alloué à une VM
      correspond au nombre de threads logiques exposés à l'OS invité.
    - Si le CPU hôte a Hyper-Threading activé (cas des Xeon Scalable),
      1 cœur physique = 2 threads logiques.
    - Conséquence : pour obtenir 4 cœurs physiques visibles dans l'OS invité,
      il faut allouer 8 processeurs virtuels dans Hyper-V.
    - Le script affiche :
        * CPU_Cores   = cœurs physiques vus par l'OS invité
        * CPU_Logical = threads logiques vus par l'OS invité
    - Recommandation : pour un serveur SQL, viser CPU_Cores >= 4,
      soit CPU_Logical >= 8.

    NOTES SUR LA RAM :
    - Sur Hyper-V, si la "Mémoire dynamique" est activée, la RAM vue par
      l'OS invité peut être très inférieure à la RAM maximale configurée.
    - Pour un serveur SQL, désactiver la Mémoire dynamique et fixer la RAM.
    - Recommandation : SQLS01 et SQLS02 à 10 GB fixes.

    NOTES SUR LE DISQUE S: :
    - Les serveurs SQL doivent disposer d'un disque S: pour héberger
      les données, logs, backups et TempDB.
    - Le script signale une alerte si S: est absent sur un serveur SQL.

    NOTES GÉNÉRALES :
    - Aucun mot de passe n'est demandé : utilise les credentials de la session.
    - Le script n'effectue AUCUNE modification sur les serveurs cibles.
    - Les erreurs WinRM sont capturées et rapportées sans interrompre le script.
#>

param(
    [string[]]$Servers = @("DC03","SQLS01","SQLS02","OPT-FS03","OPT-RP-01"),
    [switch]$IncludeIIS,
    [string]$ExportCsv,
    [int]$PingTimeoutMs = 2000
)

# --- Ajout des serveurs IIS si demandé ---
if ($IncludeIIS) {
    $IIS = 1..6 | ForEach-Object { "OPT-IIS-0$_" }
    $Servers = $Servers + $IIS
}

# --- Structure de résultat ---
$Results = @()

# ============================================================
# PHASE A — Vérification WinRM
# ============================================================
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " PHASE A — Vérification WinRM" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

foreach ($Server in $Servers) {

    Write-Host ""
    Write-Host "--- $Server ---" -ForegroundColor Yellow

    $Result = [PSCustomObject]@{
        Server        = $Server
        DNS           = "?"
        Ping          = "?"
        WinRM         = "?"
        OS            = "?"
        RAM_Total_GB  = "?"
        RAM_Free_GB   = "?"
        CPU_Cores     = "?"
        CPU_Logical   = "?"
        Disk_C_Free   = "?"
        Disk_S_Free   = "?"
        Domain        = "?"
        Uptime_Days   = "?"
        Status        = "?"
        Alerts        = ""
    }

    # --- Test DNS ---
    try {
        $ip = [System.Net.Dns]::GetHostAddresses($Server) | Select-Object -First 1
        $Result.DNS = $ip.IPAddressToString
        Write-Host "  DNS          : OK ($($Result.DNS))" -ForegroundColor Green
    } catch {
        $Result.DNS = "ECHEC"
        $Result.Status = "NON JOIGNABLE (DNS)"
        Write-Host "  DNS          : ECHEC" -ForegroundColor Red
        $Results += $Result
        continue
    }

    # --- Test Ping (via Test-Connection) ---
    try {
        $ping = Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction Stop
        if ($ping) {
            $Result.Ping = "OK"
            Write-Host "  Ping         : OK" -ForegroundColor Green
        } else {
            $Result.Ping = "ECHEC"
            Write-Host "  Ping         : ECHEC" -ForegroundColor Red
        }
    } catch {
        $Result.Ping = "ECHEC"
        Write-Host "  Ping         : ECHEC" -ForegroundColor Red
    }

    # --- Test WinRM (Test-WSMan) ---
    try {
        $wsman = Test-WSMan -ComputerName $Server -ErrorAction Stop
        $Result.WinRM = "OK"
        Write-Host "  WinRM        : OK (ProductVersion $($wsman.ProductVersion))" -ForegroundColor Green
    } catch {
        $Result.WinRM = "ECHEC"
        $Result.Status = "NON JOIGNABLE (WinRM)"
        Write-Host "  WinRM        : ECHEC - $($_.Exception.Message)" -ForegroundColor Red
        $Results += $Result
        continue
    }

    # ============================================================
    # PHASE B — Vérification système (si WinRM OK)
    # ============================================================
    try {
        $sys = Invoke-Command -ComputerName $Server -ScriptBlock {
            $os      = Get-CimInstance Win32_OperatingSystem
            $cs      = Get-CimInstance Win32_ComputerSystem
            $cpu     = Get-CimInstance Win32_Processor | Select-Object -First 1
            $disks   = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"

            $diskC = $disks | Where-Object { $_.DeviceID -eq "C:" } | Select-Object -First 1
            $diskS = $disks | Where-Object { $_.DeviceID -eq "S:" } | Select-Object -First 1

            [PSCustomObject]@{
                OS           = "$($os.Caption) $($os.Version)"
                RAM_Total_GB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
                RAM_Free_GB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
                CPU_Cores    = $cpu.NumberOfCores
                CPU_Logical  = $cpu.NumberOfLogicalProcessors
                Disk_C_Free  = if ($diskC) { [math]::Round($diskC.FreeSpace / 1GB, 2) } else { "N/A" }
                Disk_S_Free  = if ($diskS) { [math]::Round($diskS.FreeSpace / 1GB, 2) } else { "N/A" }
                Domain       = $cs.Domain
                Uptime_Days  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
            }
        } -ErrorAction Stop

        $Result.OS           = $sys.OS
        $Result.RAM_Total_GB = $sys.RAM_Total_GB
        $Result.RAM_Free_GB  = $sys.RAM_Free_GB
        $Result.CPU_Cores    = $sys.CPU_Cores
        $Result.CPU_Logical  = $sys.CPU_Logical
        $Result.Disk_C_Free  = $sys.Disk_C_Free
        $Result.Disk_S_Free  = $sys.Disk_S_Free
        $Result.Domain       = $sys.Domain
        $Result.Uptime_Days  = $sys.Uptime_Days
        $Result.Status       = "OK"

        Write-Host "  OS           : $($sys.OS)" -ForegroundColor Green
        Write-Host "  RAM          : $($sys.RAM_Total_GB) GB total, $($sys.RAM_Free_GB) GB libre" -ForegroundColor Green
        Write-Host "  CPU          : $($sys.CPU_Cores) cœurs physiques, $($sys.CPU_Logical) threads logiques" -ForegroundColor Green
        Write-Host "  Disque C:    : $($sys.Disk_C_Free) GB libre" -ForegroundColor Green

        # --- Alerte spécifique si S: est absent ---
        if ($sys.Disk_S_Free -eq "N/A") {
            Write-Host "  Disque S:    : ABSENT" -ForegroundColor Yellow
        } else {
            Write-Host "  Disque S:    : $($sys.Disk_S_Free) GB libre" -ForegroundColor Green
        }

        Write-Host "  Domaine      : $($sys.Domain)" -ForegroundColor Green
        Write-Host "  Uptime       : $($sys.Uptime_Days) jours" -ForegroundColor Green

        # --- Construction des alertes ---
        $alerts = @()
        if ($Server -match "SQL" -and $sys.Disk_S_Free -eq "N/A") {
            $alerts += "Disque S: absent"
        }
        if ($Server -match "SQL" -and [double]$sys.RAM_Total_GB -lt 8) {
            $alerts += "RAM insuffisante (< 8 GB)"
        }
        if ($Server -match "SQL" -and [int]$sys.CPU_Cores -lt 4) {
            $alerts += "CPU insuffisant (< 4 cœurs physiques)"
        }
        if ([double]$sys.RAM_Free_GB -lt 0.5) {
            $alerts += "RAM libre < 0.5 GB"
        }
        if ($alerts.Count -gt 0) {
            $Result.Alerts = $alerts -join " ; "
            Write-Host "  ALERTES      : $($Result.Alerts)" -ForegroundColor Yellow
        }

    } catch {
        $Result.Status = "ERREUR WinRM-COMMAND"
        Write-Host "  Erreur Invoke-Command : $($_.Exception.Message)" -ForegroundColor Red
    }

    $Results += $Result
}

# ============================================================
# RAPPORT FINAL
# ============================================================
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " RAPPORT FINAL" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- Tableau principal ---
$Results | Format-Table Server, DNS, Ping, WinRM, Status, OS, RAM_Total_GB, CPU_Cores, CPU_Logical, Domain -AutoSize

# --- Détail des alertes ---
$WithAlerts = $Results | Where-Object { $_.Alerts -ne "" }
if ($WithAlerts.Count -gt 0) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Yellow
Write-Host " ALERTES DÉTECTÉES" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    $WithAlerts | Select-Object Server, Alerts | Format-Table -AutoSize
}

# --- Résumé des statuts ---
$OkCount   = ($Results | Where-Object { $_.Status -eq "OK" }).Count
$FailCount = ($Results | Where-Object { $_.Status -ne "OK" }).Count

Write-Host ""
Write-Host "Résumé : $OkCount serveur(s) OK, $FailCount serveur(s) en échec." -ForegroundColor $(if ($FailCount -eq 0) { "Green" } else { "Yellow" })

# --- Export CSV optionnel ---
if ($ExportCsv) {
    $Results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Rapport exporté : $ExportCsv" -ForegroundColor Green
}

Write-Host ""
Write-Host "Pré-vol terminé. Corriger les alertes avant de continuer." -ForegroundColor Cyan