-- 7.3.0c.create_alert_job.sql
-- Objet  : Creer le job SQL Agent qui envoie les emails d'alerte via PowerShell
-- Noeud  : SQLS01 + SQLS02
-- Note   : contourne Database Mail (incompatible avec OVH SMTP)

USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Send Alert Email')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Send Alert Email', @delete_unused_schedule = 1;
    PRINT 'Ancien job DBA - Send Alert Email supprime.';
END
GO

EXEC msdb.dbo.sp_add_job
    @job_name    = N'DBA - Send Alert Email',
    @enabled     = 1,
    @description = N'Envoie un email via PowerShell (Send-MailMessage) quand une alerte se declenche. Contourne Database Mail (incompatible OVH SMTP).';
GO

EXEC msdb.dbo.sp_add_jobstep
    @job_name       = N'DBA - Send Alert Email',
    @step_id        = 1,
    @step_name      = N'Send via PowerShell',
    @subsystem      = N'PowerShell',
    @command        = N'& "C:\Scripts\_Projet AlwaysOn\Scripts-T-SQL\send_alert_email.ps1"',
    @database_name  = N'master',
    @on_success_action = 1,
    @on_fail_action    = 2;
GO

EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'DBA - Send Alert Email';
GO

PRINT '7.3.0c - Job DBA - Send Alert Email cree avec succes.';
GO

SELECT j.name AS JobName, j.enabled, s.step_name, s.subsystem
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE j.name = N'DBA - Send Alert Email';
GO