#!/bin/bash

# ==============================================================================
# NOM DU SCRIPT : 00.setup_complet_several_admin_ansible_V7.sh
# VERSION        : 7.1 (Post-Clone GitHub & Droits Collaboratifs Multi-Admin)
# AUTHOR         : Optimedit
# ==============================================================================
# 📋 SYNOPSIS DES TÂCHES ASSURÉES PAR CE SCRIPT :
#
# 1. MANAGEMENT DU LOGGING & UMASK COLLABORATIF
#    - Redirection de la sortie vers 00.setup_complet_several_admin_ansible_V7.log.
#    - Fixation de l'umask système à 0002 (droits d'écriture groupe par défaut).
#
# 2. PROVISIONNING DES DÉPENDANCES (APT)
#    - Installation silencieuse de : sudo, krb5-user, git, ansible-core, 
#      ansible, vim, net-tools, tree, dos2unix et curl.
#
# 3. GESTION DES ACCÈS & COMPTES COLLABORATIFS
#    - Création du groupe de sécurité de l'infrastructure : gr_ansible_admins.
#    - Création des comptes admin_ansible, shamil, sakina et driss avec mot de 
#      passe sécurisé et raccordement aux groupes 'sudo' et 'gr_ansible_admins'.
#    - Injection de l'identité ANSIBLE_NET_USER personnalisée dans chaque .bashrc.
#
# 4. PRIVILÈGES ELEVÉS SANS MOT DE PASSE (SUDOERS)
#    - Déploiement du fichier d'élévation /etc/sudoers.d/90-ansible-collaborative 
#      permettant au groupe d'exécuter sudo sans interruption (requis par Ansible).
#
# 5. CONFIGURATION IDENTITY GIT GLOBALE (PROPRE À CHAQUE USER)
#    - Initialisation de 'user.name' (avec majuscule) et 'user.email' locaux 
#      dans l'espace /home de chaque administrateur pour la traçabilité Git.
#
# 6. AUTOMATISATION DES CLÉS SSH DÉDIÉES GITHUB
#    - Génération d'une clé moderne id_ed25519_username par administrateur.
#    - Écriture du fichier 'config' SSH pour router et forcer l'usage de cette 
#      clé vers github.com. Verrouillage des permissions strictes (700/600).
#
# 7. INTERCONNEXION WINRM VIA CLIENT KERBEROS
#    - Génération du fichier /etc/krb5.conf pré-configuré pour le domaine 
#      OPTIMEDIT.EU et ciblant le contrôleur de domaine OPT-DC02.
#
# 8. VERROUILLAGE & PERSISTANCE DES DROITS DE GROUPE (SGID)
#    - Alignement du groupe gr_ansible_admins sur le dossier cloné /projets_optimedit.
#    - Forçage du bit SGID (g+s) sur les dossiers pour l'héritage futur du groupe.
#    - Application récursive des droits d'écriture et d'exécution des scripts .sh.
# ==============================================================================

# --- CONFIGURATION DU LOGGING ---
LOG_FILE="${0%.sh}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "------------------------------------------------------------"
echo "🕒 Début de l'installation : $(date)"
echo "------------------------------------------------------------"

# --- CONFIGURATION DE L'UMASK SYSTEME ---
umask 0002

# --- 1. CONFIGURATION DES VARIABLES ---
DOMAIN="OPTIMEDIT.EU"
DOMAIN_LOWER="optimedit.eu"
DC_SERVER="OPT-DC02.optimedit.eu"
BASE_DIR="/projets_optimedit"   # <--- CORRIGÉ : Parfaitement aligné au pluriel
ADMIN_GROUP="gr_ansible_admins"
ANSIBLE_PASS="Dr/*-101977"

# Couleurs pour l'affichage terminal interactif
BLUE_BOLD="\e[1;34m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
NC="\e[0m" # No Color

# Matrice complète des identités d'administration de l'infrastructure
ADMIN_USERS_LIST=("admin_ansible" "shamil" "sakina" "driss")

# Vérification que le script est exécuté en root/sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Erreur : Ce script doit être exécuté en tant que root ou avec sudo.${NC}"
    exit 1
fi

echo "🚀 [START] Début de la configuration du Master Ansible Multi-Admin..."

# --- 2. INSTALLATION DES DÉPENDANCES ---
export DEBIAN_FRONTEND=noninteractive

echo "📦 [APT] Installation des paquets nécessaires..."
apt update && apt install -y sudo krb5-user git ansible-core ansible vim net-tools tree dos2unix curl

# --- 3. SÉCURITÉ LINUX : UTILISATEURS ET GROUPES ---
echo "👥 [USER] Configuration des comptes locaux, .bashrc et permissions..."
groupadd -f $ADMIN_GROUP

for USER in "${ADMIN_USERS_LIST[@]}"; do
    if id "$USER" &>/dev/null; then
        echo "   [INFO] L'utilisateur local $USER existe déjà."
    else
        useradd -m -s /bin/bash "$USER"
        echo "$USER:$ANSIBLE_PASS" | chpasswd
        echo "   [OK] Utilisateur local $USER créé."
    fi
    
    # Rapprochement de l'utilisateur avec les privilèges sudo et le groupe d'administration
    usermod -aG sudo,${ADMIN_GROUP} "$USER"

    # INJECTION DU BASHRC : Liaison dynamique de la session Linux pour le ciblage Kerberos
    BASHRC_FILE="/home/$USER/.bashrc"
    if [ -f "$BASHRC_FILE" ]; then
        if ! grep -q "ANSIBLE_NET_USER" "$BASHRC_FILE"; then
            echo -e "\n# Configuration de l'identité utilisateur pour l'orchestration Ansible" >> "$BASHRC_FILE"
            echo "export ANSIBLE_NET_USER=\"$USER\"" >> "$BASHRC_FILE"
            chown $USER:$USER "$BASHRC_FILE"
            echo "   [OK] Variable ANSIBLE_NET_USER='$USER' injectée dans le .bashrc de $USER."
        fi
    fi

    # Configuration automatique de l'identité Git globale locale pour l'opérateur
    echo "   [GIT] Configuration de l'identité Git globale pour '$USER'..."
    su - "$USER" -c "git config --global user.name '${USER^}'"
    su - "$USER" -c "git config --global user.email '${USER}@$DOMAIN_LOWER'"

    # Génération de la clé SSH personnalisée dédiée à GitHub
    SSH_DIR="/home/$USER/.ssh"
    KEY_FILE="${SSH_DIR}/id_ed25519_${USER}"
    
    mkdir -p "$SSH_DIR"
    if [ ! -f "$KEY_FILE" ]; then
        # Génération non interactive (User en commentaire et mot de passe par défaut en Passphrase)
        ssh-keygen -t ed25519 -C "master-03-ansible-${USER}" -f "$KEY_FILE" -N "$ANSIBLE_PASS" -q
        echo "   [SSH] Clé SSH personnalisée générée pour $USER : $KEY_FILE"
    fi

    # Routage du fichier config SSH pour forcer l'usage de cette clé vers GitHub
    SSH_CONFIG="${SSH_DIR}/config"
    if [ -f "$SSH_CONFIG" ]; then
        if ! grep -q "IdentityFile $KEY_FILE" "$SSH_CONFIG"; then
            echo -e "\nHost github.com\n  IdentityFile $KEY_FILE" >> "$SSH_CONFIG"
        fi
    else
        echo -e "Host github.com\n  IdentityFile $KEY_FILE" > "$SSH_CONFIG"
    fi

    # Application stricte des permissions d'accès SSH requises par Linux
    chown -R "${USER}:${USER}" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "${SSH_DIR}/"*
    echo "   [OK] Environnement SSH et Git configuré pour $USER."
done

# Configuration du fichier Sudoers pour permettre l'élévation sans mot de passe pour le groupe d'administration
echo "%$ADMIN_GROUP ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ansible-collaborative
chmod 0440 /etc/sudoers.d/90-ansible-collaborative
echo "   [OK] Élévation Sudo sécurisée configurée pour le groupe $ADMIN_GROUP."

# --- 4. CONFIGURATION DU SOUS-SYSTÈME SSH ---
echo "🔑 [SSH] Autorisation de l'accès SSH via authentification par mot de passe..."
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
echo "   [OK] Service SSH reconfiguré et redémarré."

# --- 5. CONFIGURATION DE LA COUCHE D'AUTHENTIFICATION KERBEROS ---
echo "🔑 [KRB5] Configuration du fichier /etc/krb5.conf..."
cat <<EOT > /etc/krb5.conf
[libdefaults]
    default_realm = $DOMAIN
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    forwardable = true
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    $DOMAIN = {
        kdc = $DC_SERVER
        admin_server = $DC_SERVER
    }

[domain_realm]
    .$DOMAIN_LOWER = $DOMAIN
    $DOMAIN_LOWER = $DOMAIN
EOT
echo "   [OK] Fichier Kerberos /etc/krb5.conf initialisé."

# --- 6. AJUSTEMENT DES DROITS COLLABORATIFS CRITIQUES (CORRECTION BLOCAGE MULTI-ADMIN) ---
echo "🔐 [CHMOD] Application des privilèges et persistance du contexte de groupe (SGID)..."

if [ -d "$BASE_DIR" ]; then
    # 1. Alignement récursif de la propriété du dossier racine vers l'admin principal et le groupe
    chown -R admin_ansible:$ADMIN_GROUP $BASE_DIR

    # 2. Permissions initiales (Lecture/Écriture/Traversée pour Propriétaire et Groupe)
    chmod -R 775 $BASE_DIR

    # 3. Forçage du bit SGID (g+s) de manière récursive sur tous les répertoires présents et futurs
    find $BASE_DIR -type d -exec chmod g+s {} +

    # 4. Ajustement des droits d'écriture explicites pour le groupe (Prévient les masques umask restrictifs)
    find $BASE_DIR -type d -exec chmod g+rwX {} +
    find $BASE_DIR -type f -exec chmod g+rw {} +

    # 5. S'assurer que tous les scripts shell (.sh) présents ou futurs sont exécutables par le groupe
    find $BASE_DIR -name "*.sh" -exec chmod ug+x {} +
    echo -e "${GREEN}✅ [OK] Topologie des droits d'accès sécurisée, partagée et scripts configurés à l'exécution.${NC}"
else
    echo -e "${RED}❌ Erreur : Le dossier racine $BASE_DIR n'existe pas. Veuillez d'abord cloner votre dépôt Git.${NC}"
fi

# --- 7. TEST DE VALIDATION DES DROITS "s" (Héritage) ---
echo "🧪 [TEST] Vérification de l'héritage des droits (SGID)..."
if [ -d "$BASE_DIR" ]; then
    TEST_FILE="$BASE_DIR/test_rights.tmp"
    sudo -u admin_ansible touch "$TEST_FILE"

    GROUP_OWNER=$(stat -c "%G" "$TEST_FILE")
    if [ "$GROUP_OWNER" == "$ADMIN_GROUP" ]; then
        echo -e "${GREEN}   [SUCCESS] L'héritage du groupe (Sticky Bit/SGID) est fonctionnel.${NC}"
        rm "$TEST_FILE"
    else
        echo -e "${RED}   [ERROR] L'héritage du groupe a échoué. Propriétaire actuel : $GROUP_OWNER${NC}"
    fi
fi

echo "------------------------------------------------------------"
echo -e "${GREEN}✅ CONFIGURATION LINUX ENRICHIE ET TERMINÉE AVEC SUCCÈS !${NC}"
echo "------------------------------------------------------------"
