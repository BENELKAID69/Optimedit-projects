<#
    3.4.0.configure_network_firewall.ps1
    Objet   : Ouvrir les flux reseau necessaires a SQL Server et Always On
    Noeuds  : SQLS01 + SQLS02

    PRINCIPE :
    - Cree les regles de pare-feu pour SQL Server et Always On.
    - Idempotent : ne recree pas une regle deja existante.

    EXEMPLES D'EXÉCUTION :

    .\3.4.0.configure_network_firewall.ps1
#>

$Rules = @(
    @{ Name = "SQL Server - 1433";        Port = 1433 },
    @{ Name = "AlwaysOn Endpoint - 5022"; Port = 5022 },
    @{ Name = "Cluster RPC - 135";        Port = 135  },
    @{ Name = "SMB - 445";                Port = 445  }
)

foreach ($Rule in $Rules) {
    $Existing = Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue
    if ($Existing) {
        Write-Host "  Regle deja existante : $($Rule.Name)" -ForegroundColor Yellow
    } else {
        New-NetFirewallRule -DisplayName $Rule.Name -Direction Inbound -Protocol TCP -LocalPort $Rule.Port -Action Allow | Out-Null
        Write-Host "  Regle creee : $($Rule.Name) (port $($Rule.Port))" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Configuration reseau terminee." -ForegroundColor Cyan
Write-Host "Vérifier avec la commande suivante la configuration:" -ForegroundColor Cyan
Write-Host 'Get-NetFirewallRule -DisplayName "SQL Server - 1433","AlwaysOn Endpoint - 5022","Cluster RPC - 135","SMB - 445"' -ForegroundColor Cyan


# Vérification après exécution
Get-NetFirewallRule -DisplayName "SQL Server - 1433","AlwaysOn Endpoint - 5022","Cluster RPC - 135","SMB - 445" | Select-Object DisplayName, Enabled, Direction, Action
