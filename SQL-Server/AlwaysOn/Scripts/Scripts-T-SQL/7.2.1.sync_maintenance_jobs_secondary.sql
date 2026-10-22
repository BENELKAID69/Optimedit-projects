-- 7.2.1.sync_maintenance_jobs_secondary.sql
-- Objet  : Recreer les jobs de maintenance sur SQLS02 (Secondary), avec garde AG-aware
--          (msdb n'est pas repliquee par l'AG : sans ce script, plus aucune
--           sauvegarde/CHECKDB ne s'execute apres une bascule vers SQLS02)
-- Noeud  : SQLS02 (Secondary)
-- IMPORTANT : les jobs sont identiques a ceux de 7.2.0 (memes noms, memes
--             schedules) pour que la bascule soit transparente cote SQL Agent.

USE msdb;
GO

-- ============================================================
-- JOB 1 : Backup FULL hebdomadaire des 13 bases (AG-aware)
-- ============================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Backup FULL Weekly')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Backup FULL Weekly', @delete_unused_schedule = 0;
END
GO

EXEC msdb.dbo.sp_add_job 
    @job_name = N'DBA - Backup FULL Weekly',
    @enabled = 1,
    @description = N'Backup FULL hebdomadaire des 13 bases applicatives (AG-aware, cree par 7.2.1 sur le SECONDARY).';
GO

EXEC msdb.dbo.sp_add_jobstep 
    @job_name = N'DBA - Backup FULL Weekly',
    @step_id = 1,
    @step_name = N'Backup FULL toutes bases utilisateur (si Primary)',
    @subsystem = N'TSQL',
    @command = N'
DECLARE @dbName SYSNAME;
DECLARE @sql NVARCHAR(MAX);
DECLARE db_cursor CURSOR FOR
    SELECT name FROM sys.databases 
    WHERE name LIKE ''DB[_]%'' AND database_id > 4;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Garde AG-aware : ne sauvegarder que si ce replica est prefere
    IF (SELECT sys.fn_hadr_backup_is_preferred_replica(@dbName)) = 1
    BEGIN
        SET @sql = N''BACKUP DATABASE ['' + @dbName + N''] TO DISK = N''''S:\SQL\Backup\'' + @dbName + N''_FULL.bak'''' WITH INIT, COMPRESSION;'';
        EXEC sp_executesql @sql;
    END
    FETCH NEXT FROM db_cursor INTO @dbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;',
    @database_name = N'master',
    @on_success_action = 1,
    @on_fail_action = 2;
GO

-- Schedule : chaque dimanche a 02h00 (nom IDENTIQUE a 7.2.0 pour eviter les doublons)
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'Chaque dimanche 02h00')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = N'Chaque dimanche 02h00';
END
GO

EXEC msdb.dbo.sp_add_schedule 
    @schedule_name = N'Chaque dimanche 02h00',
    @freq_type = 8,              -- Weekly
    @freq_interval = 1,          -- Sunday
    @freq_recurrence_factor = 1,
    @active_start_time = 020000;
GO

EXEC msdb.dbo.sp_attach_schedule 
    @job_name = N'DBA - Backup FULL Weekly', 
    @schedule_name = N'Chaque dimanche 02h00';
GO

EXEC msdb.dbo.sp_add_jobserver 
    @job_name = N'DBA - Backup FULL Weekly';
GO

-- ============================================================
-- JOB 2 : DBCC CHECKDB hebdomadaire des 13 bases
-- ============================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Integrity Check (CHECKDB)')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Integrity Check (CHECKDB)', @delete_unused_schedule = 0;
END
GO

EXEC msdb.dbo.sp_add_job 
    @job_name = N'DBA - Integrity Check (CHECKDB)',
    @enabled = 1,
    @description = N'DBCC CHECKDB hebdomadaire des 13 bases applicatives (cree par 7.2.1 sur le SECONDARY).';
GO

EXEC msdb.dbo.sp_add_jobstep 
    @job_name = N'DBA - Integrity Check (CHECKDB)',
    @step_id = 1,
    @step_name = N'DBCC CHECKDB toutes bases',
    @subsystem = N'TSQL',
    @command = N'
DECLARE @dbName SYSNAME;
DECLARE @sql NVARCHAR(MAX);
DECLARE db_cursor CURSOR FOR
    SELECT name FROM sys.databases 
    WHERE name LIKE ''DB[_]%'' AND database_id > 4;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @dbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N''DBCC CHECKDB(['' + @dbName + N'']) WITH NO_INFOMSGS;'';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM db_cursor INTO @dbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;',
    @database_name = N'master',
    @on_success_action = 1,
    @on_fail_action = 2;
GO

-- Schedule : chaque samedi a 01h00 (nom IDENTIQUE a 7.2.0 ; freq_interval = 7 = Saturday)
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'Chaque samedi 01h00')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = N'Chaque samedi 01h00';
END
GO

EXEC msdb.dbo.sp_add_schedule 
    @schedule_name = N'Chaque samedi 01h00',
    @freq_type = 8,
    @freq_interval = 7,          -- Saturday (et non 1 = dimanche)
    @freq_recurrence_factor = 1,
    @active_start_time = 010000;
GO

EXEC msdb.dbo.sp_attach_schedule 
    @job_name = N'DBA - Integrity Check (CHECKDB)', 
    @schedule_name = N'Chaque samedi 01h00';
GO

EXEC msdb.dbo.sp_add_jobserver 
    @job_name = N'DBA - Integrity Check (CHECKDB)';
GO

PRINT '7.2.1 - Jobs de maintenance synchronises sur le SECONDARY avec succes.';
GO