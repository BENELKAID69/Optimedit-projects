#!/bin/bash
# ==============================================================================
# NOM DU SCRIPT : 01.install_and_test_ca.sh
# CONFIGURATION  : Automatisation de l'intégration CA & Test TLS WinRM (5986)
# AUTHOR         : Optimedit
# ==============================================================================

# Couleurs pour l'affichage
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"

# Vérification du privilège Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Erreur : Ce script doit être exécuté en tant que root ou avec sudo.${NC}"
    exit 1
fi

echo -e "${YELLOW}🔍 Étape 1 : Recherche d'un certificat de CA local...${NC}"

# Recherche du premier fichier .cer ou .crt
CA_SOURCE=$(ls *.cer *.crt 2>/dev/null | head -n 1)

if [ -z "$CA_SOURCE" ]; then
    echo -e "${RED}❌ Erreur : Aucun fichier .cer ou .crt trouvé dans le dossier actuel.${NC}"
    exit 1
fi

# Extraction du nom de base propre (sans extension) et préparation de la cible en .crt
CA_NAME=$(basename "$CA_SOURCE" | sed 's/\.[^.]*$//')
TARGET_CRT="/usr/local/share/ca-certificates/${CA_NAME}.crt"

echo -e "   [INFO] Certificat source trouvé : ${GREEN}${CA_SOURCE}${NC}"
echo -e "   [INFO] Copie vers le magasin système : ${TARGET_CRT}"

# 1. Copie du certificat vers le répertoire officiel
cp "$CA_SOURCE" "$TARGET_CRT"
chmod 644 "$TARGET_CRT"

# 2. Mise à jour forcée du magasin de certificats Linux
echo -e "${YELLOW}🔄 Étape 2 : Rafraîchissement du magasin de certificats (update-ca-certificates)...${NC}"
update-ca-certificates --fresh > /dev/null

# Vérification de la création du lien symbolique PEM
PEM_LINK="/etc/ssl/certs/${CA_NAME}.pem"
if [ -L "$PEM_LINK" ]; then
    echo -e "${GREEN}✅ [OK] Le certificat système a été correctement déployé et lié.${NC}"
else
    echo -e "${RED}❌ Erreur : Le lien symbolique système n'a pas pu être généré.${NC}"
    exit 1
fi

echo "------------------------------------------------------------"

# 3. Phase de Test Interactive
echo -e "${YELLOW}🧪 Étape 3 : Validation interactive de la chaîne TLS${NC}"
read -p "👉 Entrez le FQDN du serveur Windows à tester (ex: opt-iis-01.optimedit.eu) : " TARGET_SERVER

if [ -z "$TARGET_SERVER" ]; then
    echo -e "${RED}❌ Erreur : Aucun nom de serveur renseigné. Fin du script.${NC}"
    exit 1
fi

echo -e "\n📡 Connexion TLS en cours sur ${TARGET_SERVER}:5986..."

# Exécution de OpenSSL en mode silencieux, extraction stricte du bloc de validation
OPENSSL_OUTPUT=$(echo | openssl s_client -connect "${TARGET_SERVER}:5986" -CAfile /etc/ssl/certs/ca-certificates.crt 2>&1)

# Analyse du code de retour via Grep
if echo "$OPENSSL_OUTPUT" | grep -q "Verification: OK"; then
    echo -e "------------------------------------------------------------"
    echo -e "${GREEN}✅ VALIDATION RÉUSSIE !${NC}"
    echo "$OPENSSL_OUTPUT" | grep -A 2 "Verification:"
    echo -e "------------------------------------------------------------"
else
    echo -e "------------------------------------------------------------"
    echo -e "${RED}❌ ÉCHEC DE LA VALIDATION TLS !${NC}"
    # Affiche l'erreur potentielle pour débugger
    echo "$OPENSSL_OUTPUT" | grep -i -E "error|fail" | head -n 3
    echo -e "------------------------------------------------------------"
fi