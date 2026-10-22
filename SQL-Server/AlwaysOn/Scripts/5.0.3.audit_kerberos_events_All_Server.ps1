<#
.SYNOPSIS
    Audit des événements Kerberos (4768 TGT et 4769 TGS) - Version multi-versions.

.DESCRIPTION
    Ce script collecte, analyse et exporte les événements Kerberos 4768 (TGT)
    et 4769 (TGS) depuis le journal de sécurité d'un contrôleur de domaine.

    ✅ VERSION MULTI-VERSIONS (avec détection par élimination)
    Compatible avec :
      - Windows Server 2016
      - Windows Server 2019
      - Windows Server 2022
      - Windows Server 2025

    MÉTHODE DE DÉTECTION DU STATUS :
      Le Status est un Int32 entre 0 et 100, en évitant :
        - TicketOptions (>1000000)
        - EncryptionType (1-50)
      On cherche dans une fenêtre de 6 positions après TicketOptions.

.PARAMETER ServerName
    Nom FQDN du contrôleur de domaine. Défaut : DC03.optimedit.eu

.PARAMETER Days
    Période d'audit en jours. Défaut : 10

.PARAMETER ExportFolder
    Dossier de destination des exports CSV. Défaut : C:\Audit\Kerberos

.PARAMETER EventIDs
    IDs d'événements à analyser. Défaut : @(4768, 4769)

.PARAMETER TopCount
    Nombre d'entrées à afficher dans les Top. Défaut : 10

.PARAMETER LogPath
    Chemin du fichier de log. Défaut : .\5.0.3.audit_kerberos_events_All_Server.log

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 3.1 (Multi-versions - détection corrigée)
    Nœud    : DC03
.EXAMPLE
    # Audit standard sur 10 jours
    .\5.0.3.audit_kerberos_events_All_Server.ps1

.EXAMPLE
    # Audit sur 30 jours avec export dans un dossier spécifique
    .\5.0.3.audit_kerberos_events_All_Server.ps1 -Days 30 

.EXAMPLE
    # Audit uniquement des TGT (4768)
    .\5.0.3.audit_kerberos_events_All_Server.ps1 -EventIDs 4768
   ===========================================================================
    ⚠️  PRÉREQUIS : ACTIVATION DES LOGS D'AUDIT KERBEROS
    ===========================================================================

    Avant d'exécuter ce script, l'audit Kerberos DOIT être activé via GPO
    sur le contrôleur de domaine. Sans cela, AUCUN événement 4768/4769
    ne sera présent dans le journal de sécurité.

    📋 PROCÉDURE D'ACTIVATION (sur DC03, via gpmc.msc) :

    1. Créer ou éditer un GPO :
       - Créez un nouveau GPO (par exemple « Audit Kerberos »)
         OU éditez le « Default Domain Controllers Policy ».

    2. Naviguer dans l'arborescence :
       Configuration ordinateur
         → Stratégies
           → Paramètres Windows
             → Paramètres de sécurité
               → Configuration avancée des stratégies d'audit
                 → Stratégies d'audit
                   → Ouverture de session de compte

    3. Activer les deux stratégies (cocher « Réussite » ET « Échec ») :
       ✅ Auditer le service d'authentification Kerberos
          → génère l'événement 4768 (demandes de TGT)

       ✅ Auditer les opérations de ticket de service Kerberos
          → génère l'événement 4769 (demandes de TGS)

    4. Appliquer la stratégie :
       gpupdate /force

    📊 OÙ CONSULTER LES ÉVÉNEMENTS :

    Observateur d'événements
      → Journaux Windows
        → Sécurité

    Filtrer par ID :
      • 4768 : Demande de ticket TGT (authentification initiale)
      • 4769 : Demande de ticket de service (accès à une ressource)
      • 4771 : Échec de pré-authentification Kerberos

    🧪 TEST DE VALIDATION (sur un serveur membre, ex. SQLS02) :

    # 1. Purger le cache Kerberos
    klist purge

    # 2. Se connecter à SQLS01 (génère un événement 4769)
    sqlcmd -S SQLS01.optimedit.eu -E -Q "SELECT @@SERVERNAME"

    # 3. Vérifier les tickets obtenus
    klist

    # 4. Sur DC03, vérifier la présence de l'événement 4769
    #    dans le journal Sécurité.

    ===========================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerName = "DC03.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$Days = 10,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ExportFolder = "C:\Audit\Kerberos",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [int[]]$EventIDs = @(4768, 4769),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$TopCount = 10,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\5.0.3.audit_kerberos_events_All_Server.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:Results = @()

try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
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

function Get-EventName {
    param([int]$EventID)
    switch ($EventID) {
        4768 { return "TGT (Ticket Granting Ticket)" }
        4769 { return "TGS (Ticket Granting Service)" }
        4771 { return "Échec de pré-authentification Kerberos" }
        default { return "Événement $EventID" }
    }
}

function Convert-IPv6MappedToIPv4 {
    param([string]$IpAddress)
    if ([string]::IsNullOrWhiteSpace($IpAddress)) { return "" }
    if ($IpAddress -match "^::ffff:(\d+\.\d+\.\d+\.\d+)$") { return $Matches[1] }
    return $IpAddress
}

function Get-KerberosEvents {
    param(
        [Parameter(Mandatory = $true)] [string]$ComputerName,
        [Parameter(Mandatory = $true)] [int]$EventID,
        [Parameter(Mandatory = $true)] [datetime]$StartTime,
        [Parameter(Mandatory = $false)] [string]$LogName = "Security"
    )

    $filter = @{
        LogName   = $LogName
        ID        = $EventID
        StartTime = $StartTime
    }

    try {
        $events = Get-WinEvent -FilterHashtable $filter -ComputerName $ComputerName -ErrorAction Stop
        return @($events)
    } catch {
        if ($_.Exception.Message -like "*No events were found*") { return @() }
        throw
    }
}

function Get-DynamicIndexes {
    <#
    .SYNOPSIS
        Détecte dynamiquement les index des propriétés critiques d'un événement Kerberos.
    .DESCRIPTION
        Méthode de détection par élimination :
          1. TicketOptions : Int32 > 1000000 (grande valeur)
          2. EncryptionType : 1er Int32 entre 1 et 50 après TicketOptions
          3. IpAddress : String contenant "::" ou format IP
          4. Status : 1er Int32 entre 0 et 100 après TicketOptions,
                      en SAUTANT EncryptionType (fenêtre de 6 positions)

        Cette méthode est robuste aux variations WS2016/2019/2022/2025 :
          - WS 2025 4768 : Status à [6]  (juste après TicketOptions)
          - WS 2025 4769 : Status à [8]  (après IpPort)
    #>
    param($Properties)

    $statusIndex         = -1
    $ipAddressIndex      = -1
    $ipPortIndex         = -1
    $ticketOptionsIndex  = -1
    $encryptionTypeIndex = -1

    # --- ÉTAPE 1 : TicketOptions (Int32 > 1000000) ---
    for ($i = 0; $i -lt $Properties.Count; $i++) {
        $val = $Properties[$i].Value
        if ($val.GetType().Name -eq "Int32" -and $val -gt 1000000) {
            $ticketOptionsIndex = $i
            break
        }
    }

    # --- ÉTAPE 2 : EncryptionType (1er Int32 1-50 après TicketOptions) ---
    if ($ticketOptionsIndex -ge 0) {
        for ($i = $ticketOptionsIndex + 1; $i -lt $Properties.Count; $i++) {
            $val = $Properties[$i].Value
            if ($val.GetType().Name -eq "Int32" -and $val -ge 1 -and $val -le 50) {
                $encryptionTypeIndex = $i
                break
            }
        }
    }

    # --- ÉTAPE 3 : IpAddress (String IP) ---
    for ($i = 0; $i -lt $Properties.Count; $i++) {
        $val = $Properties[$i].Value
        if ($val.GetType().Name -eq "String" -and $val -match "^::|^\d+\.\d+\.\d+\.\d+$") {
            $ipAddressIndex = $i
            break
        }
    }

    # --- ÉTAPE 4 : IpPort (String numérique juste après IpAddress) ---
    if ($ipAddressIndex -ge 0 -and $ipAddressIndex + 1 -lt $Properties.Count) {
        $nextVal = $Properties[$ipAddressIndex + 1].Value
        if ($nextVal.GetType().Name -eq "String" -and $nextVal -match "^\d+$") {
            $ipPortIndex = $ipAddressIndex + 1
        }
    }

    # --- ÉTAPE 5 : Status (détection par élimination) ---
    # Chercher le 1er Int32 entre 0 et 100 après TicketOptions,
    # en SAUTANT l'index identifié comme EncryptionType.
    if ($ticketOptionsIndex -ge 0) {
        $windowEnd = [Math]::Min($ticketOptionsIndex + 6, $Properties.Count - 1)
        for ($i = $ticketOptionsIndex + 1; $i -le $windowEnd; $i++) {
            if ($i -eq $encryptionTypeIndex) { continue }
            $val = $Properties[$i].Value
            if ($val.GetType().Name -eq "Int32" -and $val -ge 0 -and $val -le 100) {
                $statusIndex = $i
                break
            }
        }
    }

    # Fallback : si rien trouvé, chercher à partir de 0
    if ($statusIndex -eq -1) {
        for ($i = 0; $i -lt $Properties.Count; $i++) {
            if ($i -eq $encryptionTypeIndex) { continue }
            if ($i -eq $ticketOptionsIndex) { continue }
            $val = $Properties[$i].Value
            if ($val.GetType().Name -eq "Int32" -and $val -ge 0 -and $val -le 100) {
                $statusIndex = $i
                break
            }
        }
    }

    return [PSCustomObject]@{
        StatusIndex          = $statusIndex
        IpAddressIndex       = $ipAddressIndex
        IpPortIndex          = $ipPortIndex
        TicketOptionsIndex   = $ticketOptionsIndex
        EncryptionTypeIndex  = $encryptionTypeIndex
    }
}

function Convert-EventToObject {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Eventing.Reader.EventLogRecord]$Event,

        [Parameter(Mandatory = $true)]
        [int]$EventID
    )

    $prop = $Event.Properties
    $count = $prop.Count

    $indexes = Get-DynamicIndexes -Properties $prop

    # Status
    $statusInt = if ($indexes.StatusIndex -ge 0) { $prop[$indexes.StatusIndex].Value } else { -1 }
    $statusHex = "0x{0:X}" -f $statusInt

    # IpAddress
    $ipRaw = if ($indexes.IpAddressIndex -ge 0) { $prop[$indexes.IpAddressIndex].Value } else { "" }
    $ipClean = Convert-IPv6MappedToIPv4 -IpAddress $ipRaw

    # TicketOptions
    $ticketOptHex = if ($indexes.TicketOptionsIndex -ge 0) {
        "0x{0:X}" -f $prop[$indexes.TicketOptionsIndex].Value
    } else { "" }

    # EncryptionType
    $encTypeHex = if ($indexes.EncryptionTypeIndex -ge 0) {
        "0x{0:X}" -f $prop[$indexes.EncryptionTypeIndex].Value
    } else { "" }

    # TargetUser / TargetDomain
    $targetUser = if ($count -gt 0) { $prop[0].Value } else { "" }
    $targetDomain = if ($count -gt 1) { $prop[1].Value } else { "" }

    # ServiceName
    $serviceName = ""
    if ($EventID -eq 4768 -and $count -gt 3) { $serviceName = $prop[3].Value }
    elseif ($EventID -eq 4769 -and $count -gt 2) { $serviceName = $prop[2].Value }

    return [PSCustomObject]@{
        Timestamp             = $Event.TimeCreated
        EventID               = $EventID
        EventName             = Get-EventName -EventID $EventID
        TargetUserName        = $targetUser
        TargetDomain          = $targetDomain
        ServiceName           = $serviceName
        TicketOptions         = $ticketOptHex
        TicketEncryptionType  = $encTypeHex
        IpAddress             = $ipClean
        Status                = $statusHex
        Success               = ($statusInt -eq 0)
        ServerDC              = $env:COMPUTERNAME
    }
}

function Show-TopList {
    param(
        [Parameter(Mandatory = $true)] [array]$Data,
        [Parameter(Mandatory = $true)] [string]$Property,
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $false)] [int]$Top = 10
    )

    Write-Host ""
    Write-Host "  $Title :" -ForegroundColor Yellow

    $grouped = $Data | Where-Object { $_.$Property } |
        Group-Object -Property $Property |
        Sort-Object Count -Descending |
        Select-Object -First $Top

    if ($grouped.Count -eq 0) {
        Write-Host "    (aucune donnée)" -ForegroundColor DarkGray
        return
    }

    foreach ($item in $grouped) {
        $name = $item.Name
        if ($name.Length -gt 50) { $name = $name.Substring(0, 47) + "..." }
        Write-Host ("    {0,6}  {1}" -f $item.Count, $name) -ForegroundColor Gray
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.0.3 - Audit des événements Kerberos (Multi-versions v3.1)"
    Write-Host " Serveur          : $ServerName" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " PowerShell       : $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host " Période          : $Days derniers jours" -ForegroundColor Gray
    Write-Host " IDs              : $($EventIDs -join ', ')" -ForegroundColor Gray
    Write-Host " Dossier export   : $ExportFolder" -ForegroundColor Gray
    Write-Host " Log              : $LogPath" -ForegroundColor Gray
    Write-Host " Version script   : Multi-versions v3.1 (détection corrigée)" -ForegroundColor Yellow

    # --- PRÉ-VOL 1 ---
    Write-Section "Pré-vol 1/3 : Vérification des privilèges"
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ce script doit être exécuté en tant qu'administrateur."
    }
    Write-Step "Privilèges administrateur confirmés" "OK"

    # --- PRÉ-VOL 2 ---
    Write-Section "Pré-vol 2/3 : Vérification de la connectivité au DC"
    try {
        Test-Connection -ComputerName $ServerName -Count 1 -Quiet -ErrorAction Stop | Out-Null
        Write-Step "Connectivité à $ServerName confirmée" "OK"
    } catch {
        throw "Impossible de contacter $ServerName : $($_.Exception.Message)"
    }

    # --- PRÉ-VOL 3 ---
    Write-Section "Pré-vol 3/3 : Préparation du dossier d'export"
    if (-not (Test-Path $ExportFolder)) {
        New-Item -Path $ExportFolder -ItemType Directory -Force | Out-Null
        Write-Step "Dossier créé : $ExportFolder" "OK"
    } else {
        Write-Step "Dossier existant : $ExportFolder" "OK"
    }

    # --- COLLECTE ---
    $timestamp = (Get-Date).ToString("yyyyMMdd_HHmm")
    $startTime = (Get-Date).AddDays(-$Days)

    Write-Section "Collecte des événements Kerberos"
    Write-Host "  Période : du $startTime à $(Get-Date -Format 'dd/MM/yyyy HH:mm')" -ForegroundColor Gray

    $allResults = @{}

    foreach ($eventId in $EventIDs) {
        $eventName = Get-EventName -EventID $eventId
        Write-Host ""
        Write-Host "  ── Event ID $eventId ($eventName) ──" -ForegroundColor Magenta

        try {
            $events = Get-KerberosEvents -ComputerName $ServerName `
                -EventID $eventId -StartTime $startTime -LogName "Security"

            if ($events.Count -eq 0) {
                Write-Step "Aucun événement $eventId trouvé" "WARN"
                $script:Warnings += "Aucun événement $eventId ($eventName) trouvé"
                $allResults[$eventId] = @()
                continue
            }

            Write-Step "$($events.Count) événements $eventId collectés" "OK"

            $converted = foreach ($evt in $events) {
                Convert-EventToObject -Event $evt -EventID $eventId
            }

            $allResults[$eventId] = @($converted)
        } catch {
            Write-Step "Erreur lors de la collecte de l'ID $eventId : $($_.Exception.Message)" "ERROR"
            $script:Errors += "ID $eventId : $($_.Exception.Message)"
            $allResults[$eventId] = @()
        }
    }

    # --- EXPORT CSV ---
    Write-Section "Export CSV par ID d'événement"

    foreach ($eventId in $EventIDs) {
        $data = $allResults[$eventId]
        $eventName = Get-EventName -EventID $eventId

        if ($data.Count -eq 0) {
            Write-Step "ID $eventId ($eventName) : aucun export (0 événement)" "SKIP"
            continue
        }

        $rawFileName = "Kerberos_${eventId}_Raw_${ServerName}_${timestamp}.csv"
        $rawFilePath = Join-Path $ExportFolder $rawFileName
        $data | Export-Csv -Path $rawFilePath -NoTypeInformation -Encoding UTF8
        Write-Step "Export brut ID $eventId : $rawFilePath" "OK"

        $uniqueUsers = $data | Where-Object { $_.TargetUserName } |
            Select-Object -ExpandProperty TargetUserName | Sort-Object -Unique

        $uniqueFileName = "Kerberos_${eventId}_Unique_${ServerName}_${timestamp}.csv"
        $uniqueFilePath = Join-Path $ExportFolder $uniqueFileName

        $uniqueExport = $uniqueUsers | ForEach-Object {
            [PSCustomObject]@{
                EventID      = $eventId
                EventName    = $eventName
                ActiveEntity = $_
                AuditDate    = (Get-Date).ToString("yyyy-MM-dd")
                ServerDC     = $ServerName
            }
        }
        $uniqueExport | Export-Csv -Path $uniqueFilePath -NoTypeInformation -Encoding UTF8
        Write-Step "Export uniques ID $eventId : $uniqueFilePath ($($uniqueUsers.Count) entités)" "OK"

        $script:Results += [PSCustomObject]@{
            EventID       = $eventId
            EventName     = $eventName
            TotalEvents   = $data.Count
            UniqueUsers   = $uniqueUsers.Count
            RawFile       = $rawFilePath
            UniqueFile    = $uniqueFilePath
        }
    }

    # --- STATISTIQUES ---
    Write-Section "Statistiques détaillées"

    foreach ($eventId in $EventIDs) {
        $data = $allResults[$eventId]
        $eventName = Get-EventName -EventID $eventId

        Write-Host ""
        Write-Host ("━" * 70) -ForegroundColor DarkMagenta
        Write-Host "  EVENT ID $eventId - $eventName" -ForegroundColor Magenta
        Write-Host ("━" * 70) -ForegroundColor DarkMagenta

        if ($data.Count -eq 0) {
            Write-Host "  Aucun événement à analyser." -ForegroundColor DarkGray
            continue
        }

        $successCount = ($data | Where-Object { $_.Success }).Count
        $failureCount = $data.Count - $successCount
        $uniqueUsersCount = ($data | Where-Object { $_.TargetUserName } |
            Select-Object -ExpandProperty TargetUserName -Unique).Count
        $uniqueIPsCount = ($data | Where-Object { $_.IpAddress -and $_.IpAddress -ne "::1" } |
            Select-Object -ExpandProperty IpAddress -Unique).Count

        Write-Host ""
        Write-Host "  📊 Statistiques globales :" -ForegroundColor Yellow
        Write-Host "     Total événements     : $($data.Count)" -ForegroundColor Gray
        Write-Host "     Réussites            : $successCount" -ForegroundColor Green
        Write-Host "     Échecs               : $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { 'Red' } else { 'Gray' })
        Write-Host "     Comptes uniques      : $uniqueUsersCount" -ForegroundColor Cyan
        Write-Host "     Adresses IP uniques  : $uniqueIPsCount" -ForegroundColor Cyan

        Show-TopList -Data $data -Property "TargetUserName" `
            -Title "Top $TopCount comptes" -Top $TopCount
        Show-TopList -Data $data -Property "IpAddress" `
            -Title "Top $TopCount adresses IP" -Top $TopCount
        Show-TopList -Data $data -Property "TicketOptions" `
            -Title "Top $TopCount TicketOptions" -Top $TopCount
        Show-TopList -Data $data -Property "TicketEncryptionType" `
            -Title "Top $TopCount types de chiffrement" -Top $TopCount

        if ($failureCount -gt 0) {
            Write-Host ""
            Write-Host "  ⚠️  Détail des échecs :" -ForegroundColor Red
            $failures = $data | Where-Object { -not $_.Success } | Select-Object -First 10
            foreach ($f in $failures) {
                Write-Host ("     [{0}] {1} - Status: {2} - IP: {3}" -f
                    $f.Timestamp.ToString("dd/MM HH:mm"),
                    $f.TargetUserName,
                    $f.Status,
                    $f.IpAddress) -ForegroundColor Red
            }
            if ($failureCount -gt 10) {
                Write-Host "     (... et $($failureCount - 10) autres échecs - voir CSV)" -ForegroundColor DarkGray
            }
        }
    }

    # --- RÉSUMÉ ---
    $duration = (Get-Date) - $script:StartTime
    Write-Section "Résumé de l'audit"
    Write-Host ""
    Write-Host "  Durée totale : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""

    if ($script:Results.Count -gt 0) {
        Write-Host "  Exports générés :" -ForegroundColor Cyan
        $script:Results | Format-Table EventID, EventName, TotalEvents, UniqueUsers -AutoSize

        Write-Host "  Chemins des fichiers :" -ForegroundColor Cyan
        foreach ($r in $script:Results) {
            Write-Host "    ID $($r.EventID) brut    : $($r.RawFile)" -ForegroundColor Gray
            Write-Host "    ID $($r.EventID) uniques : $($r.UniqueFile)" -ForegroundColor Gray
        }
    }

    if ($script:Warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "  Avertissements :" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    }

    if ($script:Errors.Count -gt 0) {
        Write-Host ""
        Write-Host "  Erreurs :" -ForegroundColor Red
        $script:Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    }

    # --- RAPPEL GPO ---
    Write-Host ""
    Write-Host ("─" * 70) -ForegroundColor DarkGray
    Write-Host "  ⚠️  RAPPEL : ACTIVATION DES LOGS D'AUDIT KERBEROS" -ForegroundColor Yellow
    Write-Host ("─" * 70) -ForegroundColor DarkGray
    Write-Host "  Sur DC03, via gpmc.msc :" -ForegroundColor Cyan
    Write-Host "    Configuration ordinateur → Stratégies → Paramètres Windows" -ForegroundColor Gray
    Write-Host "      → Paramètres de sécurité → Configuration avancée des stratégies d'audit" -ForegroundColor Gray
    Write-Host "        → Stratégies d'audit → Ouverture de session de compte" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Activer (Réussite + Échec) :" -ForegroundColor Cyan
    Write-Host "    ✅ Auditer le service d'authentification Kerberos         (→ 4768 TGT)" -ForegroundColor Gray
    Write-Host "    ✅ Auditer les opérations de ticket de service Kerberos   (→ 4769 TGS)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Puis : gpupdate /force" -ForegroundColor Cyan
    Write-Host ""

    if ($script:Errors.Count -gt 0) { exit 1 }

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
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $LogPath" -ForegroundColor DarkGray
}