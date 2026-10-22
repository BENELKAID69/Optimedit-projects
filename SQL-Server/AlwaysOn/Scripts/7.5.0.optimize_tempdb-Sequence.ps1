Set-Location "C:\Scripts\_Projet AlwaysOn"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 1. Créer les fichiers (déjà fait : .sql + .ps1)
# 2. Prévisualiser
.\7.5.0.optimize_tempdb.ps1 -WhatIf

# 3. Exécuter
.\7.5.0.optimize_tempdb.ps1

# 4. Redémarrer SQLS02 EN PREMIER (pour minimiser l'impact)
Invoke-Command -ComputerName SQLS02.optimedit.eu -ScriptBlock {
    Restart-Service MSSQLSERVER -Force
    Start-Sleep -Seconds 15
    Get-Service MSSQLSERVER, SQLSERVERAGENT
}

# 5. Redémarrer SQLS01
Invoke-Command -ComputerName SQLS01.optimedit.eu -ScriptBlock {
    Restart-Service MSSQLSERVER -Force
    Start-Sleep -Seconds 15
    Get-Service MSSQLSERVER, SQLSERVERAGENT
}

# 6. Vérifier que les 4 fichiers existent
foreach ($node in @("SQLS01.optimedit.eu", "SQLS02.optimedit.eu")) {
    Write-Host "=== $node ===" -ForegroundColor Cyan
    Invoke-Sqlcmd -ServerInstance $node -Query @"
SELECT name, size * 8 / 1024 AS SizeMB FROM tempdb.sys.database_files WHERE type_desc = 'ROWS';
"@ -TrustServerCertificate | Format-Table -AutoSize
}

# 7. Vérifier la sante de l'AG
Invoke-Sqlcmd -ServerInstance "SQLS01.optimedit.eu" -TrustServerCertificate -Query @"
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;
"@


# Si SQLS01 bascule vers SECONDARY faire cette verification 
# Interroger depuis SQLS02 (qui devrait être le nouveau PRIMARY)
Invoke-Sqlcmd -ServerInstance "SQLS02.optimedit.eu" -TrustServerCertificate -Query @"
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;
"@

# Et l'état du cluster
Import-Module FailoverClusters
Get-ClusterGroup -Name "AG-OPTIMEDIT" | Select-Object Name, State, OwnerNode

# ***** REBASCULER SQLS01 VERS PRIMARY ***********************

Import-Module SqlServer
Switch-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\SQLS01\DEFAULT\AvailabilityGroups\AG-OPTIMEDIT"

Start-Sleep -Seconds 15

# Vérifier
Invoke-Sqlcmd -ServerInstance "SQLS01.optimedit.eu" -TrustServerCertificate -Query @"
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;
"@


Import-Module FailoverClusters

# Voir l'état des deux nœuds
Get-ClusterNode | Select-Object Name, State, NodeWeight, DynamicWeight