#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/infra_iis_ansible/infra_iis_cert_wc_ansible_v.2.14.18/00.00.scripts_sh_conf_et_validations\05.00.iis_check_sites
# Fichier      : 05.00.iis_check_sites_HTTP_V2.sh
# Date : 29/05/2026
# ==============================================================================
SITES=("direction" "comptabilite" "paie" "rh" "ce" "it" "production" "formation" "achat" "commercial" "client" "juridique" "blog")

echo "--- Test des sites Optimedit (HTTP - Port 80) ---"
for app in "${SITES[@]}"; do
    url="http://$app.optimedit.eu"
    status=$(curl -o /dev/null -s -w "%{http_code}" "$url")
    
    # Si le statut est 000, le serveur ne répond pas du tout
    if [ "$status" = "000" ]; then
        status="DOWN / Port 80 fermé"
    fi
    
    echo "[$app] -> $url : HTTP $status"
done
