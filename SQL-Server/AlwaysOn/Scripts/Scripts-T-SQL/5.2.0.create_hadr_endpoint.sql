-- 5.2.0.create_hadr_endpoint.sql
-- Objet  : Creer l'endpoint Always On et autoriser le compte de service a s'y connecter
-- Noeuds : SQLS01 + SQLS02 (executer sur chaque instance)

--- *****************************************************************************************************
--- ***   Pour la creation de des endpoint utiliser le script ps1 "5.2.0.create_hadr_endpoint.ps1"   ***
--- *****************************************************************************************************


CREATE ENDPOINT [Hadr_endpoint]
STATE = STARTED
AS TCP (LISTENER_PORT = 5022)
FOR DATABASE_MIRRORING (
    ROLE = ALL,
    AUTHENTICATION = WINDOWS NEGOTIATE,
    ENCRYPTION = REQUIRED ALGORITHM AES
);
GO

GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [optimedit\SVC_SQL_Engine];
GO
