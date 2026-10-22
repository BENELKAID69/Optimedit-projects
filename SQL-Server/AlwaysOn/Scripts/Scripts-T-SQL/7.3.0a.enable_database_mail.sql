-- 7.3.0a.enable_database_mail.sql
-- Objet  : Activer le composant Database Mail XPs (désactivé par défaut)
-- Nœud   : SQLS01 + SQLS02
-- Note   : cette activation est idempotente (sans effet si déjà activée)

USE master;
GO

-- ============================================================
-- ETAPE 1 : Activer 'show advanced options' si nécessaire
-- ============================================================
IF (SELECT value_in_use FROM sys.configurations WHERE name = 'show advanced options') = 0
BEGIN
    EXEC sp_configure 'show advanced options', 1;
    RECONFIGURE;
    PRINT 'show advanced options active.';
END
ELSE
    PRINT 'show advanced options deja active.';
GO

-- ============================================================
-- ETAPE 2 : Activer 'Database Mail XPs'
-- ============================================================
IF (SELECT value_in_use FROM sys.configurations WHERE name = 'Database Mail XPs') = 0
BEGIN
    EXEC sp_configure 'Database Mail XPs', 1;
    RECONFIGURE;
    PRINT 'Database Mail XPs active.';
END
ELSE
    PRINT 'Database Mail XPs deja active.';
GO

-- ============================================================
-- ETAPE 3 : Vérification
-- ============================================================
PRINT '--- Verification ---';
SELECT 
    name         AS ConfigurationName, 
    value_in_use AS ValueInUse,
    CASE value_in_use 
        WHEN 1 THEN 'Active' 
        WHEN 0 THEN 'Desactive' 
        ELSE 'Autre' 
    END AS Statut
FROM sys.configurations
WHERE name IN ('show advanced options', 'Database Mail XPs')
ORDER BY name;
GO

PRINT '7.3.0a - Database Mail XPs active avec succes.';
GO