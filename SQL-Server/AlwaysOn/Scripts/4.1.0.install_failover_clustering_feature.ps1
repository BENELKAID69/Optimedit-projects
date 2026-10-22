<#
    4.1.0.install_failover_clustering_feature.ps1
    Objet   : Installer la fonctionnalite Failover Clustering
    Noeuds  : SQLS01 + SQLS02
#>

Install-WindowsFeature Failover-Clustering -IncludeManagementTools
Install-WindowsFeature RSAT-Clustering
Install-WindowsFeature RSAT-AD-PowerShell

Write-Host "Fonctionnalites de clustering installees." -ForegroundColor Green
