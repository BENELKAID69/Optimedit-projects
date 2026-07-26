

# On cible uniquement ceux qui ont plus de 1 certificat
$PollutedServers = @("OPT-IIS-01", "OPT-IIS-02", "OPT-IIS-03","OPT-IIS-04", "OPT-IIS-05", "OPT-IIS-06")

Invoke-Command -ComputerName $PollutedServers {
    Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, NotAfter, Thumbprint | 
    Format-Table -AutoSize
}