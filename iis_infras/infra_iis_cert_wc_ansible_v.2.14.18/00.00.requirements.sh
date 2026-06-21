#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/iis_infras/infra_iis_cert_wc_ansible_v.2.14.18/
# NOM DU SCRIPT : 00.00.requirements.sh
# CONFIGURATION : Installation double (Système + Local) des collections Ansible
#                 & Restauration des droits collaboratifs (SGID)
# AUTHOR        : Optimedit
# ==============================================================================

# --- CONFIGURATION DES COULEURS & CHEMINS ---
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[1;34m"
NC="\e[0m"

# --- DÉTECTION AUTOMATIQUE DU CHEMIN ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_YML="${SCRIPT_DIR}/00.00.requirements.yml"
ADMIN_GROUP="gr_ansible_admins"

# Destinations pour la double installation
SYS_PATH="/usr/share/ansible/collections"
LOCAL_PATH="${SCRIPT_DIR}/collections"

echo -e "${BLUE}🔍 [START] Vérification et alignement des collections Ansible (Double cible)...${NC}"

# 1. Vérification de la présence du fichier de référence
if [ ! -f "$REQ_YML" ]; then
    echo -e "${RED}❌ Erreur : Le fichier $REQ_YML est introuvable.${NC}"
    exit 1
fi

# 2. Préparation des dossiers
mkdir -p "$LOCAL_PATH"
sudo mkdir -p "$SYS_PATH"

# 3. Installation double (Boucle pour système et local)
DESTINATIONS=("$LOCAL_PATH" "$SYS_PATH")

for DEST in "${DESTINATIONS[@]}"; do
    echo -e "${BLUE}🔄 Installation dans : ${GREEN}${DEST}${NC}"

    # Si c'est le dossier système, on utilise sudo, sinon installation locale directe
    if [[ "$DEST" == "$SYS_PATH" ]]; then
        sudo ansible-galaxy collection install -r "$REQ_YML" -p "$DEST" --force > /dev/null 2>&1
    else
        ansible-galaxy collection install -r "$REQ_YML" -p "$DEST" --force > /dev/null 2>&1
    fi
done

# 4. Installation spécifique de microsoft.ad (nécessaire pour l'étape AD)
echo -e "${BLUE}🔄 Alignement de la collection 'microsoft.ad'...${NC}"
sudo ansible-galaxy collection install microsoft.ad -p "$SYS_PATH" --force > /dev/null 2>&1
ansible-galaxy collection install microsoft.ad -p "$LOCAL_PATH" --force > /dev/null 2>&1

echo "------------------------------------------------------------"

# 5. SÉCURISATION ET DROITS COLLABORATIFS (SGID)
echo -e "${BLUE}🔄 Alignement des privilèges et persistance du contexte de groupe (SGID)...${NC}"

if [ -d "$SCRIPT_DIR" ]; then
    sudo chown -R admin_ansible:${ADMIN_GROUP} "$SCRIPT_DIR"
    sudo chmod -R 2775 "$SCRIPT_DIR"
    sudo find "$SCRIPT_DIR" -type d -exec chmod g+s {} +
    sudo find "$SCRIPT_DIR" -type d -exec chmod g+rwX {} +
    sudo find "$SCRIPT_DIR" -type f -exec chmod g+rw {} +
    sudo find "$SCRIPT_DIR" -name "*.sh" -exec chmod ug+x {} +

    echo -e "   ${GREEN}[OK] Droits collaboratifs réappliqués avec succès sur : $SCRIPT_DIR${NC}"
else
    echo -e "   ${RED}[ERREUR] Impossible de détecter le répertoire du projet.${NC}"
fi

echo "------------------------------------------------------------"
echo -e "${GREEN}✅ ALIGNEMENT DU SYSTEME ET DU PROJET TERMINE AVEC SUCCÈS !${NC}"
