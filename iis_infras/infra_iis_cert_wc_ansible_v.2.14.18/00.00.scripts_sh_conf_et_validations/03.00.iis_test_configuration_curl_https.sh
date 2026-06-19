#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/infra_iis_ansible/infra_iis_cert_wc_ansible_v.2.14.18/00.00.scripts_sh_conf_et_validations
# Fichier      : 03.00.iis_test_configuration_curl_https.sh
# Description : Recette et validation automatisée du chiffrement HTTPS / SNI (443)
# Date : 29/05/2026
# ==============================================================================
# Couleurs pour l'affichage
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN="optimedit.eu"

# Liste des 13 applications métiers
APPS=(
    "direction"
    "comptabilite"
    "paie"
    "rh"
    "ce"
    "it"
    "production"
    "formation"
    "achat"
    "commercial"
    "client"
    "juridique"
    "blog"
)

echo -e "${BLUE}=== ÉTAPE 1 : Vérification de la présence de Curl ===${NC}"
if ! command -v curl &> /dev/null; then
    echo -e "${RED}[ERROR] Curl n'est pas installé sur cette machine. Installe-le avant de continuer.${NC}"
    exit 1
fi
echo -e "${GREEN}OK : Curl est disponible.${NC}"
echo ""

echo -e "${BLUE}=== ÉTAPE 2 : Tests de connectivité HTTPS (Port 443 avec SNI) ===${NC}"
echo -e "${BLUE}==================================================================${NC}"

# Tri par ordre alphabétique pour un rapport propre
for app in $(echo "${APPS[@]}" | tr ' ' '\n' | sort); do
    FQDN="${app}.${DOMAIN}"
    URL="https://${FQDN}"
    
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    echo -e "${BLUE}Vérification HTTPS -> ${FQDN^^}${NC}"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    
    # Test de la poignée de main TLS + Code Retour HTTP
    # -k / --insecure permet de bypasser l'alerte si l'autorité de certification (CA) n'est pas encore poussée sur le master Ansible.
    echo -n "🔒 Connexion à $URL ... "
    HTTP_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" --connect-timeout 3 "$URL")
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        echo -e "${GREEN}200 OK${NC}"
        
        # Récupération et affichage des lignes clés du code HTML généré
        echo -e "${BLUE}[Contenu de la page index.html de test] :${NC}"
        curl -s -k "$URL" | grep -E "(Bienvenue|Cible|Nom Réel)" || curl -s -k "$URL" | head -n 3
    else
        echo -e "${RED}ÉCHEC (HTTP Code: ${HTTP_CODE})${NC}"
    fi
    
    echo ""
done

echo -e "${BLUE}=== Fin de la recette de la couche SSL/HTTPS ===${NC}"
