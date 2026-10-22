<#
    4.4.0.configure_cluster_quorum.ps1
    Objet   : Configurer le quorum du cluster (File Share Witness)
#>

Set-ClusterQuorum -FileShareWitness "\\OPT-FS03\ClusterWitness"

Write-Host "Quorum configure (File Share Witness sur OPT-FS03)." -ForegroundColor Green
