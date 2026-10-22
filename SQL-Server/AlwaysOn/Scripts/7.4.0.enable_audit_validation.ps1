#📋 Séquence complète


# 1. Vérifier la capture d'événement
Invoke-Sqlcmd -ServerInstance "SQLS01.optimedit.eu" -TrustServerCertificate -Query @"
SELECT TOP 5 event_time, action_id, succeeded, server_principal_name, statement
FROM sys.fn_get_audit_file('S:\SQL\Backup\Audit\*.sqlaudit', DEFAULT, DEFAULT)
ORDER BY event_time DESC;
"@

# 2. Vérifier les fichiers sur disque
Invoke-Command -ComputerName SQLS01.optimedit.eu, SQLS02.optimedit.eu -ScriptBlock {
    Get-ChildItem "S:\SQL\Backup\Audit\*.sqlaudit" -ErrorAction SilentlyContinue |
        Select-Object Name, @{n='Size(KB)';e={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
}

# 3. Redémarrer MSSQLSERVER
Invoke-Command -ComputerName SQLS01.optimedit.eu, SQLS02.optimedit.eu -ScriptBlock {
    Restart-Service MSSQLSERVER -Force
    Start-Sleep -Seconds 10
    Get-Service MSSQLSERVER, SQLSERVERAGENT
}

# 4. Vérifier que l'audit survit au reboot
Invoke-Sqlcmd -ServerInstance "SQLS01.optimedit.eu" -TrustServerCertificate -Query @"
SELECT a.name AS AuditName, a.is_state_enabled AS AuditActive,
       s.name AS SpecName, s.is_state_enabled AS SpecActive
FROM sys.server_audits a
LEFT JOIN sys.server_audit_specifications s ON a.audit_guid = s.audit_guid
WHERE a.name = N'Audit-OPTIMEDIT';
"@


# 1. Vérification de persistance sur SQLS02
Invoke-Sqlcmd -ServerInstance "SQLS02.optimedit.eu" -TrustServerCertificate -Query @"
SELECT 
    a.name AS AuditName, a.is_state_enabled AS AuditActive,
    s.name AS SpecName, s.is_state_enabled AS SpecActive
FROM sys.server_audits a
LEFT JOIN sys.server_audit_specifications s ON a.audit_guid = s.audit_guid
WHERE a.name = N'Audit-OPTIMEDIT';
"@

