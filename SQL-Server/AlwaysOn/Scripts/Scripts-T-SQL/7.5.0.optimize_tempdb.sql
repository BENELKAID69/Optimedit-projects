-- 7.5.0.optimize_tempdb.sql
-- Objet  : Configurer TempDB avec 8 fichiers de 2 GB (optimal pour 8 CPU)
-- Noeuds : SQLS01 + SQLS02
-- Note   : machine avec 8 CPU logiques -> 8 fichiers TempDB recommandes

USE master;
GO

-- ============================================================
-- ETAPE 1 : Redimensionner les 8 fichiers data a 2 GB
-- ============================================================
ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'tempdev redimensionne a 2 GB.';
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = temp2, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'temp2 redimensionne a 2 GB.';
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = temp3, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'temp3 redimensionne a 2 GB.';
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = temp4, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'temp4 redimensionne a 2 GB.';
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = temp5, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'temp5 redimensionne a 2 GB.';
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = temp6, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'temp6 redimensionne a 2 GB.';
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = temp7, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'temp7 redimensionne a 2 GB.';
GO

ALTER DATABASE tempdb MODIFY FILE (NAME = temp8, SIZE = 2GB, FILEGROWTH = 512MB, MAXSIZE = 8GB);
PRINT 'temp8 redimensionne a 2 GB.';
GO

-- ============================================================
-- ETAPE 2 : Redimensionner le log
-- ============================================================
ALTER DATABASE tempdb MODIFY FILE (NAME = templog, SIZE = 512MB, FILEGROWTH = 256MB, MAXSIZE = 2GB);
PRINT 'templog redimensionne a 512 MB.';
GO

-- ============================================================
-- ETAPE 3 : Verification
-- ============================================================
PRINT '--- Etat de TempDB ---';
SELECT 
    name               AS LogicalName,
    physical_name      AS PhysicalPath,
    size * 8 / 1024    AS SizeMB,
    growth * 8 / 1024  AS GrowthMB,
    max_size * 8 / 1024 AS MaxSizeMB,
    type_desc
FROM tempdb.sys.database_files
ORDER BY file_id;
GO

PRINT '7.5.0 - TempDB configure (8 fichiers de 2 GB). Redemarrage requis.';
GO