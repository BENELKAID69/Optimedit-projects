#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/infra_iis_ansible/infra_iis_cert_wc_ansible_v.2.14.18/00.00.scripts_sh_conf_et_validations\05.00.iis_check_sites
# Fichier      : 05.00.iis_check_sites_HTTPS_V2.sh
# Date : 29/05/2026
# ==============================================================================
SITES=("direction" "comptabilite" "paie" "rh" "ce" "it" "production" "formation" "achat" "commercial" "client" "juridique" "blog")

echo "--- Test des sites Optimedit (HTTPS - Port 443) ---"
for app in "${SITES[@]}"; do
    url="https://$app.optimedit.eu"
    status=$(curl -o /dev/null -s -w "%{http_code}" -k "$url")
    
    if [ "$status" = "000" ]; then
        status="DOWN / Port 443 fermé (Vérifier IIS ou Certificat)"
    fi
    
    echo "[$app] -> $url : HTTP $status"
done
