#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/infra_iis_ansible/infra_iis_cert_wc_ansible_v.2.14.18/00.00.scripts_sh_conf_et_validations
# Fichier      : 03.00.iis_test_configuration_curl_https_ports_dedies.sh
# Description : Recette HTTPS sur ports dédiés spécifiques (Hardening IIS)
# Date : 29/05/2026
# ==============================================================================
# Couleurs pour l'affichage terminal
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN="optimedit.eu"

# Dictionnaire applicatif associant chaque site à son port durci
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

echo -e "${BLUE}=== ÉTAPE 1 : Vérification de la présence de Curl ===${NC}"
if ! command -v curl &> /dev/null; then
    echo -e "${RED}[ERROR] Curl n'est pas disponible. Installe-le avant de continuer.${NC}"
    exit 1
fi
echo -e "${GREEN}OK : Curl est disponible.${NC}"
echo ""

echo -e "${BLUE}=== ÉTAPE 2 : Tests de connectivité HTTPS sur Ports Dédiés ===${NC}"
echo -e "${BLUE}==================================================================${NC}"

# Tri alphabétique des clés du dictionnaire pour un affichage ordonné
for app in $(echo "${!APPS[@]}" | tr ' ' '\n' | sort); do
    port=${APPS[$app]}
    FQDN="${app}.${DOMAIN}"
    URL="https://${FQDN}:${port}"
    
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    echo -e "${BLUE}Vérification Hardening -> ${app^^} (Port dédiée: ${port})${NC}"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    
    # Requête de test TLS + extraction du code de statut HTTP
    echo -n "🔒 Connexion sécurisée à $URL ... "
    HTTP_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" --connect-timeout 3 "$URL")
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        echo -e "${GREEN}200 OK${NC}"
        
        # Affichage sélectif du livrable index.html de test
        echo -e "${BLUE}[Aperçu de la réponse IIS] :${NC}"
        curl -s -k "$URL" | grep -E "(Bienvenue|Cible|Nom Réel)" || curl -s -k "$URL" | head -n 3
    else
        echo -e "${RED}ÉCHEC (HTTP Code: ${HTTP_CODE})${NC}"
    fi
    
    echo ""
done

echo -e "${BLUE}=== Fin de la recette de durcissement HTTPS Ports Dédiés ===${NC}"
