# ============================================================
# Script manuel - Bascule de l'AG si le nœud courant est SECONDARY
# ============================================================

# Le nœud courant est-il SECONDARY ?
$currentNode = $env:COMPUTERNAME

$roleQuery = @"
SELECT 
    ar.replica_server_name AS Replica,
    ars.role_desc AS Role,
    ars.connected_state_desc AS ConnState
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = 'AG-OPTIMEDIT'
ORDER BY ar.replica_server_name
"@

$roles = Invoke-Sqlcmd -ServerInstance "SQLS01.optimedit.eu" -TrustServerCertificate -Query $roleQuery

# Récupérer le rôle du nœud courant
$currentRole = ($roles | Where-Object { $_.Replica -eq $currentNode }).Role

if ($currentRole -eq "SECONDARY") {
    Write-Host "[INFO] $currentNode est SECONDARY -> bascule en PRIMARY..." -ForegroundColor Cyan

    Set-Location "C:\Scripts\_Projet AlwaysOn"
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

    # Vérifier l'état AVANT
    Import-Module FailoverClusters
    $ag = Get-ClusterGroup -Name "AG-OPTIMEDIT"
    Write-Host "Primary AVANT : $($ag.OwnerNode.Name)" -ForegroundColor Cyan

    # Exécuter le failover
    Import-Module SqlServer
    Switch-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$currentNode\DEFAULT\AvailabilityGroups\AG-OPTIMEDIT"

    # Attendre la stabilisation
    Start-Sleep -Seconds 15

    # Vérifier l'état APRÈS
    Invoke-Sqlcmd -ServerInstance "$currentNode.optimedit.eu" -TrustServerCertificate -Query @"
SELECT 
    ar.replica_server_name AS Replica,
    ars.role_desc AS Role,
    ars.connected_state_desc AS ConnState,
    ars.synchronization_health_desc AS SyncHealth
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = 'AG-OPTIMEDIT'
ORDER BY ar.replica_server_name
"@ | Format-Table Replica, Role, ConnState, SyncHealth -AutoSize

    # Vérifier TDE via le Listener
    klist purge
    sqlcmd -S SQL-AG-LSTNR.optimedit.eu -E -Q "SELECT @@SERVERNAME AS ServerName"
    sqlcmd -S SQL-AG-LSTNR.optimedit.eu -E -Q "SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID"

    Invoke-Sqlcmd -ServerInstance "SQL-AG-LSTNR.optimedit.eu" -TrustServerCertificate -Query @"
SELECT 
    db.name AS DatabaseName,
    dek.encryption_state AS EncryptionState,
    CASE dek.encryption_state
        WHEN 3 THEN 'Encrypted'
        ELSE 'Other'
    END AS EncryptionStateDesc
FROM sys.databases db
LEFT JOIN sys.dm_database_encryption_keys dek ON db.database_id = dek.database_id
WHERE db.name LIKE 'DB_%'
ORDER BY db.name
"@
}
else {
    Write-Host "[SKIP] $currentNode est $currentRole (pas SECONDARY) -> aucune bascule." -ForegroundColor Yellow
}