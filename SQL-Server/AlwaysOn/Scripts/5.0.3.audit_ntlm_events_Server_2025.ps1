<#
.SYNOPSIS
    Audit des événements NTLM (4032 Information / 4033 Avertissement) - Version Windows Server 2025.

.DESCRIPTION
    Complément aux scripts 5.0.3.audit_kerberos_events_*.ps1 : ceux-ci prouvent que
    Kerberos fonctionne pour les comptes qui l'utilisent, mais ne peuvent structurellement
    PAS prouver l'absence de bascule NTLM ailleurs (une connexion NTLM ne génère aucun
    4768/4769). Ce script comble cet angle mort en auditant directement le canal NTLM.

    Ce script collecte, analyse et exporte les événements NTLM 4032 et 4033
    depuis le journal Microsoft-Windows-NTLM/Operational d'un contrôleur de domaine
    exécutant Windows Server 2025.

    ⚠️ VERSION SPÉCIFIQUE WINDOWS SERVER 2025
    Utilise les index de propriétés FIXES observés sur WS2025 (schéma EventData
    17 propriétés, identique pour 4032 et 4033 - seul le niveau/Status diffère).

    FONCTIONNALITÉS :
    - Collecte les événements 4032 (Information) et 4033 (Avertissement) séparément
    - Export CSV brut par ID d'événement
    - Export CSV des entités uniques par ID
    - Statistiques affichées en console (Top comptes, Top IPs, Top SPN ciblés, échecs)
    - Classification automatique : poste hors domaine (AccountDomain=NULL) vs
      compte local sur un membre du domaine vs compte de domaine réel
    - Détection des échecs d'authentification via le champ Status (déjà formaté en hex)
    - Gestion d'erreurs robuste (try/catch/finally)
    - Logging complet via Start-Transcript
    - Compatible Windows PowerShell 5.1 et PowerShell 7+

.PARAMETER ServerName
    Nom FQDN du contrôleur de domaine. Défaut : DC03.optimedit.eu

.PARAMETER Days
    Période d'audit en jours. Défaut : 10

.PARAMETER ExportFolder
    Dossier de destination des exports CSV. Défaut : C:\Audit\NTLM

.PARAMETER EventIDs
    IDs d'événements à analyser. Défaut : @(4032, 4033)

.PARAMETER TopCount
    Nombre d'entrées à afficher dans les Top. Défaut : 10

.PARAMETER LogPath
    Chemin du fichier de log. Défaut : .\5.0.3.audit_ntlm_events_Server_2025.log

.EXAMPLE
    .\5.0.3.audit_ntlm_events_Server_2025.ps1

.EXAMPLE
    .\5.0.3.audit_ntlm_events_Server_2025.ps1 -Days 30 -TopCount 30

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0 (WS2025 - complément NTLM aux scripts Kerberos 4768/4769)
    Nœud    : DC03 (ou poste admin avec RSAT)

    ===========================================================================
    ⚠️  PRÉREQUIS : ACTIVATION DES LOGS D'AUDIT NTLM
    ===========================================================================

    Sur DC03, via gpmc.msc (GPO distincte de l'audit Kerberos) :
      1. Créer/éditer un GPO « Audit NTLM »
      2. Configuration ordinateur → Stratégies → Paramètres Windows
         → Paramètres de sécurité → Stratégies locales → Options de sécurité
      3. Activer :
         ✅ Sécurité réseau : Restreindre NTLM :
            Auditer l'authentification NTLM dans ce domaine   → Activer tout
      4. gpupdate /force

      Le journal Microsoft-Windows-NTLM/Operational doit aussi être activé
      (clic droit sur le journal dans l'Observateur d'événements → Activer
      le journal, si ce n'est pas déjà fait par la GPO).

    ===========================================================================
    📋 STRUCTURE DES ÉVÉNEMENTS SUR WINDOWS SERVER 2025
    ===========================================================================
    Journal : Microsoft-Windows-NTLM/Operational (PAS "Security")
    Source  : Microsoft-Windows-Security-Netlogon

    Event 4032 (Information) / 4033 (Avertissement) - meme schema, 17 propriétés :
      [0]  DCName
      [1]  AccountName           ← peut être "user@domaine" si poste hors domaine
      [2]  AccountDomain         ← "NULL" (poste hors AD), nom de MACHINE (compte
                                    local sur un membre) ou vrai nom de domaine
      [3]  AccountMachine
      [4]  ServerName
      [5]  ServerDomain
      [6]  ServerIP
      [7]  ServerOS
      [8]  NtlmVersion
      [9]  ServiceBinding        ← le SPN cible (ex: MSSQLSvc/SQLS01...)          ✅
      [10] TargetMachine
      [11] TargetDomain
      [12] Mic Status
      [13] AvFlags
      [14] AvFlagsStr
      [15] Status                ← déjà formaté en hex string (ex: "0xc0000064")  ✅
      [16] StatusMsg             ← équivalent décimal du Status

    Différence clé avec 4768/4769 : le champ "Level" de l'événement
    (Information=4032 / Avertissement=4033) correspond directement à
    réussite/échec sur cette infra - pas besoin de reparser le Status pour
    la classification globale, seulement pour le détail du motif d'échec.
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
    [string]$ExportFolder = "C:\Audit\NTLM",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [int[]]$EventIDs = @(4032, 4033),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$TopCount = 10,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\5.0.3.audit_ntlm_events_Server_2025.log"
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
        4032 { return "NTLM meme domaine (Information)" }
        4033 { return "NTLM meme domaine (Avertissement)" }
        default { return "Événement $EventID" }
    }
}

function ConvertTo-StatusHex {
    <# Le champ Status de 4032/4033 est deja une chaine hex ("0xc0000064"),
       mais on securise au cas ou le provider renverrait un Int32 brut. #>
    param($RawValue)
    if ($null -eq $RawValue) { return "" }
    $s = [string]$RawValue
    if ($s -match "^0x[0-9a-fA-F]+$") { return $s.ToLower() }
    $asInt = 0
    if ([int64]::TryParse($s, [ref]$asInt)) { return "0x{0:x}" -f $asInt }
    return $s
}

function Get-AccountClassification {
    <#
        Distingue les 3 cas rencontres sur cette infra :
          - "HorsDomaine"      : AccountDomain = "NULL" (poste non joint a l'AD,
                                  NTLM inevitable, PAS une anomalie)
          - "CompteLocal"      : AccountDomain = nom de la MACHINE elle-meme
                                  (compte local sur un membre du domaine -
                                  c'est la cause du bug initial de ce projet)
          - "CompteDeDomaine"  : AccountDomain = un vrai nom de domaine/NetBIOS
    #>
    param([string]$AccountDomain, [string]$AccountMachine)

    if ([string]::IsNullOrWhiteSpace($AccountDomain) -or $AccountDomain -eq "NULL") {
        return "HorsDomaine"
    }
    if (-not [string]::IsNullOrWhiteSpace($AccountMachine) -and
        $AccountDomain -eq $AccountMachine) {
        return "CompteLocal"
    }
    return "CompteDeDomaine"
}

function Get-NtlmEvents {
    param(
        [Parameter(Mandatory = $true)] [string]$ComputerName,
        [Parameter(Mandatory = $true)] [int]$EventID,
        [Parameter(Mandatory = $true)] [datetime]$StartTime
    )

    $filter = @{
        LogName   = "Microsoft-Windows-NTLM/Operational"
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

function Convert-EventToObject {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Eventing.Reader.EventLogRecord]$Event,

        [Parameter(Mandatory = $true)]
        [int]$EventID
    )

    $prop = $Event.Properties
    $count = $prop.Count

    # Schema identique pour 4032 et 4033 sur WS2025 (17 proprietes)
    $accountDomain = if ($count -gt 2) { [string]$prop[2].Value } else { "" }
    $accountMachine = if ($count -gt 3) { [string]$prop[3].Value } else { "" }
    $statusHex = if ($count -gt 15) { ConvertTo-StatusHex -RawValue $prop[15].Value } else { "" }

    return [PSCustomObject]@{
        Timestamp        = $Event.TimeCreated
        EventID          = $EventID
        EventName        = Get-EventName -EventID $EventID
        Level            = $Event.LevelDisplayName          # Information / Avertissement
        AccountName      = if ($count -gt 1)  { $prop[1].Value }  else { "" }
        AccountDomain    = $accountDomain
        AccountMachine   = $accountMachine
        Classification   = Get-AccountClassification -AccountDomain $accountDomain -AccountMachine $accountMachine
        ServerName       = if ($count -gt 4)  { $prop[4].Value }  else { "" }
        ServerIP         = if ($count -gt 6)  { $prop[6].Value }  else { "" }
        NtlmVersion      = if ($count -gt 8)  { $prop[8].Value }  else { "" }
        ServiceBinding   = if ($count -gt 9)  { $prop[9].Value }  else { "" }   # le SPN cible
        TargetMachine    = if ($count -gt 10) { $prop[10].Value } else { "" }
        TargetDomain     = if ($count -gt 11) { $prop[11].Value } else { "" }
        Status           = $statusHex
        Success          = ($statusHex -eq "0x0")
        ServerDC         = $env:COMPUTERNAME
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
    Write-Section "5.0.3 - Audit des événements NTLM (WS2025 v1.0)"
    Write-Host " Serveur          : $ServerName" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " PowerShell       : $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host " Période          : $Days derniers jours" -ForegroundColor Gray
    Write-Host " IDs              : $($EventIDs -join ', ')" -ForegroundColor Gray
    Write-Host " Journal          : Microsoft-Windows-NTLM/Operational" -ForegroundColor Gray
    Write-Host " Dossier export   : $ExportFolder" -ForegroundColor Gray
    Write-Host " Log              : $LogPath" -ForegroundColor Gray
    Write-Host " Version script   : WS2025 v1.0 (complément NTLM)" -ForegroundColor Yellow

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

    Write-Section "Collecte des événements NTLM"
    Write-Host "  Période : du $startTime à $(Get-Date -Format 'dd/MM/yyyy HH:mm')" -ForegroundColor Gray

    $allResults = @{}

    foreach ($eventId in $EventIDs) {
        $eventName = Get-EventName -EventID $eventId
        Write-Host ""
        Write-Host "  ── Event ID $eventId ($eventName) ──" -ForegroundColor Magenta

        try {
            $events = Get-NtlmEvents -ComputerName $ServerName -EventID $eventId -StartTime $startTime

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

        $rawFileName = "NTLM_${eventId}_Raw_${ServerName}_${timestamp}.csv"
        $rawFilePath = Join-Path $ExportFolder $rawFileName
        $data | Export-Csv -Path $rawFilePath -NoTypeInformation -Encoding UTF8
        Write-Step "Export brut ID $eventId : $rawFilePath" "OK"

        $uniqueAccounts = $data | Where-Object { $_.AccountName } |
            Select-Object -ExpandProperty AccountName | Sort-Object -Unique

        $uniqueFileName = "NTLM_${eventId}_Unique_${ServerName}_${timestamp}.csv"
        $uniqueFilePath = Join-Path $ExportFolder $uniqueFileName

        $uniqueExport = $uniqueAccounts | ForEach-Object {
            [PSCustomObject]@{
                EventID      = $eventId
                EventName    = $eventName
                ActiveEntity = $_
                AuditDate    = (Get-Date).ToString("yyyy-MM-dd")
                ServerDC     = $ServerName
            }
        }
        $uniqueExport | Export-Csv -Path $uniqueFilePath -NoTypeInformation -Encoding UTF8
        Write-Step "Export uniques ID $eventId : $uniqueFilePath ($($uniqueAccounts.Count) entités)" "OK"

        $script:Results += [PSCustomObject]@{
            EventID       = $eventId
            EventName     = $eventName
            TotalEvents   = $data.Count
            UniqueUsers   = $uniqueAccounts.Count
            RawFile       = $rawFilePath
            UniqueFile    = $uniqueFilePath
        }
    }

    # --- STATISTIQUES ---
    Write-Section "Statistiques détaillées"

    $allEvents4032 = @($allResults[4032])
    $allEvents4033 = @($allResults[4033])
    $allEventsCombined = @($allEvents4032) + @($allEvents4033)

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
        $uniqueAccountsCount = ($data | Where-Object { $_.AccountName } |
            Select-Object -ExpandProperty AccountName -Unique).Count

        Write-Host ""
        Write-Host "  📊 Statistiques globales :" -ForegroundColor Yellow
        Write-Host "     Total événements     : $($data.Count)" -ForegroundColor Gray
        Write-Host "     Réussites (Status 0x0) : $successCount" -ForegroundColor Green
        Write-Host "     Échecs                  : $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { 'Red' } else { 'Gray' })
        Write-Host "     Comptes uniques         : $uniqueAccountsCount" -ForegroundColor Cyan

        Show-TopList -Data $data -Property "AccountName" `
            -Title "Top $TopCount comptes" -Top $TopCount
        Show-TopList -Data $data -Property "ServiceBinding" `
            -Title "Top $TopCount SPN/services ciblés" -Top $TopCount
        Show-TopList -Data $data -Property "Classification" `
            -Title "Répartition par type de compte" -Top $TopCount
        Show-TopList -Data $data -Property "NtlmVersion" `
            -Title "Versions NTLM" -Top $TopCount

        if ($failureCount -gt 0) {
            Write-Host ""
            Write-Host "  ⚠️  Détail des échecs :" -ForegroundColor Red
            $failures = $data | Where-Object { -not $_.Success } | Select-Object -First 10
            foreach ($f in $failures) {
                Write-Host ("     [{0}] {1}\{2} -> {3} - Status: {4} - SPN: {5}" -f
                    $f.Timestamp.ToString("dd/MM HH:mm"),
                    $f.AccountDomain, $f.AccountName,
                    $f.ServerName,
                    $f.Status,
                    $f.ServiceBinding) -ForegroundColor Red
            }
            if ($failureCount -gt 10) {
                Write-Host "     (... et $($failureCount - 10) autres échecs - voir CSV)" -ForegroundColor DarkGray
            }
        }
    }

    # --- ALERTE SPÉCIFIQUE : comptes locaux sur membres du domaine ---
    Write-Host ""
    Write-Host ("━" * 70) -ForegroundColor DarkMagenta
    Write-Host "  ANALYSE CIBLÉE : comptes locaux / hors domaine" -ForegroundColor Magenta
    Write-Host ("━" * 70) -ForegroundColor DarkMagenta

    $comptesLocaux = @($allEventsCombined | Where-Object { $_.Classification -eq "CompteLocal" })
    $horsDomaine   = @($allEventsCombined | Where-Object { $_.Classification -eq "HorsDomaine" })

    if ($comptesLocaux.Count -gt 0) {
        Write-Host ""
        Write-Host "  ⚠️  $($comptesLocaux.Count) événement(s) avec un COMPTE LOCAL sur un membre du domaine :" -ForegroundColor Red
        Write-Host "     (c'est ce type d'événement qui avait révélé le bug initial de ce projet)" -ForegroundColor DarkGray
        $comptesLocaux | Select-Object -First 10 | ForEach-Object {
            Write-Host ("     [{0}] {1}\{2} -> {3}" -f
                $_.Timestamp.ToString("dd/MM HH:mm"), $_.AccountDomain, $_.AccountName, $_.ServerName) -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Aucun compte local détecté sur un membre du domaine - RAS" -ForegroundColor Green
    }

    if ($horsDomaine.Count -gt 0) {
        Write-Host ""
        Write-Host "  ℹ️  $($horsDomaine.Count) événement(s) depuis un poste HORS DOMAINE (normal, NTLM inévitable) :" -ForegroundColor Cyan
        $horsDomaine | Select-Object -ExpandProperty AccountMachine -Unique | ForEach-Object {
            Write-Host "     - $_" -ForegroundColor DarkGray
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
    Write-Host "  ⚠️  RAPPEL : ACTIVATION DES LOGS D'AUDIT NTLM" -ForegroundColor Yellow
    Write-Host ("─" * 70) -ForegroundColor DarkGray
    Write-Host "  Sur DC03, via gpmc.msc (GPO distincte de l'audit Kerberos) :" -ForegroundColor Cyan
    Write-Host "    Configuration ordinateur → Stratégies → Paramètres Windows" -ForegroundColor Gray
    Write-Host "      → Paramètres de sécurité → Stratégies locales → Options de sécurité" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Activer :" -ForegroundColor Cyan
    Write-Host "    ✅ Sécurité réseau : Restreindre NTLM :" -ForegroundColor Gray
    Write-Host "       Auditer l'authentification NTLM dans ce domaine   → Activer tout" -ForegroundColor Gray
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