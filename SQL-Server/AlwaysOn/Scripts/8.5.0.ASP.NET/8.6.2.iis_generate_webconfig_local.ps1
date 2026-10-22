<#
    8.6.2.iis_generate_webconfig_local.ps1
    Objet   : Générer le web.config (Session State) sur les 13 sites des 6 backends IIS
    Noeud   : Exécution depuis DC03 ou poste admin (via WinRM HTTPS)
    Note    : Alternative au playbook Ansible 06.02. Supporte -WhatIf.
              Crée une sauvegarde .bak du web.config existant.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Servers = @(
        "OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", 
        "OPT-IIS-04.optimedit.eu", "OPT-IIS-05.optimedit.eu", "OPT-IIS-06.optimedit.eu"
    ),
    [string]$SqlListener = "SQL-AG-LSTNR.optimedit.eu",
    [string]$AspStateDb = "ASPState"
)

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "  [ECHEC] $Message" -ForegroundColor Red }

Write-Step "Génération des web.config sur $($Servers.Count) backends"

$ScriptBlock = {
    param($SqlListener, $AspStateDb, $WhatIf)

    Import-Module WebAdministration -ErrorAction Stop
    $sites = Get-Website
    $results = @()

    # Contenu XML complet à générer
    $xmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <system.webServer>
        <security>
            <authentication>
                <anonymousAuthentication userName="" />
            </authentication>
        </security>
    </system.webServer>
    <system.web>
        <customErrors mode="Off" />
        <sessionState mode="SQLServer" 
                      cookieless="false" 
                      timeout="20" 
                      allowCustomSqlDatabase="true"
                      sqlConnectionString="Data Source=$SqlListener;Initial Catalog=$AspStateDb;Integrated Security=True;Application Name=SessionState" />
    </system.web>
</configuration>
"@

    foreach ($site in $sites) {
        $webConfigPath = Join-Path $site.PhysicalPath "web.config"
        
        try {
            if (-not $WhatIf) {
                # Sauvegarde de l'ancien fichier
                if (Test-Path $webConfigPath) {
                    Copy-Item -Path $webConfigPath -Destination "$webConfigPath.bak" -Force
                }
                # Écriture du nouveau fichier
                Set-Content -Path $webConfigPath -Value $xmlContent -Encoding UTF8 -Force
            }
            
            $results += [PSCustomObject]@{
                Server = $env:COMPUTERNAME
                Site   = $site.Name
                Status = if ($WhatIf) { "Simulé (WhatIf)" } else { "Généré + Backup" }
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

if ($PSCmdlet.ShouldProcess("Les 6 backends", "Générer les 78 fichiers web.config")) {
    try {
        $allResults = Invoke-Command -ComputerName $Servers -UseSSL -ScriptBlock $ScriptBlock -ArgumentList $SqlListener, $AspStateDb, $WhatIfPreference -ErrorAction Stop
        
        Write-Step "Résultat"
        $allResults | Select-Object Server, Site, Status | Sort-Object Server, Site | Format-Table -AutoSize
        
        $errCount = ($allResults | Where-Object { $_.Status -like "*Erreur*" }).Count
        if ($errCount -eq 0) { Write-Ok "Tous les web.config ont été traités avec succès." } 
        else { Write-Fail "$errCount erreur(s) rencontrée(s)." }
    }
    catch {
        Write-Fail "Erreur critique WinRM : $($_.Exception.Message)"
    }
}