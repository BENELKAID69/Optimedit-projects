<#
    8.7.1.verify_iis_sessionstate.ps1
    Objet   : Auditer le mode Session State (InProc vs SQLServer) sur tous les serveurs IIS
    Noeud   : Exécution depuis DC03 ou poste admin (via WinRM HTTPS)
    Note    : Script en lecture seule. Vérifie les 6 backends et le Reverse Proxy.
#>

[CmdletBinding()]
param(
    [string[]]$Servers = @(
        "OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", 
        "OPT-IIS-04.optimedit.eu", "OPT-IIS-05.optimedit.eu", "OPT-IIS-06.optimedit.eu",
        "OPT-RP-01.optimedit.eu"
    )
)

Write-Host "`n=== Audit du mode Session State sur les serveurs IIS ===" -ForegroundColor Cyan

Invoke-Command -ComputerName $Servers -UseSSL -ErrorAction SilentlyContinue -ScriptBlock {
    Import-Module WebAdministration
    $results = @()
    
    Get-Website | ForEach-Object {
        $site = $_
        $webConfigPath = Join-Path $site.PhysicalPath "web.config"
        $sessionMode = "Non configuré (InProc par défaut)"
        
        if (Test-Path $webConfigPath) {
            try {
                [xml]$xml = Get-Content $webConfigPath -ErrorAction Stop
                $sessionNode = $xml.SelectSingleNode("/configuration/system.web/sessionState")
                if ($sessionNode) {
                    $sessionMode = $sessionNode.mode
                    if ($sessionMode -eq "SQLServer") {
                        $sessionMode = "SQLServer (via ASPState)"
                    }
                }
            } catch {
                $sessionMode = "Erreur lecture XML"
            }
        }

        $results += [PSCustomObject]@{
            Server      = $env:COMPUTERNAME
            Site        = $site.Name
            SessionMode = $sessionMode
        }
    }
    return $results
} | Select-Object Server, Site, SessionMode | Sort-Object Server, Site | Format-Table -AutoSize

Write-Host "  [OK] Audit terminé." -ForegroundColor Green