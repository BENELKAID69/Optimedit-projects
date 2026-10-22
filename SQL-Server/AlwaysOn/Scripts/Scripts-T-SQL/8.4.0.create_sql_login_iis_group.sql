-- 8.4.0.create_sql_login_iis_group.sql
-- Objet  : Creer le login SQL pour le groupe AD GG_IIS_AppPools et accorder les droits sur les 13 bases applicatives
-- Noeud  : SQLS01 (Primary)
-- PREREQUIS : ASPState doit deja exister et etre dans l'AG (etapes 8.3.0 et 8.3.1),
--             sinon elle est silencieusement absente de la boucle ci-dessous et
--             GG_IIS_AppPools n'obtient jamais de droits dessus.

USE master;
GO

-- ============================================================
-- ETAPE 1 : Création du Login au niveau Serveur
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'OPTIMEDIT\GG_IIS_AppPools')
BEGIN
    CREATE LOGIN [OPTIMEDIT\GG_IIS_AppPools] FROM WINDOWS;
    PRINT 'Login [OPTIMEDIT\GG_IIS_AppPools] cree.';
END
ELSE
    PRINT 'Login [OPTIMEDIT\GG_IIS_AppPools] deja existant.';
GO

-- ============================================================
-- ETAPE 2 : Boucle sur les 14 bases pour créer l'utilisateur et les droits
-- ============================================================
DECLARE @dbName NVARCHAR(128);
DECLARE @sql NVARCHAR(MAX);

-- Curseur sur les bases applicatives + ASPState
DECLARE db_cursor CURSOR FOR
    SELECT name 
    FROM sys.databases 
    WHERE name IN (
        'ASPState', 
        'DB_Direction', 'DB_Comptabilite', 'DB_Paie', 'DB_RH', 'DB_CE', 
        'DB_IT', 'DB_Production', 'DB_Formation', 'DB_Achat', 
        'DB_Commercial', 'DB_Client', 'DB_Juridique', 'DB_Blog'
    )
    AND state_desc = 'ONLINE';

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        USE [' + @dbName + N'];
        
        -- 1. Création de l''utilisateur (si absent)
        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''OPTIMEDIT\GG_IIS_AppPools'')
        BEGIN
            CREATE USER [OPTIMEDIT\GG_IIS_AppPools] FOR LOGIN [OPTIMEDIT\GG_IIS_AppPools];
        END
        
        -- 2. Attribution des rôles de lecture/écriture standards
        ALTER ROLE db_datareader ADD MEMBER [OPTIMEDIT\GG_IIS_AppPools];
        ALTER ROLE db_datawriter ADD MEMBER [OPTIMEDIT\GG_IIS_AppPools];
        
        -- 3. Création d''un rôle db_executor pour les procédures stockées (indispensable pour ASPState)
        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''db_executor'' AND type = ''R'')
        BEGIN
            CREATE ROLE db_executor;
            GRANT EXECUTE TO db_executor;
        END
        ALTER ROLE db_executor ADD MEMBER [OPTIMEDIT\GG_IIS_AppPools];
    ';
    
    BEGIN TRY
        EXEC sp_executesql @sql;
        PRINT 'Droits accordes avec succes dans la base : ' + @dbName;
    END TRY
    BEGIN CATCH
        PRINT 'Erreur dans la base ' + @dbName + ' : ' + ERROR_MESSAGE();
    END CATCH;
    
    FETCH NEXT FROM db_cursor INTO @dbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;
GO

PRINT '8.4.0 - Configuration des droits IIS terminee.';
GO