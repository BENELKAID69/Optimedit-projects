-- 7.4.0.enable_audit.sql
-- Objet  : Creer l'audit serveur (connexions, DDL, elevations de privileges)
-- Noeud  : SQLS01 + SQLS02
-- Note   : idempotent ; max 100 Mo par fichier, rotation sur 10 fichiers (1 Go total)

USE master;
GO

-- ============================================================
-- ETAPE 1 : Creer l'audit serveur (si inexistant)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'Audit-OPTIMEDIT')
BEGIN
    CREATE SERVER AUDIT [Audit-OPTIMEDIT]
    TO FILE (
        FILEPATH                = 'S:\SQL\Backup\Audit\',
        MAXSIZE                 = 100 MB,
        MAX_ROLLOVER_FILES      = 10,
        RESERVE_DISK_SPACE      = OFF
    )
    WITH (
        QUEUE_DELAY     = 1000,
        ON_FAILURE      = CONTINUE
    );
    PRINT 'Audit-OPTIMEDIT cree.';
END
ELSE
BEGIN
    PRINT 'Audit-OPTIMEDIT existe deja.';
END
GO

-- Activer l'audit
ALTER SERVER AUDIT [Audit-OPTIMEDIT] WITH (STATE = ON);
GO

-- ============================================================
-- ETAPE 2 : Specification CONNEXIONS
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'AuditSpec-Connexions')
BEGIN
    CREATE SERVER AUDIT SPECIFICATION [AuditSpec-Connexions]
    FOR SERVER AUDIT [Audit-OPTIMEDIT]
    ADD (FAILED_LOGIN_GROUP),
    ADD (SUCCESSFUL_LOGIN_GROUP);
    PRINT 'Specification AuditSpec-Connexions creee.';
END
ALTER SERVER AUDIT SPECIFICATION [AuditSpec-Connexions] WITH (STATE = ON);
GO

-- ============================================================
-- ETAPE 3 : Specification DDL + PRIVILEGES
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'AuditSpec-DDL-Privileges')
BEGIN
    CREATE SERVER AUDIT SPECIFICATION [AuditSpec-DDL-Privileges]
    FOR SERVER AUDIT [Audit-OPTIMEDIT]
    ADD (SCHEMA_OBJECT_CHANGE_GROUP),
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (DATABASE_PERMISSION_CHANGE_GROUP),
    ADD (LOGIN_CHANGE_PASSWORD_GROUP),
    ADD (SERVER_OBJECT_CHANGE_GROUP),
    ADD (AUDIT_CHANGE_GROUP),
    ADD (BACKUP_RESTORE_GROUP);
    PRINT 'Specification AuditSpec-DDL-Privileges creee.';
END
ALTER SERVER AUDIT SPECIFICATION [AuditSpec-DDL-Privileges] WITH (STATE = ON);
GO

-- ============================================================
-- ETAPE 4 : Verification
-- ============================================================
PRINT '--- Verification ---';
SELECT name, is_state_enabled, type_desc, on_failure_desc
FROM sys.server_audits WHERE name = N'Audit-OPTIMEDIT';

SELECT name, is_state_enabled
FROM sys.server_audit_specifications WHERE name LIKE N'AuditSpec-%';
GO

PRINT '7.4.0 - Audit serveur configure avec succes.';
GO