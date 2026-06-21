#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/iis_infras/infra_iis_cert_wc_ansible_v.2.14.18/00.00.audit_winrm_certs/00.00.scripts_sh_conf_et_validations
# Fichier      : 02.00.iis_test_configuration_curl_http.sh
# Description : Recette et validation automatisée des 13 sites IIS (HTTP)
# Date : 29/05/2026
# ==============================================================================

# Couleurs pour l'affichage
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Pas de couleur

#TARGET_IP="192.168.3.168"
# Récupère dynamiquement l'IP de la première application de la liste (ex: achat.optimedit.eu)
TARGET_IP=$(nslookup achat.optimedit.eu | awk '/^Address: / { print $2 }' | tail -n1)
DOMAIN="optimedit.eu"

# Liste des applications avec leurs ports dédiés
declare -A APPS=(
    ["direction"]=8060
    ["comptabilite"]=8061
    ["paie"]=8062
    ["rh"]=8063
    ["ce"]=8064
    ["it"]=8065
    ["production"]=8066
    ["formation"]=8067
    ["achat"]=8068
    ["commercial"]=8069
    ["client"]=8070
    ["juridique"]=8071
    ["blog"]=8072
)

echo -e "${BLUE}=== ÉTAPE 1 : Validation de la Résolution DNS ===${NC}"
DNS_ERRORS=0

for app in "${!APPS[@]}"; do
    FQDN="${app}.${DOMAIN}"
    echo -n "Vérification DNS de ${FQDN}... "
    if nslookup "$FQDN" >/dev/null 2>&1; then
        RESOLVED_IP=$(nslookup "$FQDN" | awk '/^Address: / { print $2 }' | tail -n1)
        echo -e "${GREEN}OK (${RESOLVED_IP})${NC}"
    else
        echo -e "${RED}ÉCHEC${NC}"
        DNS_ERRORS=$((DNS_ERRORS + 1))
    fi
done

if [ $DNS_ERRORS -gt 0 ]; then
    echo -e "${YELLOW}[WARNING] Certaines résolutions DNS ont échoué. Vérifie ton serveur DNS.${NC}"
fi

echo ""
echo -e "${BLUE}=== ÉTAPE 2 : Vérification et Installation de Curl ===${NC}"
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}[i] Curl n'est pas installé. Installation en cours...${NC}"
    sudo apt update && sudo apt install curl -y
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR] Impossible d'installer curl. Arrêt du script.${NC}"
        exit 1
    fi
    echo -e "${GREEN}OK : Curl a été installé avec succès.${NC}"
else
    echo -e "${GREEN}OK : Curl est déjà installé.${NC}"
fi

echo ""
echo -e "${BLUE}=== ÉTAPE 3 : Tests de connectivité HTTP (Ports Dédiés & FQDN) ===${NC}"
echo -e "${BLUE}==================================================================${NC}"

for app in $(echo "${!APPS[@]}" | tr ' ' '\n' | sort); do
    port=${APPS[$app]}
    FQDN="${app}.${DOMAIN}"
    
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    echo -e "${BLUE}Application : ${app^^} (Port: ${port} | FQDN: ${FQDN})${NC}"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    
    # Test 1 : Port Dédié (via IP)
    echo -e "${BLUE}[Test 1/2] Requête sur Port Dédié (http://${TARGET_IP}:${port}) :${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://${TARGET_IP}:${port}")
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        echo -e "${GREEN}👉 HTTP Code: 200 OK${NC}"
        # Affiche un aperçu propre du contenu HTML extrait
        curl -s "http://${TARGET_IP}:${port}" | grep -E "(Bienvenue|Cible|Nom Réel)" || curl -s "http://${TARGET_IP}:${port}" | head -n 3
    else
        echo -e "${RED}👉 ÉCHEC (HTTP Code: ${HTTP_CODE})${NC}"
    fi
    
    echo ""
    
    # Test 2 : Résolution par Nom (Port 80 standard)
    echo -e "${BLUE}[Test 2/2] Requête via FQDN Standard (http://${FQDN}) :${NC}"
    HTTP_CODE_FQDN=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://${FQDN}")
    
    if [ "$HTTP_CODE_FQDN" -eq 200 ]; then
        echo -e "${GREEN}👉 HTTP Code: 200 OK${NC}"
        curl -s "http://${FQDN}" | grep -E "(Bienvenue|Cible|Nom Réel)" || curl -s "http://${FQDN}" | head -n 3
    else
        echo -e "${RED}👉 ÉCHEC (HTTP Code: ${HTTP_CODE_FQDN})${NC}"
    fi
    echo ""
done

echo -e "${BLUE}=== Fin de la recette des composants IIS ===${NC}"

