<#
    8.5.0.configure_iis_sessionstate_Local.ps1
    Objet   : Configurer le Session State SQL Server sur les 13 sites du serveur IIS local.
    Noeud   : À exécuter LOCALEMENT sur chaque serveur backend (ex: via Ansible).
    Note    : Crée un backup .bak du web.config avant modification.
              Prend en charge le mode -WhatIf.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SqlListener = "SQL-AG-LSTNR.optimedit.eu",
    [string]$WebsiteName = "*" # Par défaut "*" = tous les sites. On peut cibler un seul site.
)

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "  [ECHEC] $Message" -ForegroundColor Red }

Write-Step "Configuration du Session State sur le serveur local : $env:COMPUTERNAME"

# Vérification du module IIS
if (-not (Get-Module -Name WebAdministration -ErrorAction SilentlyContinue)) {
    Import-Module WebAdministration -ErrorAction Stop
}

# Récupération des sites (filtrés si $WebsiteName est spécifié)
$sites = Get-Website | Where-Object { $WebsiteName -eq "*" -or $_.Name -eq $WebsiteName }

if (-not $sites) {
    Write-Fail "Aucun site trouvé correspondant au filtre : $WebsiteName"
    exit 1
}

$results = @()

foreach ($site in $sites) {
    $webConfigPath = Join-Path $site.PhysicalPath "web.config"
    
    try {
        # 1. Charger le XML existant ou en créer un nouveau
        if (Test-Path $webConfigPath) {
            if (-not $WhatIfPreference) {
                # Création d'une sauvegarde de sécurité (.bak)
                Copy-Item -Path $webConfigPath -Destination "$webConfigPath.bak" -Force
            }
            [xml]$xml = Get-Content -Path $webConfigPath -ErrorAction Stop
        } else {
            [xml]$xml = "<configuration></configuration>"
        }

        # 2. S'assurer que le noeud <configuration> existe
        if (-not $xml.configuration) {
            $configNode = $xml.CreateElement("configuration")
            $xml.AppendChild($configNode) | Out-Null
        }

        # 3. Trouver ou créer le noeud <system.web>
        $systemWebNode = $xml.SelectSingleNode("/configuration/system.web")
        if (-not $systemWebNode) {
            $systemWebNode = $xml.CreateElement("system.web")
            $xml.configuration.AppendChild($systemWebNode) | Out-Null
        }

        # 4. Supprimer un éventuel ancien noeud sessionState pour éviter les doublons
        $oldSession = $systemWebNode.SelectSingleNode("sessionState")
        if ($oldSession) {
            if (-not $WhatIfPreference) {
                $systemWebNode.RemoveChild($oldSession) | Out-Null
            }
        }

        # 5. Créer et insérer le nouveau noeud sessionState
        $newSessionNode = $xml.CreateElement("sessionState")
        $newSessionNode.SetAttribute("mode", "SQLServer")
        $newSessionNode.SetAttribute("cookieless", "false")
        $newSessionNode.SetAttribute("timeout", "20")
        
        $connString = "Data Source=$SqlListener;Initial Catalog=ASPState;Integrated Security=True;Application Name=SessionState"
        $newSessionNode.SetAttribute("sqlConnectionString", $connString)
        
        # 6. Sauvegarder le fichier
        if (-not $WhatIfPreference) {
            $systemWebNode.AppendChild($newSessionNode) | Out-Null
            $xml.Save($webConfigPath)
        }
        
        $results += [PSCustomObject]@{
            Server = $env:COMPUTERNAME
            Site   = $site.Name
            Status = if ($WhatIfPreference) { "Simulé (WhatIf)" } else { "OK (Configuré + Backup)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            Server = $env:COMPUTERNAME
            Site   = $site.Name
            Status = "Erreur : $($_.Exception.Message)"
        }
    }
}

# ============================================================
# AFFICHAGE DU RESULTAT
# ============================================================
Write-Step "Résultat pour le serveur $env:COMPUTERNAME"
$results | Select-Object Site, Status | Format-Table -AutoSize

$errorCount = ($results | Where-Object { $_.Status -like "*Erreur*" }).Count
$okCount = ($results | Where-Object { $_.Status -like "*OK*" -or $_.Status -like "*Simulé*" }).Count

if ($errorCount -eq 0) {
    Write-Ok "$okCount site(s) traité(s) avec succès sur ce serveur."
} else {
    Write-Fail "$errorCount site(s) ont rencontré une erreur."
}

Write-Host "`n  [OK] Traitement local terminé." -ForegroundColor Green