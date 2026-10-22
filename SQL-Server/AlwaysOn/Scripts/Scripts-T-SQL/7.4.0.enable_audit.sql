Set-Location "C:\Scripts\_Projet AlwaysOn"

$sql = @'
-- 7.4.0.enable_audit.sql
-- Objet  : Creer l'audit serveur (connexions, DDL, elevations de privileges)
-- Noeud  : SQLS01 + SQLS02
-- Note   : idempotent ; UNE SEULE spec par audit (contrainte SQL Server)
--          Max 100 Mo par fichier, rotation sur 10 fichiers (1 Go total)

USE master;
GO

-- ============================================================
-- ETAPE 0 : Nettoyage (idempotence)
-- ============================================================
IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'AuditSpec-OPTIMEDIT')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION [AuditSpec-OPTIMEDIT] WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION [AuditSpec-OPTIMEDIT];
    PRINT 'Ancienne spec AuditSpec-OPTIMEDIT supprimee.';
END
GO

-- Supprime aussi les anciennes specs (si migration depuis une version precedente)
IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'AuditSpec-Connexions')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION [AuditSpec-Connexions] WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION [AuditSpec-Connexions];
    PRINT 'Ancienne spec AuditSpec-Connexions supprimee.';
END
GO

IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'AuditSpec-DDL-Privileges')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION [AuditSpec-DDL-Privileges] WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION [AuditSpec-DDL-Privileges];
    PRINT 'Ancienne spec AuditSpec-DDL-Privileges supprimee.';
END
GO

IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'Audit-OPTIMEDIT')
BEGIN
    ALTER SERVER AUDIT [Audit-OPTIMEDIT] WITH (STATE = OFF);
    DROP SERVER AUDIT [Audit-OPTIMEDIT];
    PRINT 'Ancien Audit-OPTIMEDIT supprime.';
END
GO

-- ============================================================
-- ETAPE 1 : Creer l'audit serveur
-- ============================================================
CREATE SERVER AUDIT [Audit-OPTIMEDIT]
TO FILE (
    FILEPATH           = 'S:\SQL\Backup\Audit\',
    MAXSIZE            = 100 MB,
    MAX_ROLLOVER_FILES = 10,
    RESERVE_DISK_SPACE = OFF
)
WITH (
    QUEUE_DELAY = 1000,
    ON_FAILURE  = CONTINUE
);
PRINT 'Audit-OPTIMEDIT cree.';
GO

ALTER SERVER AUDIT [Audit-OPTIMEDIT] WITH (STATE = ON);
GO

-- ============================================================
-- ETAPE 2 : Creer LA spec unique (connexions + DDL + privileges)
-- ============================================================
CREATE SERVER AUDIT SPECIFICATION [AuditSpec-OPTIMEDIT]
FOR SERVER AUDIT [Audit-OPTIMEDIT]
    -- Connexions
    ADD (FAILED_LOGIN_GROUP),
    ADD (SUCCESSFUL_LOGIN_GROUP),
    -- DDL et changements de schema
    ADD (SCHEMA_OBJECT_CHANGE_GROUP),
    ADD (SERVER_OBJECT_CHANGE_GROUP),
    ADD (DATABASE_OBJECT_CHANGE_GROUP),
    -- Roles et permissions
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (DATABASE_PERMISSION_CHANGE_GROUP),
    ADD (SERVER_PERMISSION_CHANGE_GROUP),
    -- Securite des comptes
    ADD (LOGIN_CHANGE_PASSWORD_GROUP),
    ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
    ADD (DATABASE_PRINCIPAL_CHANGE_GROUP),
    -- Audit lui-meme
    ADD (AUDIT_CHANGE_GROUP),
    -- Backup/Restore (utile pour tracer les operations sensibles)
    ADD (BACKUP_RESTORE_GROUP);
PRINT 'AuditSpec-OPTIMEDIT creee.';
GO

ALTER SERVER AUDIT SPECIFICATION [AuditSpec-OPTIMEDIT] WITH (STATE = ON);
GO

-- ============================================================
-- ETAPE 3 : Verification
-- ============================================================
PRINT '--- Verification ---';
SELECT name, is_state_enabled, on_failure_desc
FROM sys.server_audits WHERE name = N'Audit-OPTIMEDIT';

SELECT name, is_state_enabled
FROM sys.server_audit_specifications WHERE name = N'AuditSpec-OPTIMEDIT';

SELECT 
    s.name AS SpecName,
    COUNT(sad.audit_action_id) AS NbActions
FROM sys.server_audit_specifications s
JOIN sys.server_audit_specification_details sad 
    ON s.server_specification_id = sad.server_specification_id
WHERE s.name = N'AuditSpec-OPTIMEDIT'
GROUP BY s.name;
GO

PRINT '7.4.0 - Audit serveur configure avec succes.';
GO
'@

Set-Content -Path ".\Scripts-T-SQL\7.4.0.enable_audit.sql" -Value $sql -Encoding UTF8

$fileInfo = Get-Item ".\Scripts-T-SQL\7.4.0.enable_audit.sql"
Write-Host "[OK] Fichier regenere : $($fileInfo.Length) octets" -ForegroundColor Green