-- 5.5.0.create_ag_listener.sql
-- Objet  : Creer le Listener SQL-AG-LSTNR (IP dediee)
-- Noeud  : SQLS01 (Primary)

--- *******************************************************************************************
--- *** Pour la creation de Listener utiliser le script ps1 "5.5.0.create_ag_listener.ps1" ***
--- *******************************************************************************************


ALTER AVAILABILITY GROUP [AG-OPTIMEDIT]
ADD LISTENER 'SQL-AG-LSTNR'
(
    WITH IP (('192.168.1.250','255.255.255.0')),
    PORT = 1433
);
GO
