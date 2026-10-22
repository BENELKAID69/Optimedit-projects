-- 7.3.0.create_alerts.sql
-- Objet  : Creer les alertes SQL Server (severites 19-25 + erreurs I/O critiques)
-- Noeud  : SQLS01 + SQLS02 (msdb n'est pas repliquee par l'AG)
-- Note   : idempotent - supprime puis recree chaque alerte

USE msdb;
GO

-- ============================================================
-- ETAPE 0 : Creer l'operateur s'il n'existe pas
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'DBA-Ops')
BEGIN
    EXEC msdb.dbo.sp_add_operator
        @name           = N'DBA-Ops',
        @enabled        = 1,
        @email_address  = N'contact@optimedit.eu;optimedit.fr@gmail.com';
    PRINT 'Operateur DBA-Ops cree.';
END
ELSE
    PRINT 'Operateur DBA-Ops deja existant.';
GO

-- ============================================================
-- ETAPE 1 : Alertes de severite 19 a 25
-- ============================================================
DECLARE @sev INT = 19;
DECLARE @name NVARCHAR(100);
DECLARE @msg NVARCHAR(500);

WHILE @sev <= 25
BEGIN
    SET @name = N'DBA - Severite ' + CAST(@sev AS NVARCHAR(2));
    SET @msg  = N'Erreur SQL Server de severite ' + CAST(@sev AS NVARCHAR(2)) + N' detectee.';

    -- Suppression si existe
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @name)
        EXEC msdb.dbo.sp_delete_alert @name = @name;

    -- Creation
    EXEC msdb.dbo.sp_add_alert 
        @name                        = @name,
        @severity                    = @sev,
        @delay_between_responses     = 60,
        @notification_message        = @msg,
        @include_event_description_in = 1;

    -- Notification vers l'operateur
    EXEC msdb.dbo.sp_add_notification
        @alert_name         = @name,
        @operator_name      = N'DBA-Ops',
        @notification_method = 1;   -- 1 = email

    PRINT 'Alerte creee : ' + @name;
    SET @sev += 1;
END
GO

-- ============================================================
-- ETAPE 2 : Alertes sur erreurs specifiques (I/O + log plein)
-- ============================================================
DECLARE @errNumber INT;
DECLARE @errName NVARCHAR(100);
DECLARE @errMsg NVARCHAR(500);

DECLARE err_cursor CURSOR FOR
    SELECT 823, N'DBA - Erreur 823 (I/O physique)'
    UNION ALL SELECT 824, N'DBA - Erreur 824 (I/O logique)'
    UNION ALL SELECT 825, N'DBA - Erreur 825 (I/O lecture retry)'
    UNION ALL SELECT 9002, N'DBA - Erreur 9002 (Transaction log plein)';

OPEN err_cursor;
FETCH NEXT FROM err_cursor INTO @errNumber, @errName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @errMsg = N'Erreur SQL Server ' + CAST(@errNumber AS NVARCHAR(10)) + N' detectee.';

    IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @errName)
        EXEC msdb.dbo.sp_delete_alert @name = @errName;

    EXEC msdb.dbo.sp_add_alert
        @name                        = @errName,
        @message_id                  = @errNumber,
        @delay_between_responses     = 60,
        @notification_message        = @errMsg,
        @include_event_description_in = 1;

    EXEC msdb.dbo.sp_add_notification
        @alert_name          = @errName,
        @operator_name       = N'DBA-Ops',
        @notification_method = 1;

    PRINT 'Alerte creee : ' + @errName;
    FETCH NEXT FROM err_cursor INTO @errNumber, @errName;
END
CLOSE err_cursor;
DEALLOCATE err_cursor;
GO

-- ============================================================
-- ETAPE 3 : Verification
-- ============================================================
PRINT '--- Alertes creees ---';
SELECT name AS AlertName, severity, message_id, enabled, delay_between_responses
FROM msdb.dbo.sysalerts
WHERE name LIKE 'DBA - %'
ORDER BY name;
GO

PRINT '7.3.0 - Alertes SQL Server creees avec succes.';
GO