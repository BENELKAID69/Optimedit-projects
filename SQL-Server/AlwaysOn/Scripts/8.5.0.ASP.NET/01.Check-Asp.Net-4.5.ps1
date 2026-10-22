$servers = @(
    "OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", 
    "OPT-IIS-04.optimedit.eu", "OPT-IIS-05.optimedit.eu", "OPT-IIS-06.optimedit.eu"
)

Invoke-Command -ComputerName $servers -UseSSL -ScriptBlock {
    Get-WindowsFeature Web-Asp-Net45 | 
        Select-Object @{n='Server';e={$env:COMPUTERNAME}}, Name, InstallState
} | Select-Object Server, Name, InstallState | Sort-Object Server | Format-Table -AutoSize