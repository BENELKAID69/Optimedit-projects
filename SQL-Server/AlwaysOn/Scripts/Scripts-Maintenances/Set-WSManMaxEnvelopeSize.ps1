<#
.SYNOPSIS
    Configure MaxEnvelopeSizekb sur les serveurs du PoC.

.DESCRIPTION
    Ce script configure la valeur MaxEnvelopeSizekb du service WinRM
    sur l'ensemble des serveurs du PoC (SQL, FS, RP, IIS).
    Cela corrige les erreurs "WS-Man - Taille d'enveloppe maximale" 
    observées dans le Gestionnaire de serveur ou lors d'Invoke-Command.

    ⚠️ La valeur 1024 (1 Mo) est suffisante pour la majorité des cas.
    Elle peut être augmentée à 2048 ou 4096 si nécessaire.

.PARAMETER Servers
    Liste des serveurs cibles. Par défaut, tous les serveurs du PoC.

.PARAMETER MaxEnvelopeSizekb
    Taille maximale de l'enveloppe en Ko. Défaut : 1024

.PARAMETER RestartWinRM
    Redémarre le service WinRM après modification.

.PARAMETER WhatIf
    Prévisualise sans modifier.

.PARAMETER TranscriptPath
    Chemin du fichier de log.
    Défaut : .\Set-WSManMaxEnvelopeSize.log

.EXAMPLE
    # Exécution standard (1024 Ko, sans redémarrage WinRM)
    .\Set-WSManMaxEnvelopeSize.ps1

.EXAMPLE
    # Avec redémarrage du service WinRM
    .\Set-WSManMaxEnvelopeSize.ps1 -RestartWinRM

.EXAMPLE
    # Valeur personnalisée (2048 Ko)
    .\Set-WSManMaxEnvelopeSize.ps1 -MaxEnvelopeSizekb 2048

.EXAMPLE
    # Prévisualisation
    .\Set-WSManMaxEnvelopeSize.ps1 -WhatIf

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : Poste d'administration (ou DC03)
    Dossier : C:\Scripts-Maintenances
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Servers = @(
        "SQLS01.optimedit.eu",
        "SQLS02.optimedit.eu",
        "OPT-FS03.optimedit.eu",
        "OPT-RP-01.optimedit.eu",
        "OPT-IIS-01.optimedit.eu",
        "OPT-IIS-02.optimedit.eu",
        "OPT-IIS-03.optimedit.eu",
        "OPT-IIS-04.optimedit.eu",
        "OPT-IIS-05.optimedit.eu",
        "OPT-IIS-06.optimedit.eu"
    ),

    [Parameter(Mandatory = $false)]
    [ValidateRange(500, 8192)]
    [int]$MaxEnvelopeSizekb = 1024,

    [Parameter(Mandatory = $false)]
    [switch]$RestartWinRM,

    [Parameter(Mandatory = $false)]
    [string]$TranscriptPath = ".\Set-WSManMaxEnvelopeSize.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Continue"
$script:StartTime = Get-Date
$script:Results = @()

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
    Write-Host ("=" * 75) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 75) -ForegroundColor DarkCyan
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
    Write-Section "Configuration de MaxEnvelopeSizekb ($MaxEnvelopeSizekb Ko)"
    Write-Host " Poste d'exécution : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " Date              : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode              : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Valeur cible      : $MaxEnvelopeSizekb Ko ($([math]::Round($MaxEnvelopeSizekb * 1024)) octets)" -ForegroundColor Gray
    Write-Host " Redémarrer WinRM  : $(if ($RestartWinRM) { 'OUI' } else { 'NON' })" -ForegroundColor Gray
    Write-Host " Nombre de serveurs: $($Servers.Count)" -ForegroundColor Gray
    Write-Host " Log               : $TranscriptPath" -ForegroundColor Gray

    Write-Section "Liste des serveurs cibles"

    foreach ($server in $Servers) {
        Write-Host "  - $server" -ForegroundColor Gray
    }

    Write-Section "Configuration"

    $index = 0
    foreach ($server in $Servers) {
        $index++
        Write-Host ""
        Write-Host "  ── [$index/$($Servers.Count)] $server ──" -ForegroundColor Magenta

        try {
            $result = Invoke-Command -ComputerName $server -ScriptBlock {
                param($targetValue, $doRestart)

                $result = [PSCustomObject]@{
                    Server       = $env:COMPUTERNAME
                    BeforeValue  = $null
                    AfterValue   = $null
                    Changed      = $false
                    WinRMRestart = $false
                    Error        = $null
                }

                try {
                    # Valeur avant
                    $currentConfig = Get-WSManInstance -ResourceURI winrm/config -ErrorAction Stop
                    $result.BeforeValue = [int]$currentConfig.MaxEnvelopeSizekb

                    # Modification si nécessaire
                    if ($result.BeforeValue -ne $targetValue) {
                        Set-WSManInstance -ResourceURI winrm/config `
                            -ValueSet @{MaxEnvelopeSizekb = "$targetValue"} `
                            -ErrorAction Stop

                        # Valeur après
                        $newConfig = Get-WSManInstance -ResourceURI winrm/config -ErrorAction Stop
                        $result.AfterValue = [int]$newConfig.MaxEnvelopeSizekb
                        $result.Changed = $true

                        # Redémarrage WinRM si demandé
                        if ($doRestart) {
                            Restart-Service WinRM -Force -ErrorAction Stop
                            Start-Sleep -Seconds 3
                            $result.WinRMRestart = $true
                        }
                    } else {
                        $result.AfterValue = $result.BeforeValue
                    }
                } catch {
                    $result.Error = $_.Exception.Message
                }

                return $result
            } -ArgumentList $MaxEnvelopeSizekb, $RestartWinRM.IsPresent -ErrorAction Stop

            if ($result.Error) {
                Write-Step "Erreur : $($result.Error)" "ERROR"
                $script:Results += [PSCustomObject]@{
                    Server      = $server
                    BeforeValue = $result.BeforeValue
                    AfterValue  = $result.AfterValue
                    Changed     = $false
                    Status      = "Erreur"
                    Message     = $result.Error
                }
            }
            elseif ($result.Changed) {
                Write-Step "Modifié : $($result.BeforeValue) Ko → $($result.AfterValue) Ko" "OK"
                if ($result.WinRMRestart) {
                    Write-Step "Service WinRM redémarré" "OK"
                }
                $script:Results += [PSCustomObject]@{
                    Server      = $server
                    BeforeValue = $result.BeforeValue
                    AfterValue  = $result.AfterValue
                    Changed     = $true
                    Status      = "Modifié"
                    Message     = ""
                }
            }
            else {
                Write-Step "Déjà configuré : $($result.BeforeValue) Ko" "OK"
                $script:Results += [PSCustomObject]@{
                    Server      = $server
                    BeforeValue = $result.BeforeValue
                    AfterValue  = $result.AfterValue
                    Changed     = $false
                    Status      = "Déjà OK"
                    Message     = ""
                }
            }

        } catch {
            Write-Step "Erreur de connexion : $($_.Exception.Message)" "ERROR"
            $script:Results += [PSCustomObject]@{
                Server      = $server
                BeforeValue = $null
                AfterValue  = $null
                Changed     = $false
                Status      = "Connexion échouée"
                Message     = $_.Exception.Message
            }
        }
    }

    # ============================================================
    # RÉSUMÉ
    # ============================================================
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"

    Write-Host ""
    Write-Host "  Durée totale     : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host "  Valeur cible     : $MaxEnvelopeSizekb Ko" -ForegroundColor Gray
    Write-Host ""

    # Statistiques
    $modified = @($script:Results | Where-Object { $_.Status -eq "Modifié" })
    $already  = @($script:Results | Where-Object { $_.Status -eq "Déjà OK" })
    $errors   = @($script:Results | Where-Object { $_.Status -notin @("Modifié", "Déjà OK") })

    Write-Host "  Serveurs modifiés    : $($modified.Count)" -ForegroundColor Green
    Write-Host "  Serveurs déjà OK     : $($already.Count)" -ForegroundColor Cyan
    Write-Host "  Serveurs en erreur   : $($errors.Count)" -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host ""

    # Tableau détaillé
    Write-Host "  Détail par serveur :" -ForegroundColor Cyan
    $script:Results | Format-Table Server, BeforeValue, AfterValue, Status, Message -AutoSize

    # Vérification finale
    if ($errors.Count -gt 0) {
        Write-Host "  ⚠️  Certains serveurs n'ont pas pu être configurés :" -ForegroundColor Yellow
        $errors | ForEach-Object {
            Write-Host "    - $($_.Server) : $($_.Status) - $($_.Message)" -ForegroundColor Yellow
        }
        Write-Host ""
    } else {
        Write-Host "  ✅ Tous les serveurs sont configurés avec MaxEnvelopeSizekb = $MaxEnvelopeSizekb Ko" -ForegroundColor Green
        Write-Host ""
    }

    Write-Host "  Prochaine étape : actualiser le Gestionnaire de serveur (F5)" -ForegroundColor Yellow
    Write-Host ""

    # Code de sortie
    if ($errors.Count -gt 0) {
        exit 1
    }

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  Message : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Ligne   : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log complet : $TranscriptPath" -ForegroundColor DarkGray
}