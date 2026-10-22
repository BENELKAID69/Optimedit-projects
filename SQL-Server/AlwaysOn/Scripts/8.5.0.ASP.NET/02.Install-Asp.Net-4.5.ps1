$servers = @(
    "OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", 
    "OPT-IIS-04.optimedit.eu", "OPT-IIS-05.optimedit.eu", "OPT-IIS-06.optimedit.eu"
)

Invoke-Command -ComputerName $servers -UseSSL -ScriptBlock {
    $feature = Get-WindowsFeature Web-Asp-Net45
    if ($feature.InstallState -eq 'Available') {
        Write-Host "[$env:COMPUTERNAME] Installation de Web-Asp-Net45..." -ForegroundColor Cyan
        Install-WindowsFeature Web-Asp-Net45 -IncludeManagementTools | Out-Null
        Write-Host "[$env:COMPUTERNAME] Installation terminée." -ForegroundColor Green
    } else {
        Write-Host "[$env:COMPUTERNAME] Déjà installé (ignoré)." -ForegroundColor Yellow
    }
    
    # Vérification finale
    Get-WindowsFeature Web-Asp-Net45 | Select-Object Name, InstallState
} | Format-Table PSComputerName, Name, InstallState -AutoSize