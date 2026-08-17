
# Si la duré de vie de certificat est défini plus grand que celle défini dans le CA, ce dernier va brider la durée de certificat
# Ex: si on génère un certificat avec un modèle défini la vie de certificat pour 3 ans et que la vie de certificat et paramétré pour 2 ans c'est
# la valeur de 2 ans qui sera donnée au certificat généré.


:: Configurer la validité maximale globale de la CA sur 3 ans
certutil -setreg CA\ValidityPeriod "Years"
certutil -setreg CA\ValidityPeriodUnits 3

:: Redémarrer le service Active Directory Certificate Services pour appliquer
net stop certsvc
net start certsvc


# Vérification de la nouvelle conf
certutil -getreg CA\ValidityPeriodUnits




Microsoft Windows [version 10.0.20348.587]
(c) Microsoft Corporation. Tous droits réservés.

C:\Users\Administrateur>certutil -setreg CA\ValidityPeriod "Years"
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\Optimedit-CA2\ValidityPeriod:

Ancienne valeur :
  ValidityPeriod REG_SZ = Years

Nouvelle valeur :
  ValidityPeriod REG_SZ = Years
CertUtil: -setreg La commande s’est terminée correctement.
Le service CertSvc devra peut-être être redémarré afin que les changements
prennent effet.

C:\Users\Administrateur>certutil -setreg CA\ValidityPeriodUnits 3
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\Optimedit-CA2\ValidityPeriodUnits:

Ancienne valeur :
  ValidityPeriodUnits REG_DWORD = 2

Nouvelle valeur :
  ValidityPeriodUnits REG_DWORD = 3
CertUtil: -setreg La commande s’est terminée correctement.
Le service CertSvc devra peut-être être redémarré afin que les changements
prennent effet.

C:\Users\Administrateur>net stop certsvc
Le service Services de certificats Active Directory s’arrête.
Le service Services de certificats Active Directory a été arrêté.


C:\Users\Administrateur>net start certsvc
Le service Services de certificats Active Directory démarre.
Le service Services de certificats Active Directory a démarré.


C:\Users\Administrateur>


Microsoft Windows [version 10.0.20348.587]
(c) Microsoft Corporation. Tous droits réservés.

C:\Users\Administrateur>certutil -getreg CA\ValidityPeriodUnits
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\Optimedit-CA2\ValidityPeriodUnits:

  ValidityPeriodUnits REG_DWORD = 3
CertUtil: -getreg La commande s’est terminée correctement.

C:\Users\Administrateur>