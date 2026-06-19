#!/bin/bash
# ==============================================================================
# NOM DU SCRIPT : 00.setup_complet_several_admin_ansible_V7.3.sh
# VERSION        : 7.3 (Intégration Libkrb5-Dev & Fix Pip Compil Kerberos)
# AUTHOR         : Optimedit
# ==============================================================================
# 📋 SYNOPSIS DES TÂCHES ASSURÉES PAR CE SCRIPT :
#
# 1. MANAGEMENT DU LOGGING & UMASK COLLABORATIF
#    - Redirection de la sortie vers le fichier .log associé.
#    - Fixation de l'umask système à 0002 (droits d'écriture groupe par défaut).
#
# 2. PROVISIONNING DES DÉPENDANCES (APT)
#    - Nettoyage conditionnel des paquets APT Ansible.
#    - Installation silencieuse des prérequis systèmes, Python3 et libkrb5-dev.
#    - Installation forcée globale via PIP d'ansible-core 2.14.18.
#
# 3. PRÉREQUIS POUR L'ORCHESTRATION WINDOWS (WinRM & GALAXY)
#    - Installation globale forcée de pywinrm[kerberos] (compilée via libkrb5-dev).
#    - Déploiement forcé de la collection 'ansible.windows' dans le dossier partagé.
#
# 4. GESTION DES ACCÈS & COMPTES COLLABORATIFS
#    - Création du groupe de sécurité de l'infrastructure : gr_ansible_admins.
#    - Création des comptes admin_ansible, shamil, sakina et driss avec mot de
#      passe sécurisé et raccordement aux groupes 'sudo' et 'gr_ansible_admins'.
#    - Injection de l'identité ANSIBLE_NET_USER personnalisée dans chaque .bashrc.
#
# 5. PRIVILÈGES ELEVÉS SANS MOT DE PASSE (SUDOERS)
#    - Déploiement du fichier d'élévation /etc/sudoers.d/90-ansible-collaborative.
#
# 6. CONFIGURATION IDENTITY GIT GLOBALE (PROPRE À CHAQUE USER)
#    - Initialisation de 'user.name' et 'user.email' locaux pour chaque admin.
#
# 7. AUTOMATISATION DES CLÉS SSH DÉDIÉES GITHUB
#    - Génération d'une clé moderne id_ed25519_username par administrateur.
#    - Configuration du fichier config SSH pour forcer l'usage de cette clé.
#
# 8. INTERCONNEXION WINRM VIA CLIENT KERBEROS
#    - Génération du fichier /etc/krb5.conf pré-configuré pour OPTIMEDIT.EU.
#
# 9. CREATION, VERROUILLAGE & PERSISTANCE DES DROITS DE GROUPE (SGID)
#    - Création automatique du dossier racine /projets_optimedit si absent.
#    - Alignement de la propriété sur admin_ansible:gr_ansible_admins.
#    - Forçage du bit SGID (2775) pour l'héritage collaboratif.
#    - Déclaration de safe.directory pour contrer les blocages Git multi-admin.
#
# 10. CLONAGE AUTOMATISÉ OU SYNCHRONISATION DU RÉFÉRENTIEL GIT
#    - Détection dynamique et clonage de l'infrastructure sous l'identité pivot.
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
DC_SERVER="DC03.optimedit.eu"
BASE_DIR="/projets_optimedit"
ADMIN_GROUP="gr_ansible_admins"
ANSIBLE_PASS="Dr/*-101977"
REPO_URL="https://github.com/BENELKAID69/infra_iis_ansible.git"
COLLECTIONS_GLOBAL_PATH="/usr/share/ansible/collections"

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

echo -e "${BLUE_BOLD}🚀 [START] Début de la configuration du Master Ansible Multi-Admin...${NC}"

# --- 2. INSTALLATION DES DÉPENDANCES ET VERSION CONFIGURÉE D'ANSIBLE ---
export DEBIAN_FRONTEND=noninteractive

# Vérification de la présence de reliquats APT (ansible ou ansible-core)
if dpkg -l | grep -E '^ii  ansible(_|-core)? ' &>/dev/null; then
    echo "🧹 [CLEAN] Suppression d'éventuels reliquats Ansible d'APT..."
    apt remove -y ansible ansible-core 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
else
    echo "🧹 [CLEAN] Aucun reliquat Ansible (APT) détecté. Poursuite du script..."
fi

echo "📦 [APT] Installation des paquets de base et des en-têtes de dev (Kerberos/Python)..."
# Inclusions majeures : libkrb5-dev requis pour compiler pywinrm[kerberos] sur les nouvelles versions de pip
apt update && apt install -y sudo krb5-user libkrb5-dev git python3-pip python3-full vim net-tools tree dos2unix curl

echo "🐍 [PIP] Configuration et installation forcée d'ansible-core version 2.14.18..."
pip3 install --upgrade pip --break-system-packages
pip3 install ansible-core==2.14.18 --break-system-packages

# --- 3. PRÉREQUIS POUR L'ORCHESTRATION WINDOWS (WinRM & GALAXY) ---
echo -e "${YELLOW}📦 [WINDOWS] Installation des prérequis pour l'administration Windows...${NC}"

echo "   [PIP] Installation de pywinrm[kerberos]..."
# Utilisation de --ignore-installed pour forcer la reconstruction propre avec libkrb5-dev
if pip3 install pywinrm[kerberos] --break-system-packages --ignore-installed >> "$LOG_FILE" 2>&1; then
    echo -e "   ${GREEN}[OK] Bibliothèques Python WinRM/Kerberos prêtes.${NC}"
else
    echo -e "   ${RED}[ERREUR] Échec de l'installation de pywinrm via Pip. Vérifie le log.${NC}"
    exit 1
fi

echo "   [DIR] Initialisation du dossier des collections globales..."
mkdir -p "$COLLECTIONS_GLOBAL_PATH"

echo "   [GALAXY] Téléchargement et installation globale de 'ansible.windows'..."
if ansible-galaxy collection install ansible.windows -p "$COLLECTIONS_GLOBAL_PATH" --force > /dev/null 2>&1; then
    echo -e "   ${GREEN}[OK] Collection 'ansible.windows' déployée globalement.${NC}"
else
    echo -e "   ${RED}[ERREUR] Échec du déploiement de la collection Ansible Windows via Galaxy.${NC}"
    exit 1
fi

# --- 4. SÉCURITÉ LINUX : UTILISATEURS ET GROUPES ---
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
        ssh-keygen -t ed25519 -C "master-ansible-${USER}" -f "$KEY_FILE" -N "$ANSIBLE_PASS" -q
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
    chmod 600 "${SSH_DIR}/"* 2>/dev/null || true
    echo "   [OK] Environnement SSH et Git configuré pour $USER."
done

# Configuration du fichier Sudoers pour permettre l'élévation sans mot de passe pour le groupe d'administration
echo "%$ADMIN_GROUP ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ansible-collaborative
chmod 0440 /etc/sudoers.d/90-ansible-collaborative
echo "   [OK] Élévation Sudo sécurisée configurée pour le groupe $ADMIN_GROUP."

# --- 5. CONFIGURATION DU SOUS-SYSTÈME SSH ---
echo "🔑 [SSH] Autorisation de l'accès SSH via authentification par mot de passe..."
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
echo "   [OK] Service SSH reconfiguré et redémarré."

# --- 6. CONFIGURATION DE LA COUCHE D'AUTHENTIFICATION KERBEROS ---
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

# --- 7. CRÉATION DU DOSSIER RACINE ET AJUSTEMENT DES DROITS COLLABORATIFS (SGID) ---
echo "🔐 [CHMOD] Application des privilèges et persistance du contexte de groupe (SGID)..."

# Création dynamique du dossier racine si manquant pour assurer le fonctionnement au premier coup
if [ ! -d "$BASE_DIR" ]; then
    echo "   [INFO] Le dossier racine $BASE_DIR n'existe pas. Création automatisée..."
    mkdir -p "$BASE_DIR"
fi

# 1. Alignement récursif de la propriété du dossier racine vers l'admin principal et le groupe
chown -R admin_ansible:$ADMIN_GROUP $BASE_DIR

# 2. Permissions initiales (Lecture/Écriture/Traversée pour Propriétaire et Groupe - Mode 2775)
chmod -R 2775 $BASE_DIR

# 3. Forçage du bit SGID (g+s) de manière récursive sur tous les répertoires présents et futurs
find $BASE_DIR -type d -exec chmod g+s {} +

# 4. Ajustement des droits d'écriture explicites pour le groupe (Prévient les masques umask restrictifs)
find $BASE_DIR -type d -exec chmod g+rwX {} +
find $BASE_DIR -type f -exec chmod g+rw {} +

# 5. S'assurer que tous les scripts shell (.sh) présents ou futurs sont exécutables par le groupe
find $BASE_DIR -name "*.sh" -exec chmod ug+x {} +

# 6. Sécurisation fine globale pour Git (Autorise tous les membres du groupe d'administration à interagir)
git config --global --add safe.directory "$BASE_DIR"

echo -e "   ${GREEN}[OK] Topologie des droits d'accès sécurisée, partagée et dossiers initialisés.${NC}"

# --- 8. CLONAGE AUTOMATISÉ OU SYNCHRONISATION DU RÉFÉRENTIEL GIT ---
echo -e "${YELLOW}📥 [GIT] Synchronisation du référentiel d'infrastructure...${NC}"

if [ -d "$BASE_DIR/.git" ]; then
    echo "   [INFO] Dépôt déjà existant dans $BASE_DIR. Exécution d'une mise à jour (git pull)..."
    if su - admin_ansible -c "cd $BASE_DIR && git pull" > /dev/null 2>&1; then
        echo -e "   ${GREEN}[OK] Référentiel Git synchronisé avec succès.${NC}"
    else
        echo -e "   ${YELLOW}[⚠️ WARNING] Le 'git pull' a échoué. Vérifie la connectivité Internet.${NC}"
    fi
else
    echo "   [GIT] Clonage initial du dépôt d'infrastructure dans $BASE_DIR..."
    if su - admin_ansible -c "git clone $REPO_URL $BASE_DIR" > /dev/null 2>&1; then
        echo -e "   ${GREEN}[OK] Référentiel cloné avec succès dans $BASE_DIR.${NC}"
    else
        echo -e "   ${RED}[ERREUR] Échec du clonage Git. Vérifie l'accessibilité de l'URL ou du Proxy.${NC}"
        exit 1
    fi
fi

# Réapplication rapide de sécurité sur les éléments clonés
chmod -R 2775 $BASE_DIR
chown -R admin_ansible:$ADMIN_GROUP $BASE_DIR

# --- 9. TEST DE VALIDATION DES DROITS "s" (Héritage) ---
echo "🧪 [TEST] Vérification de l'héritage des droits (SGID)..."
TEST_FILE="$BASE_DIR/test_rights.tmp"
sudo -u admin_ansible touch "$TEST_FILE"

GROUP_OWNER=$(stat -c "%G" "$TEST_FILE")
if [ "$GROUP_OWNER" == "$ADMIN_GROUP" ]; then
    echo -e "${GREEN}   [SUCCESS] L'héritage du groupe (Sticky Bit/SGID) est fonctionnel.${NC}"
    rm "$TEST_FILE"
else
    echo -e "${RED}   [ERROR] L'héritage du groupe a échoué. Propriétaire actuel : $GROUP_OWNER${NC}"
fi

echo "------------------------------------------------------------"
echo -e "${GREEN}✅ CONFIGURATION LINUX ENRICHIE ET TERMINÉE AVEC SUCCÈS !${NC}"
echo "------------------------------------------------------------"
