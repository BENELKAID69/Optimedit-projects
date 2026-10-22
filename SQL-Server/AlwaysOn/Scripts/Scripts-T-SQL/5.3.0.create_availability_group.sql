-- 5.3.0.create_availability_group.sql
-- Objet  : Creer l'Availability Group AG-OPTIMEDIT (seeding automatique)
-- Noeud  : SQLS01 (Primary)

--- *******************************************************************************************
--- *** Pour la creation de AG utiliser le script ps1 "5.3.0.create_availability_group.ps1" ***
--- *******************************************************************************************


CREATE AVAILABILITY GROUP [AG-OPTIMEDIT]
FOR REPLICA ON
N'SQLS01' WITH (
    ENDPOINT_URL = 'TCP://192.168.1.251:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = AUTOMATIC,
    SEEDING_MODE = AUTOMATIC
),
N'SQLS02' WITH (
    ENDPOINT_URL = 'TCP://192.168.1.252:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = AUTOMATIC,
    SEEDING_MODE = AUTOMATIC
);
GO
