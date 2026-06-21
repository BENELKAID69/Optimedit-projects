#!/bin/bash

# ==============================================================================
# NOM DU SCRIPT : add_new_ansible_admin_V3.sh
# VERSION        : 3.1 (Correction BASE_DIR -> /projets_optimedit)
# AUTHOR         : Optimedit
# DESCRIPTION    : Ajout sécurisé et standardisé d'un nouvel administrateur
#                  sur le Master Ansible avec configuration Git, SSH et Sudo.
# ==============================================================================

# Couleurs pour l'affichage terminal
BLUE_BOLD="\e[1;34m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
NC="\e[0m" # No Color

# Vérification des privilèges Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Erreur : Ce script doit être exécuté en tant que root ou avec sudo.${NC}"
    exit 1
fi

# --- CONFIGURATION DES VARIABLES SYSTEME (Alignées sur le Master) ---
DOMAIN="OPTIMEDIT.EU"
DOMAIN_LOWER="optimedit.eu"
BASE_DIR="/projets_optimedit"   # <--- CORRIGÉ : Avec le "s" pour correspondre au Master
ADMIN_GROUP="gr_ansible_admins"
ANSIBLE_PASS="Dr/*-101977"

echo -e "${BLUE_BOLD}============================================================${NC}"
echo -e "${BLUE_BOLD}👤 AJOUT D'UN NOUVEL ADMINISTRATEUR ANSIBLE (Optimedit)${NC}"
echo -e "${BLUE_BOLD}============================================================${NC}"

# Demande interactive du nom du nouvel utilisateur
echo -e "${BLUE_BOLD}👉 Entrez le nom du nouvel utilisateur à créer (ex: myriam) :${NC}"
read -r NEW_USER

# Validation de la saisie
if [ -z "$NEW_USER" ]; then
    echo -e "${RED}❌ Erreur : Le nom d'utilisateur ne peut pas être vide.${NC}"
    exit 1
fi

# Convertir en minuscules pour éviter les erreurs Linux
NEW_USER=$(echo "$NEW_USER" | tr '[:upper:]' '[:lower:]')

# 1. CRÉATION DU COMPTE LINUX
if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}⚠️ [INFO] L'utilisateur local '$NEW_USER' existe déjà sur le système.${NC}"
else
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$ANSIBLE_PASS" | chpasswd
    echo -e "${GREEN}   [OK] Utilisateur local '$NEW_USER' créé avec succès.${NC}"
fi

# 2. RACCORDEMENT AUX GROUPES (Sudo et Administration collaborative)
usermod -aG sudo,${ADMIN_GROUP} "$NEW_USER"
echo -e "${GREEN}   [OK] Utilisateur ajouté aux groupes 'sudo' et '$ADMIN_GROUP'.${NC}"

# 3. INJECTION DE LA VARIABLE D'IDENTITÉ ANSIBLE DANS LE .BASHRC
BASHRC_FILE="/home/$NEW_USER/.bashrc"
if [ -f "$BASHRC_FILE" ]; then
    if ! grep -q "ANSIBLE_NET_USER" "$BASHRC_FILE"; then
        echo -e "\n# Configuration de l'identité utilisateur pour l'orchestration Ansible" >> "$BASHRC_FILE"
        echo "export ANSIBLE_NET_USER=\"$NEW_USER\"" >> "$BASHRC_FILE"
        chown $NEW_USER:$NEW_USER "$BASHRC_FILE"
        echo -e "${GREEN}   [OK] Variable ANSIBLE_NET_USER='$NEW_USER' injectée dans son .bashrc.${NC}"
    fi
fi

# 4. CONFIGURATION DE L'IDENTITÉ GIT GLOBALE PROPRE À L'OPÉRATEUR
echo "   [GIT] Configuration de l'identité Git globale..."
su - "$NEW_USER" -c "git config --global user.name '${NEW_USER^}'"
su - "$NEW_USER" -c "git config --global user.email '${NEW_USER}@$DOMAIN_LOWER'"

# 5. GÉNÉRATION DE LA CLÉ SSH DÉDIÉE GITHUB
SSH_DIR="/home/$NEW_USER/.ssh"
KEY_FILE="${SSH_DIR}/id_ed25519_${NEW_USER}"

mkdir -p "$SSH_DIR"
if [ ! -f "$KEY_FILE" ]; then
    # Génération non interactive (Passphrase par défaut)
    ssh-keygen -t ed25519 -C "master-03-ansible-${NEW_USER}" -f "$KEY_FILE" -N "$ANSIBLE_PASS" -q
    echo -e "${GREEN}   [SSH] Clé SSH personnalisée générée : $KEY_FILE${NC}"
else
    echo -e "${YELLOW}   [INFO] Une clé SSH existe déjà à cet emplacement.${NC}"
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
chown -R "${NEW_USER}:${NEW_USER}" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "${SSH_DIR}/"*
echo -e "${GREEN}   [OK] Environnement SSH et Git configuré pour $NEW_USER.${NC}"

# 6. MISE À TRÈS JOUR DES DROITS SUR LE RÉPERTOIRE PROJET EXISTANT
echo "🔐 [CHMOD] Réapplication des privilèges collaboratifs sur le dossier projet..."
if [ -d "$BASE_DIR" ]; then
    chown -R admin_ansible:$ADMIN_GROUP $BASE_DIR
    chmod -R 775 $BASE_DIR
    find $BASE_DIR -type d -exec chmod g+s {} +
    find $BASE_DIR -type d -exec chmod g+rwX {} +
    find $BASE_DIR -type f -exec chmod g+rw {} +
    find $BASE_DIR -name "*.sh" -exec chmod ug+x {} +
    echo -e "${GREEN}   [OK] Droits collaboratifs ré-harmonisés sur $BASE_DIR.${NC}"
else
    echo -e "${YELLOW}⚠️ [WARN] Le dossier racine $BASE_DIR n'existe pas encore. Les droits seront appliqués lors du setup initial.${NC}"
fi

echo -e "${BLUE_BOLD}------------------------------------------------------------${NC}"
echo -e "🎉 ${GREEN}L'administrateur '$NEW_USER' a été configuré avec succès !${NC}"
echo -e "${BLUE_BOLD}------------------------------------------------------------${NC}"
echo -e "${YELLOW}📋 ÉTAPE SUIVANTE SUR GITHUB :${NC}"
echo -e "Demandez à l'utilisateur de copier sa clé publique ci-dessous et de l'ajouter à son compte GitHub :"
echo -e "${CYAN}"
cat "${KEY_FILE}.pub"
echo -e "${NC}"
