-- 6.1.0.create_application_databases.sql
-- Objet  : Créer les 13 bases applicatives (idempotent) + FULL recovery + backup FULL/LOG
-- Noeud  : SQLS01 (Primary)
-- Version : 2.0 (avec gestion d'erreur + vérifications)

--- *************************************************************************************************************
--- *** Pour la creation des BDD applciations utiliser le script ps1 "6.1.0.create_application_databases.ps1" ***
--- *************************************************************************************************************



SET NOCOUNT ON;
GO

-- ============================================================
-- Configuration
-- ============================================================
DECLARE @BackupPath NVARCHAR(500) = 'S:\SQL\Backup\';
DECLARE @Collation NVARCHAR(100) = 'SQL_Latin1_General_CP1_CI_AS';

-- ============================================================
-- Liste des 13 bases
-- ============================================================
DECLARE @Bases TABLE (Nom NVARCHAR(100));
INSERT INTO @Bases VALUES
('DB_Direction'),('DB_Comptabilite'),('DB_Paie'),('DB_RH'),('DB_CE'),
('DB_IT'),('DB_Production'),('DB_Formation'),('DB_Achat'),
('DB_Commercial'),('DB_Client'),('DB_Juridique'),('DB_Blog');

-- ============================================================
-- Boucle sur les bases
-- ============================================================
DECLARE @Name NVARCHAR(100);
DECLARE @BackupFile NVARCHAR(500);
DECLARE @LogFile NVARCHAR(500);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @CreatedCount INT = 0;
DECLARE @SkippedCount INT = 0;
DECLARE @ErrorCount INT = 0;

DECLARE c CURSOR FOR SELECT Nom FROM @Bases;
OPEN c;
FETCH NEXT FROM c INTO @Name;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF DB_ID(@Name) IS NULL
        BEGIN
            -- Création de la base
            SET @SQL = 'CREATE DATABASE [' + @Name + '] COLLATE ' + @Collation;
            EXEC sp_executesql @SQL;
            PRINT 'Base creee : ' + @Name;

            -- Recovery FULL
            SET @SQL = 'ALTER DATABASE [' + @Name + '] SET RECOVERY FULL';
            EXEC sp_executesql @SQL;

            -- Backup FULL
            SET @BackupFile = @BackupPath + @Name + '_FULL.bak';
            SET @SQL = 'BACKUP DATABASE [' + @Name + '] TO DISK = ''' + @BackupFile + ''' WITH INIT, COMPRESSION';
            EXEC sp_executesql @SQL;
            PRINT '  Backup FULL : ' + @BackupFile;

            -- Backup LOG
            SET @LogFile = @BackupPath + @Name + '_LOG.trn';
            SET @SQL = 'BACKUP LOG [' + @Name + '] TO DISK = ''' + @LogFile + ''' WITH INIT, COMPRESSION';
            EXEC sp_executesql @SQL;
            PRINT '  Backup LOG : ' + @LogFile;

            SET @CreatedCount = @CreatedCount + 1;
        END
        ELSE
        BEGIN
            PRINT 'Base deja existante : ' + @Name;
            SET @SkippedCount = @SkippedCount + 1;
        END
    END TRY
    BEGIN CATCH
        PRINT 'ERREUR sur ' + @Name + ' : ' + ERROR_MESSAGE();
        SET @ErrorCount = @ErrorCount + 1;
    END CATCH

    FETCH NEXT FROM c INTO @Name;
END

CLOSE c;
DEALLOCATE c;

-- ============================================================
-- Résumé
-- ============================================================
PRINT '';
PRINT '========================================';
PRINT 'Résumé :';
PRINT '  Bases créées   : ' + CAST(@CreatedCount AS NVARCHAR(10));
PRINT '  Bases ignorées : ' + CAST(@SkippedCount AS NVARCHAR(10));
PRINT '  Erreurs        : ' + CAST(@ErrorCount AS NVARCHAR(10));
PRINT '========================================';
GO

-- ============================================================
-- Vérification finale
-- ============================================================
PRINT '';
PRINT 'Vérification des bases :';
SELECT 
    name AS DatabaseName,
    recovery_model_desc AS RecoveryModel,
    state_desc AS State,
    collation_name AS Collation
FROM sys.databases
WHERE name LIKE 'DB_%'
ORDER BY name;
GO

-- Vérifier les backups
PRINT '';
PRINT 'Vérification des backups :';
SELECT 
    database_name AS DatabaseName,
    type AS BackupType,
    backup_finish_date AS BackupDate,
    backup_size AS BackupSize
FROM msdb.dbo.backupset
WHERE database_name LIKE 'DB_%'
ORDER BY database_name, backup_finish_date DESC;
GO