@echo off
setlocal enabledelayedexpansion
chcp 1252 >nul

:: =============================================================================
:: AUTHOR  : Driss BENELKAID - optimedit.eu
:: DATE    : 08/06/2026
:: VERSION : 1.1 (Production - Avec libellés de suivi Name)
:: DESC    : Mappage reseau universel base sur les droits d'acces.
:: =============================================================================

:: =============================================================================
:: 1. CONFIGURATION - INFRASTRUCTURE CIBLE
:: =============================================================================
set "ServerName=opt-fs02"
set "FileServer=\\%ServerName%"
set "PathToTest=%FileServer%\OPT_Commun"
set "LogFile=%TEMP%\LogonDrives_OptimedIt.log"

:: Nettoyage du vieux log pour eviter les conflits d'encodage
if exist "%LogFile%" del /f /q "%LogFile%"

:: Commande de log avec heure reelle (PowerShell)
set "WriteLog=powershell -Command "$now = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'; Out-File -FilePath '%LogFile%' -Append -InputObject \"[$now] "

:: =============================================================================
:: 2. INITIALISATION ET ATTENTE RESEAU
:: =============================================================================
%WriteLog% --- DEBUT DE SESSION : %username% ---\""
%WriteLog% Execution script netlogon : OptLogonScript.bat\""
%WriteLog% Stabilisation reseau (20s)...\"""

:: On attend reellement 20 secondes
timeout /t 20 /nobreak >nul

set /a RetryCount=0
:WAIT_LOOP
if exist "%PathToTest%" goto NETWORK_READY
if %RetryCount% geq 10 goto NETWORK_FAILED
set /a RetryCount+=1
%WriteLog% ATTENTE : Serveur injoignable (Tentative %RetryCount%/10)\""
timeout /t 5 /nobreak >nul
goto :WAIT_LOOP

:NETWORK_FAILED
%WriteLog% FATAL : Reseau ou serveur injoignable apres 10 tentatives.\""
goto :END_LOG

:NETWORK_READY
:: =============================================================================
:: 3. NETTOYAGE ET MAPPAGE
:: =============================================================================
%WriteLog% Nettoyage des anciennes connexions reseau...\""
net use * /delete /y >nul 2>&1
timeout /t 2 /nobreak >nul

:: --- LISTE DES LECTEURS - NOMENCLATURE ET SERVICES OPT EXACTS ---
call :MapDrive K: "%FileServer%\OPT_Commun" "Commun"
call :MapDrive T: "%FileServer%\OPT_Direction" "Direction"
call :MapDrive M: "%FileServer%\OPT_Comptabilite" "Comptabilite"
call :MapDrive P: "%FileServer%\OPT_Paie" "Paie"
call :MapDrive R: "%FileServer%\OPT_RH" "RH"
call :MapDrive C: "%FileServer%\OPT_CE" "CE"
call :MapDrive I: "%FileServer%\OPT_IT" "IT"
call :MapDrive W: "%FileServer%\OPT_Production" "Production"
call :MapDrive F: "%FileServer%\OPT_Formation" "Formation"
call :MapDrive A: "%FileServer%\OPT_Achat" "Achat"
call :MapDrive Q: "%FileServer%\OPT_Commercial" "Commercial"
call :MapDrive L: "%FileServer%\OPT_Client" "Client"
call :MapDrive J: "%FileServer%\OPT_Juridique" "Juridique"
call :MapDrive B: "%FileServer%\OPT_Blog" "Blog"

:: --- Services programmes pour integration future (Commentes pour la performance) ---
call :MapDrive V: "%FileServer%\OPT_projets_optimedit\Dev" "Dev"
call :MapDrive N: "%FileServer%\OPT_Marketing" "Marketing"
call :MapDrive O: "%FileServer%\OPT_Logistique" "Logistique"
call :MapDrive X: "%FileServer%\OPT_RD" "RD"

:: =============================================================================
:: 4. FIN DU SCRIPT ET OUVERTURE LOG
:: =============================================================================
:END_LOG
%WriteLog% --- FIN DU SCRIPT POUR %username% ---\""

:: OUVERTURE DU LOG POUR VERIFICATION (A desactiver avant GPO)
start "" notepad "%LogFile%"

exit /b

:: =============================================================================
:: FONCTION DE MAPPAGE
:: =============================================================================
:MapDrive
set "DriveLtr=%~1"
set "DrivePath=%~2"
set "ServiceName=%~3"

if exist "%DrivePath%\*" (
    net use %DriveLtr% /delete /y >nul 2>&1
    net use %DriveLtr% "%DrivePath%" /persistent:no >nul 2>&1
    
    if exist %DriveLtr% (
        %WriteLog% SUCCES : Lecteur %DriveLtr% monte pour le service [%ServiceName%] sur %DrivePath%\""
    ) else (
        %WriteLog% ERREUR : Echec montage %DriveLtr% pour le service [%ServiceName%]\""
    )
) else (
    %WriteLog% INFO : Acces non autorise ou dossier inexistant pour le service [%ServiceName%]\""
)
goto :eof