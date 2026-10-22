<#
    4.3.0.create_cluster.ps1
    Objet   : Creer le cluster Windows CL-SQL-AG
    IP      : 192.168.1.253 (adresse du cluster - CNO)
    Noeud   : a executer depuis SQLS01 ou SQLS02
#>

New-Cluster -Name "CL-SQL-AG" -Node "SQLS01","SQLS02" `
            -StaticAddress "192.168.1.253" -NoStorage

Write-Host "Cluster CL-SQL-AG cree avec l'adresse 192.168.1.253." -ForegroundColor Green
