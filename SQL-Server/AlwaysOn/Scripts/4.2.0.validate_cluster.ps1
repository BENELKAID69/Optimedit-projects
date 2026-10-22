<#
    4.2.0.validate_cluster.ps1
    Objet   : Valider la configuration avant creation du cluster
    Noeud   : a executer depuis SQLS01 ou SQLS02
	les rapports sont générés dans "C:\Windows\Cluster\Reports"
#>

$Nodes = @("SQLS01","SQLS02")
Test-Cluster -Node $Nodes -Verbose

# pour lister toutes les validations à vérifier ..
# Test-Cluster -List

<#
Test-Cluster -Node
Test-Cluster -Disk
Test-Cluster -Pool
Test-Cluster -ReportName
#>

# Pour générer un rapport sur la validation de configuration Active Directory
# Test-Cluster -ReportName "Valider la configuration Active Directory"

Write-Host "Validation terminee - consulter le rapport HTML genere." -ForegroundColor Green
