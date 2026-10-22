<#
.SYNOPSIS
    Vérifie la configuration MaxEnvelopeSizekb sur les serveurs du PoC.

.DESCRIPTION
    Ce script interroge la configuration WinRM de chaque serveur cible
    et affiche la valeur MaxEnvelopeSizekb actuelle.
    Il met en évidence les serveurs dont la valeur est différente de la
    valeur cible (par défaut 1024 Ko) ou en dessous d'un seuil minimal.

    FONCTIONNALITÉS :
    - Interrogation de tous les serveurs du PoC
    - Affichage de la valeur actuelle et cible
    - Détection des serveurs non conformes
    - Statistiques récapitulatives
    - Support d'un seuil minimal personnalisé
    - Logging complet via Start-Transcript

.PARAMETER Servers
    Liste des serveurs cibles. Par défaut, tous les serveurs du PoC.

.PARAMETER TargetValue
    Valeur cible attendue (en Ko). Défaut : 1024

.PARAMETER MinimumValue
    Valeur minimale acceptable (en Ko). Défaut : 1024
    Les serveurs en dessous de cette valeur sont marqués "NON CONFORME".

.PARAMETER TranscriptPath
    Chemin du fichier de log.
    Défaut : .\Get-WSManMaxEnvelopeSize.log

.EXAMPLE
    # Vérification standard
    .\Get-WSManMaxEnvelopeSize.ps1

.EXAMPLE
    # Vérification avec seuil personnalisé
    .\Get-WSManMaxEnvelopeSize.ps1 -TargetValue 2048 -MinimumValue 1024

.EXAMPLE
    # Vérification de serveurs spécifiques
    .\Get-WSManMaxEnvelopeSize.ps1 -Servers "SQLS01.optimedit.eu", "SQLS02.optimedit.eu"

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : Poste d'administration (ou DC03)
    Dossier : C:\Scripts-Maintenances
#>

[CmdletBinding()]
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
    [int]$TargetValue = 1024,

    [Parameter(Mandatory = $false)]
    [ValidateRange(500, 8192)]
    [int]$MinimumValue = 1024,

    [Parameter(Mandatory = $false)]
    [string]$TranscriptPath = ".\Get-WSManMaxEnvelopeSize.log"
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

function Format-Value {
    <#
    .SYNOPSIS
        Formate une valeur en Ko avec indication en Mo.
    #>
    param([int]$ValueKb)
    $mo = [math]::Round($ValueKb / 1024, 2)
    return "$ValueKb Ko ($mo Mo)"
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "Vérification de MaxEnvelopeSizekb"
    Write-Host " Poste d'exécution : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " Date              : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Valeur cible      : $(Format-Value -ValueKb $TargetValue)" -ForegroundColor Gray
    Write-Host " Valeur minimale   : $(Format-Value -ValueKb $MinimumValue)" -ForegroundColor Gray
    Write-Host " Nombre de serveurs: $($Servers.Count)" -ForegroundColor Gray
    Write-Host " Log               : $TranscriptPath" -ForegroundColor Gray

    Write-Section "Interrogation des serveurs"

    $index = 0
    foreach ($server in $Servers) {
        $index++
        Write-Host ""
        Write-Host "  ── [$index/$($Servers.Count)] $server ──" -ForegroundColor Magenta

        try {
            $result = Invoke-Command -ComputerName $server -ScriptBlock {
                $result = [PSCustomObject]@{
                    Server           = $env:COMPUTERNAME
                    MaxEnvelopeSizekb = $null
                    Error            = $null
                }

                try {
                    $config = Get-WSManInstance -ResourceURI winrm/config -ErrorAction Stop
                    $result.MaxEnvelopeSizekb = [int]$config.MaxEnvelopeSizekb
                } catch {
                    $result.Error = $_.Exception.Message
                }

                return $result
            } -ErrorAction Stop

            if ($result.Error) {
                Write-Step "Erreur : $($result.Error)" "ERROR"
                $script:Results += [PSCustomObject]@{
                    Server            = $server
                    MaxEnvelopeSizekb = $null
                    Status            = "Erreur"
                    Message           = $result.Error
                }
            }
            else {
                $value = $result.MaxEnvelopeSizekb

                # Évaluation du statut
                if ($value -eq $TargetValue) {
                    Write-Step "$(Format-Value -ValueKb $value) - CONFORME (cible atteinte)" "OK"
                    $status = "Conforme"
                }
                elseif ($value -ge $MinimumValue -and $value -lt $TargetValue) {
                    Write-Step "$(Format-Value -ValueKb $value) - ACCEPTABLE (min: $MinimumValue Ko)" "WARN"
                    $status = "Acceptable"
                }
                elseif ($value -gt $TargetValue) {
                    Write-Step "$(Format-Value -ValueKb $value) - SUPÉRIEUR (au-dessus de la cible)" "OK"
                    $status = "Supérieur"
                }
                else {
                    Write-Step "$(Format-Value -ValueKb $value) - NON CONFORME (min requis: $MinimumValue Ko)" "ERROR"
                    $status = "Non conforme"
                }

                $script:Results += [PSCustomObject]@{
                    Server            = $server
                    MaxEnvelopeSizekb = $value
                    Status            = $status
                    Message           = ""
                }
            }

        } catch {
            Write-Step "Erreur de connexion : $($_.Exception.Message)" "ERROR"
            $script:Results += [PSCustomObject]@{
                Server            = $server
                MaxEnvelopeSizekb = $null
                Status            = "Connexion échouée"
                Message           = $_.Exception.Message
            }
        }
    }

    # ============================================================
    # STATISTIQUES
    # ============================================================
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé"

    Write-Host ""
    Write-Host "  Durée totale      : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host "  Valeur cible      : $(Format-Value -ValueKb $TargetValue)" -ForegroundColor Gray
    Write-Host "  Valeur minimale   : $(Format-Value -ValueKb $MinimumValue)" -ForegroundColor Gray
    Write-Host ""

    $conformes    = @($script:Results | Where-Object { $_.Status -in @("Conforme", "Supérieur") })
    $acceptables  = @($script:Results | Where-Object { $_.Status -eq "Acceptable" })
    $nonConformes = @($script:Results | Where-Object { $_.Status -eq "Non conforme" })
    $erreurs      = @($script:Results | Where-Object { $_.Status -in @("Erreur", "Connexion échouée") })

    Write-Host "  Serveurs conformes     : $($conformes.Count)" -ForegroundColor Green
    Write-Host "  Serveurs acceptables   : $($acceptables.Count)" -ForegroundColor Yellow
    Write-Host "  Serveurs non conformes : $($nonConformes.Count)" -ForegroundColor $(if ($nonConformes.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  Serveurs en erreur     : $($erreurs.Count)" -ForegroundColor $(if ($erreurs.Count -gt 0) { 'Red' } else { 'Gray' })
    Write-Host ""

    # ============================================================
    # TABLEAU DÉTAILLÉ
    # ============================================================
    Write-Host "  Détail par serveur :" -ForegroundColor Cyan
    $script:Results | Format-Table Server, MaxEnvelopeSizekb, Status, Message -AutoSize

    # ============================================================
    # SERVEURS NON CONFORMES
    # ============================================================
    if ($nonConformes.Count -gt 0) {
        Write-Host "  ⚠️  Serveurs NON CONFORMES (< $MinimumValue Ko) :" -ForegroundColor Red
        $nonConformes | ForEach-Object {
            Write-Host "    - $($_.Server) : $($_.MaxEnvelopeSizekb) Ko" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  Action recommandée :" -ForegroundColor Yellow
        Write-Host "    .\Set-WSManMaxEnvelopeSize.ps1 -MaxEnvelopeSizekb $TargetValue" -ForegroundColor Gray
        Write-Host ""
    }

    # ============================================================
    # SERVEURS ACCEPTABLES
    # ============================================================
    if ($acceptables.Count -gt 0) {
        Write-Host "  ℹ️  Serveurs acceptables (entre $MinimumValue et $TargetValue Ko) :" -ForegroundColor Yellow
        $acceptables | ForEach-Object {
            Write-Host "    - $($_.Server) : $($_.MaxEnvelopeSizekb) Ko" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    # ============================================================
    # SERVEURS EN ERREUR
    # ============================================================
    if ($erreurs.Count -gt 0) {
        Write-Host "  ⚠️  Serveurs en erreur :" -ForegroundColor Red
        $erreurs | ForEach-Object {
            Write-Host "    - $($_.Server) : $($_.Status)" -ForegroundColor Red
            Write-Host "      $($_.Message)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # ============================================================
    # VERDICT FINAL
    # ============================================================
    Write-Host ("─" * 75) -ForegroundColor DarkGray
    Write-Host "  VERDICT FINAL" -ForegroundColor Yellow
    Write-Host ("─" * 75) -ForegroundColor DarkGray

    if ($nonConformes.Count -eq 0 -and $erreurs.Count -eq 0) {
        Write-Host "  ✅ Tous les serveurs sont conformes ou acceptables" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Valeur minimale observée : $(($script:Results | Where-Object { $_.MaxEnvelopeSizekb } | Measure-Object -Property MaxEnvelopeSizekb -Minimum).Minimum) Ko" -ForegroundColor Gray
        Write-Host "  Valeur maximale observée : $(($script:Results | Where-Object { $_.MaxEnvelopeSizekb } | Measure-Object -Property MaxEnvelopeSizekb -Maximum).Maximum) Ko" -ForegroundColor Gray
    }
    else {
        Write-Host "  ❌ Des serveurs nécessitent une action corrective" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Lancer :" -ForegroundColor Yellow
        Write-Host "    .\Set-WSManMaxEnvelopeSize.ps1 -MaxEnvelopeSizekb $TargetValue" -ForegroundColor Gray
    }

    Write-Host ""

    # Code de sortie (commenté pour garder la console ouverte)
    # if ($nonConformes.Count -gt 0 -or $erreurs.Count -gt 0) {
    #     exit 1
    # }
    
    # Alternative : utiliser $global:LASTEXITCODE sans quitter
    if ($nonConformes.Count -gt 0 -or $erreurs.Count -gt 0) {
        $global:LASTEXITCODE = 1
    } else {
        $global:LASTEXITCODE = 0
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