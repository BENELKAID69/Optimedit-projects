<#
    8.5.0.configure_iis_sessionstate_WinRm.ps1
    Objet   : Configurer le Session State SQL Server sur les 13 sites des 6 backends IIS
    Noeud   : Exécution depuis DC03 (ou poste d'admin) via WinRM HTTPS
    Note    : Crée un backup .bak du web.config avant modification.
              Prend en charge le mode -WhatIf pour simuler sans modifier.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Servers = @(
        "OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", 
        "OPT-IIS-04.optimedit.eu", "OPT-IIS-05.optimedit.eu", "OPT-IIS-06.optimedit.eu"
    ),
    [string]$SqlListener = "SQL-AG-LSTNR.optimedit.eu"
)

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "  [ECHEC] $Message" -ForegroundColor Red }

Write-Step "Configuration du Session State sur $($Servers.Count) backends"

# ============================================================
# SCRIPTBLOCK : Exécuté à distance sur chaque serveur IIS backend
# ============================================================
$ScriptBlock = {
    param($SqlListener, $WhatIf)

    Import-Module WebAdministration -ErrorAction Stop
    $sites = Get-Website
    $results = @()

    foreach ($site in $sites) {
        $webConfigPath = Join-Path $site.PhysicalPath "web.config"
        
        try {
            # 1. Charger le XML existant ou en créer un nouveau
            if (Test-Path $webConfigPath) {
                if (-not $WhatIf) {
                    # Création d'une sauvegarde de sécurité (.bak)
                    Copy-Item -Path $webConfigPath -Destination "$webConfigPath.bak" -Force
                }
                [xml]$xml = Get-Content -Path $webConfigPath -ErrorAction Stop
            } else {
                [xml]$xml = "<configuration></configuration>"
            }

            # 2. S'assurer que le nœud <configuration> existe
            if (-not $xml.configuration) {
                $configNode = $xml.CreateElement("configuration")
                $xml.AppendChild($configNode) | Out-Null
            }

            # 3. Trouver ou créer le nœud <system.web>
            $systemWebNode = $xml.SelectSingleNode("/configuration/system.web")
            if (-not $systemWebNode) {
                $systemWebNode = $xml.CreateElement("system.web")
                $xml.configuration.AppendChild($systemWebNode) | Out-Null
            }

            # 4. Supprimer un éventuel ancien nœud sessionState
            $oldSession = $systemWebNode.SelectSingleNode("sessionState")
            if ($oldSession) {
                if (-not $WhatIf) {
                    $systemWebNode.RemoveChild($oldSession) | Out-Null
                }
            }

            # 5. Créer le nouveau nœud sessionState
            $newSessionNode = $xml.CreateElement("sessionState")
            $newSessionNode.SetAttribute("mode", "SQLServer")
            $newSessionNode.SetAttribute("cookieless", "false")
            $newSessionNode.SetAttribute("timeout", "20")
            
            $connString = "Data Source=$SqlListener;Initial Catalog=ASPState;Integrated Security=True;Application Name=SessionState"
            $newSessionNode.SetAttribute("sqlConnectionString", $connString)
            
            if (-not $WhatIf) {
                $systemWebNode.AppendChild($newSessionNode) | Out-Null
                $xml.Save($webConfigPath)
            }
            
            $results += [PSCustomObject]@{
                Server = $env:COMPUTERNAME
                Site   = $site.Name
                Status = if ($WhatIf) { "Simulé (WhatIf)" } else { "OK (Configuré + Backup)" }
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
    return $results
}

# ============================================================
# EXECUTION
# ============================================================
if ($PSCmdlet.ShouldProcess("Les 6 serveurs backends", "Configurer les 78 fichiers web.config")) {
    try {
        $allResults = Invoke-Command -ComputerName $Servers -UseSSL -ScriptBlock $ScriptBlock -ArgumentList $SqlListener, $WhatIfPreference -ErrorAction Stop
        
        Write-Step "Résultat par serveur et par site"
        $allResults | Select-Object Server, Site, Status | Sort-Object Server, Site | Format-Table -AutoSize
        
        $errorCount = ($allResults | Where-Object { $_.Status -like "*Erreur*" }).Count
        $okCount = ($allResults | Where-Object { $_.Status -like "*OK*" -or $_.Status -like "*Simulé*" }).Count
        
        if ($errorCount -eq 0) {
            Write-Ok "$okCount sites traités avec succès."
        } else {
            Write-Fail "$errorCount site(s) ont rencontré une erreur."
        }
    }
    catch {
        Write-Fail "Erreur critique lors de l'exécution distante : $($_.Exception.Message)"
        exit 1
    }
}

Write-Host "`n  [OK] Traitement terminé." -ForegroundColor Green