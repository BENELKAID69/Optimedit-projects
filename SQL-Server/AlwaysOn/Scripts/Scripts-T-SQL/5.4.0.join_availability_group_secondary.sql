-- 5.4.0.join_availability_group_secondary.sql
-- Objet  : Rejoindre l'AG depuis le replica secondaire
-- Noeud  : SQLS02 (Secondary)

--- **************************************************************************************************
--- *** Pour la jonction au AG utiliser le script ps1 "5.4.0.join_availability_group_secondary.ps1" ***
--- ***************************************************************************************************

ALTER AVAILABILITY GROUP [AG-OPTIMEDIT] JOIN;
GO
ALTER AVAILABILITY GROUP [AG-OPTIMEDIT] GRANT CREATE ANY DATABASE;
GO
