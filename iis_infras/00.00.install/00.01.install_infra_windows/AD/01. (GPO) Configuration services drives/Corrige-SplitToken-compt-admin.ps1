# --------------------------------------------------------------------------------------------------
# NOTE TECHNIQUE :
# Activer EnableLinkedConnections pour forcer Windows à partager les lecteurs réseau entre le mode
# "Admin" et le mode "Utilisateur".
# Cela résout le problème de UAC-Mappage pour un utilisateur qui fait partie d'un groupe admin 
# et d'un groupe standard.
# --------------------------------------------------------------------------------------------------

# 01. soit en local par clé 
# ==================================================
$RegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$Name         = "EnableLinkedConnections"
$Value        = 1

# Vérification si le chemin existe, puis création/modification de la valeur
if (-not (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force
}

Set-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -Type DWord


# 02. soit par GPO (Registre) appliqué sur tous les serveur RDS
# =============================================================
<# 
Voici comment procéder dans votre console de gestion des stratégies de groupe (gpmc.msc) :
Configuration de la GPO pour le Registre

    Créez une nouvelle GPO (ou modifiez une GPO existante liée à vos serveurs/ordinateurs) nommée : SRV-Configuration-UAC-Mappage.

    Allez dans : Configuration ordinateur > Préférences > Paramètres Windows > Registre.

    Faites un clic droit > Nouveau > Élément Registre.

    Remplissez le formulaire comme suit :

        Action : Mettre à jour

        Ruche : HKEY_LOCAL_MACHINE

        Chemin de la clé : SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System

        Nom de la valeur : EnableLinkedConnections

        Type de valeur : REG_DWORD

        Données de la valeur : 1

#>