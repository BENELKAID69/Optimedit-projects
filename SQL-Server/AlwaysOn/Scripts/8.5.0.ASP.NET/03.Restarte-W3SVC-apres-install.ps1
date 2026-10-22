# Redémarrer IIS sur les 6 backends (à faire après l'installation d'ASP.NET)

$servers = @(
    "OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", 
    "OPT-IIS-04.optimedit.eu", "OPT-IIS-05.optimedit.eu", "OPT-IIS-06.optimedit.eu"
)


Invoke-Command -ComputerName $servers -UseSSL -ScriptBlock {
    iisreset /noforce
    Get-Service W3SVC | Select-Object Name, Status
}