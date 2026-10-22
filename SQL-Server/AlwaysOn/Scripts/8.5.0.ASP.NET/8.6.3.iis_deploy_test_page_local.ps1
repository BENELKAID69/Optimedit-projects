<#
    8.6.3.iis_deploy_test_page_local.ps1
    Objet   : Déployer test_session.aspx sur les 13 sites des 6 backends IIS
    Noeud   : Exécution depuis DC03 ou poste admin (via WinRM HTTPS)
    Note    : Alternative au playbook Ansible 06.03. Supporte -WhatIf.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Servers = @(
        "OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", 
        "OPT-IIS-04.optimedit.eu", "OPT-IIS-05.optimedit.eu", "OPT-IIS-06.optimedit.eu"
    )
)

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "  [ECHEC] $Message" -ForegroundColor Red }

Write-Step "Déploiement de test_session.aspx sur $($Servers.Count) backends"

$ScriptBlock = {
    param($WhatIf)

    Import-Module WebAdministration -ErrorAction Stop
    $sites = Get-Website
    $results = @()

    # Contenu de la page ASPX
    $aspxContent = @"
<%@ Page Language="C#" %>
<!DOCTYPE html>
<html>
<head>
    <title>Test Session State SQL</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; padding: 40px; background: #f4f6f9; }
        .box { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 4px 12px rgba(0,0,0,0.1); max-width: 600px; }
        h1 { color: #0B3D91; }
        .data { font-size: 1.2rem; margin: 15px 0; }
        .value { font-weight: bold; color: #F5A623; }
    </style>
</head>
<body>
    <div class="box">
        <h1>🔍 Diagnostic Session State</h1>
        <%
            string serveur = System.Environment.MachineName;
            if (Session["Compteur"] == null) { Session["Compteur"] = 1; } 
            else { Session["Compteur"] = (int)Session["Compteur"] + 1; }
            string sessionId = Session.SessionID;
        %>
        <div class="data">🖥️ Backend IIS actuel : <span class="value"><%= serveur %></span></div>
        <div class="data">🆔 ID de session : <span class="value"><%= sessionId %></span></div>
        <div class="data">🔢 Valeur du compteur : <span class="value"><%= Session["Compteur"] %></span></div>
    </div>
</body>
</html>
"@

    foreach ($site in $sites) {
        $aspxPath = Join-Path $site.PhysicalPath "test_session.aspx"
        
        try {
            if (-not $WhatIf) {
                Set-Content -Path $aspxPath -Value $aspxContent -Encoding UTF8 -Force
            }
            
            $results += [PSCustomObject]@{
                Server = $env:COMPUTERNAME
                Site   = $site.Name
                Status = if ($WhatIf) { "Simulé (WhatIf)" } else { "Déployé" }
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

if ($PSCmdlet.ShouldProcess("Les 6 backends", "Déployer test_session.aspx sur les 78 sites")) {
    try {
        $allResults = Invoke-Command -ComputerName $Servers -UseSSL -ScriptBlock $ScriptBlock -ArgumentList $WhatIfPreference -ErrorAction Stop
        
        Write-Step "Résultat"
        $allResults | Select-Object Server, Site, Status | Sort-Object Server, Site | Format-Table -AutoSize
        
        $errCount = ($allResults | Where-Object { $_.Status -like "*Erreur*" }).Count
        if ($errCount -eq 0) { Write-Ok "Page de test déployée avec succès." } 
        else { Write-Fail "$errCount erreur(s) rencontrée(s)." }
    }
    catch {
        Write-Fail "Erreur critique WinRM : $($_.Exception.Message)"
    }
}