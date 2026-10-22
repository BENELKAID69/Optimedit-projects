<#
.SYNOPSIS
    Verifie et cree les SPN pour SQL Server (noeuds + Listener Always On).

.DESCRIPTION
    Ce script verifie l'existence des SPN requis pour SQL Server 2022
    sur le compte de service, et les cree UNIQUEMENT s'ils sont absents.
    Couvre a la fois les noeuds physiques (SQLS01, SQLS02) et le/les
    Listener(s) Always On (SQL-AG-LSTNR), car tout client se connectant
    via le nom du Listener negocie Kerberos contre ce SPN specifique -
    sans lui, la connexion retombe silencieusement en NTLM.
    Supporte -WhatIf pour la previsualisation.

.EXAMPLE
    .\5.0.0.manage_sql_spn.ps1 -WhatIf
    .\5.0.0.manage_sql_spn.ps1
    .\5.0.0.manage_sql_spn.ps1 -ListenerNames "SQL-AG-LSTNR","SQL-AG-LSTNR2"

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.1 (ajout du support Listener Always On)
    Noeud   : DC03 (ou poste admin avec RSAT)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ServiceAccount = "optimedit\SVC_SQL_Engine",
    [string[]]$Nodes = @("SQLS01", "SQLS02"),

    # --- Listener(s) Always On : meme compte de service que les noeuds,
    #     donc un seul enregistrement suffit quel que soit le noeud primaire ---
    [switch]$IncludeListener = $true,
    [string[]]$ListenerNames = @("SQL-AG-LSTNR"),

    [string]$Domain = "optimedit.eu",
    [int]$Port = 1433,
    [switch]$IncludeShortNames = $true,
    [string]$LogPath = ".\5.0.0.manage_sql_spn.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:Results = @()

try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de demarrer la transcription : $($_.Exception.Message)"
}

# ============================================================
# FONCTIONS
# ============================================================

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
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

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SetSpnAvailable {
    try {
        $null = Get-Command setspn.exe -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-SpnOwner {
    param([string]$Spn)
    try {
        $output = & setspn.exe -Q $Spn 2>&1
        $fullText = ($output -join "`n")

        # Détection explicite d'absence
        if ($fullText -match "Aucun SPN identique|No matching SPN|not found|introuvable") {
            return $null
        }

        # Chercher une ligne "CN=..."
        $cnMatch = $output | Where-Object { $_ -match "^CN=" } | Select-Object -First 1
        if ($cnMatch -and $cnMatch -match "CN=([^,]+)") {
            return $Matches[1]
        }

        return $null
    } catch {
        return $null
    }
}

function Get-SpnForAccount {
    param([string]$Account)
    try {
        $output = & setspn.exe -L $Account 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @()
        }
        $spns = $output -split "`r?`n" | Where-Object {
            $_ -match "^\s+MSSQLSvc/"
        } | ForEach-Object { $_.Trim() }
        return @($spns)
    } catch {
        return @()
    }
}

function Add-Spn {
    param([string]$Spn, [string]$Account)
    try {
        $output = & setspn.exe -S $Spn $Account 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @{ Success = $true; Message = "SPN creee" }
        }
        return @{ Success = $false; Message = ($output -join " ") }
    } catch {
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}

function Get-SpnVariants {
    <#
        Genere les variantes de SPN (FQDN/court, avec/sans port) pour un nom
        donne (noeud OU listener) - meme logique pour les deux, car un
        Listener Always On est, du point de vue Kerberos, un nom de service
        comme un autre.
    #>
    param(
        [string]$Name,
        [string]$Domain,
        [int]$Port,
        [switch]$IncludeShortNames,
        [string]$LabelPrefix = ""
    )
    $variants = @()
    $variants += [PSCustomObject]@{ Spn = "MSSQLSvc/$Name.$Domain`:$Port"; Description = "$LabelPrefix FQDN avec port" }
    $variants += [PSCustomObject]@{ Spn = "MSSQLSvc/$Name.$Domain";        Description = "$LabelPrefix FQDN sans port" }
    if ($IncludeShortNames) {
        $variants += [PSCustomObject]@{ Spn = "MSSQLSvc/$Name`:$Port"; Description = "$LabelPrefix Nom court avec port" }
        $variants += [PSCustomObject]@{ Spn = "MSSQLSvc/$Name";        Description = "$LabelPrefix Nom court sans port" }
    }
    return $variants
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "5.0.0 - Gestion des SPN SQL Server (noeuds + Listener)"
    Write-Host " Serveur           : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " Date              : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " PowerShell        : $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host " Mode              : $(if ($WhatIfPreference) { 'WhatIf (previsualisation)' } else { 'Execution reelle' })" -ForegroundColor $(if ($WhatIfPreference) { 'Yellow' } else { 'Green' })
    Write-Host " Compte de service : $ServiceAccount" -ForegroundColor Gray
    Write-Host " Noeuds            : $($Nodes -join ', ')" -ForegroundColor Gray
    Write-Host " Listener(s)       : $(if ($IncludeListener) { $ListenerNames -join ', ' } else { '(desactive)' })" -ForegroundColor Gray
    Write-Host " Domaine           : $Domain" -ForegroundColor Gray
    Write-Host " Port              : $Port" -ForegroundColor Gray
    Write-Host " Log               : $LogPath" -ForegroundColor Gray

    # --- PRE-VOL 1 : Privileges admin ---
    Write-Section "Pre-vol 1/3 : Verification des privileges"
    if (-not (Test-IsAdministrator)) {
        throw "Ce script doit etre execute en tant qu'administrateur."
    }
    Write-Step "Privileges administrateur confirmes" "OK"

    # --- PRE-VOL 2 : setspn.exe ---
    Write-Section "Pre-vol 2/3 : Verification de setspn.exe"
    if (-not (Test-SetSpnAvailable)) {
        throw "setspn.exe n'est pas disponible. Installez RSAT-AD-Tools ou executez sur DC03."
    }
    Write-Step "setspn.exe disponible" "OK"

    # --- PRE-VOL 3 : Compte de service ---
    Write-Section "Pre-vol 3/3 : Verification du compte de service"
    $existingSpns = Get-SpnForAccount -Account $ServiceAccount
    Write-Step "Compte $ServiceAccount accessible" "OK"
    Write-Step "SPN MSSQLSvc actuellement enregistrees : $($existingSpns.Count)" "INFO"
    if ($existingSpns.Count -gt 0) {
        $existingSpns | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    }

    # --- CONSTRUCTION DE LA LISTE ---
    Write-Section "Construction de la liste des SPN"
    $spnsToManage = @()

    # Noeuds physiques
    foreach ($node in $Nodes) {
        $spnsToManage += Get-SpnVariants -Name $node -Domain $Domain -Port $Port `
            -IncludeShortNames:$IncludeShortNames -LabelPrefix "Noeud $node -"
    }

    # Listener(s) Always On - meme compte de service que les noeuds (SVC_SQL_Engine),
    # donc un seul enregistrement suffit : il reste valide quel que soit le noeud
    # actuellement primaire, puisque les deux instances tournent sous cette identite.
    if ($IncludeListener) {
        foreach ($listener in $ListenerNames) {
            $spnsToManage += Get-SpnVariants -Name $listener -Domain $Domain -Port $Port `
                -IncludeShortNames:$IncludeShortNames -LabelPrefix "Listener $listener -"
        }
    }

    Write-Step "$($spnsToManage.Count) SPN a verifier ($($Nodes.Count) noeud(s) + $(if ($IncludeListener) { $ListenerNames.Count } else { 0 }) listener(s))" "INFO"

    # --- VERIFICATION ET CREATION ---
    Write-Section "Verification et creation"
    $createdCount = 0
    $existingCount = 0
    $conflictCount = 0
    $failedCount = 0

    foreach ($spnItem in $spnsToManage) {
        $spn = $spnItem.Spn
        $owner = Get-SpnOwner -Spn $spn

        if ($null -eq $owner) {
            # SPN absente
            if ($WhatIfPreference) {
                Write-Step "$spn : ABSENTE -> serait creee sur $ServiceAccount" "SKIP"
                $script:Results += [PSCustomObject]@{ Spn = $spn; Status = "Absente (WhatIf)"; Owner = ""; Type = $spnItem.Description }
            } else {
                Write-Step "$spn : ABSENTE -> creation..." "INFO"
                if ($PSCmdlet.ShouldProcess($spn, "Ajouter la SPN a $ServiceAccount")) {
                    $result = Add-Spn -Spn $spn -Account $ServiceAccount
                    if ($result.Success) {
                        Write-Step "$spn : creee sur $ServiceAccount" "OK"
                        $createdCount++
                        $script:Results += [PSCustomObject]@{ Spn = $spn; Status = "Creee"; Owner = $ServiceAccount; Type = $spnItem.Description }
                    } else {
                        Write-Step "$spn : ECHEC -> $($result.Message)" "ERROR"
                        $failedCount++
                        $script:Errors += "Echec de creation : $spn"
                        $script:Results += [PSCustomObject]@{ Spn = $spn; Status = "Echec"; Owner = ""; Type = $spnItem.Description }
                    }
                }
            }
        }
        elseif ($owner -like "*$($ServiceAccount.Split('\')[-1])*") {
            # SPN deja sur le bon compte
            Write-Step "$spn : deja presente sur $ServiceAccount" "OK"
            $existingCount++
            $script:Results += [PSCustomObject]@{ Spn = $spn; Status = "Existante"; Owner = $owner; Type = $spnItem.Description }
        }
        else {
            # Conflit
            Write-Step "$spn : CONFLIT -> deja sur '$owner'" "WARN"
            $conflictCount++
            $script:Warnings += "Conflit : $spn sur '$owner' (attendu : $ServiceAccount)"
            $script:Results += [PSCustomObject]@{ Spn = $spn; Status = "Conflit"; Owner = $owner; Type = $spnItem.Description }
            Write-Host ""
            Write-Host "         Resolution suggeree :" -ForegroundColor Yellow
            Write-Host "           setspn -D $spn $owner" -ForegroundColor Gray
            Write-Host "           setspn -S $spn $ServiceAccount" -ForegroundColor Gray
            Write-Host ""
        }
    }

    # --- VERIFICATION POST-EXECUTION ---
    Write-Section "Verification post-execution"
    if (-not $WhatIfPreference) {
        $finalSpns = Get-SpnForAccount -Account $ServiceAccount
        $mssqlSpns = @($finalSpns | Where-Object { $_ -match "MSSQLSvc/" })
        Write-Step "SPN MSSQLSvc sur $ServiceAccount : $($mssqlSpns.Count)" "INFO"
        $mssqlSpns | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }

        $missing = @()
        foreach ($item in $spnsToManage) {
            if ($mssqlSpns -notcontains $item.Spn) {
                $missing += $item.Spn
            }
        }
        if ($missing.Count -eq 0) {
            Write-Step "Toutes les SPN attendues sont presentes (noeuds + listener)" "OK"
        } else {
            Write-Step "$($missing.Count) SPN manquantes :" "WARN"
            $missing | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
        }

        # Rappel specifique Listener : verifie qu'au moins un SPN Listener est present
        if ($IncludeListener) {
            $listenerSpnsOk = @($mssqlSpns | Where-Object { $_ -match [regex]::Escape($ListenerNames[0]) })
            if ($listenerSpnsOk.Count -eq 0) {
                Write-Step "ATTENTION : aucun SPN detecte pour le Listener $($ListenerNames -join ', ') - les connexions via ce nom risquent de retomber en NTLM" "WARN"
            } else {
                Write-Step "SPN Listener confirmes ($($listenerSpnsOk.Count))" "OK"
            }
        }
    } else {
        Write-Step "Verification post-execution ignoree (mode WhatIf)" "SKIP"
    }

    # --- RESUME FINAL ---
    $duration = (Get-Date) - $StartTime
    Write-Section "Resume"
    Write-Host ""
    Write-Host "  Duree              : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host "  Mode               : $(if ($WhatIfPreference) { 'WhatIf (aucune modif)' } else { 'Reel' })" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  SPN creees         : $createdCount" -ForegroundColor Green
    Write-Host "  SPN existantes     : $existingCount" -ForegroundColor Cyan
    Write-Host "  SPN en conflit     : $conflictCount" -ForegroundColor $(if ($conflictCount -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host "  SPN echouees       : $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { 'Red' } else { 'Gray' })
    Write-Host ""

    if ($script:Results.Count -gt 0) {
        Write-Host "  Detail par SPN :" -ForegroundColor Cyan
        $script:Results | Format-Table Spn, Status, Owner, Type -AutoSize
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
    }

    Write-Host "  Verification manuelle :" -ForegroundColor Yellow
    Write-Host "    setspn -L $ServiceAccount" -ForegroundColor Gray
    Write-Host ""

    if ($script:Errors.Count -gt 0) {
        exit 1
    }
}
catch {
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
}
finally {
    try {
        Stop-Transcript | Out-Null
    } catch {
        # Ignorer
    }
    Write-Host "Log complet : $LogPath" -ForegroundColor DarkGray
}