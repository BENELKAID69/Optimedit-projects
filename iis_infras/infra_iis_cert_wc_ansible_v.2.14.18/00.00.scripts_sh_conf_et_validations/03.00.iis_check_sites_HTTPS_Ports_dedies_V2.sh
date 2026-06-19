#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/infra_iis_ansible/infra_iis_cert_wc_ansible_v.2.14.18/00.00.scripts_sh_conf_et_validations
# Fichier      : 03.00.iis_check_sites_HTTPS_Ports_dedies_V2.sh
# Date : 29/05/2026
# ==============================================================================
# Tableau associatif "nom_application:port_dedie"
SITES=(
    "direction:8060"
    "comptabilite:8061"
    "paie:8062"
    "rh:8063"
    "ce:8064"
    "it:8065"
    "production:8066"
    "formation:8067"
    "achat:8068"
    "commercial:8069"
    "client:8070"
    "juridique:8071"
    "blog:8072"
)

echo "--- Test des sites Optimedit (HTTPS - Ports Dédiés Durcis) ---"

for item in "${SITES[@]}"; do
    # Extraction du nom et du port
    app="${item%%:*}"
    port="${item##*:}"
    
    url="https://$app.optimedit.eu:$port"
    
    # -k : Ignore les alertes de certificats auto-signés/internes si ta PKI n'est pas dans le trust store Linux
    # -s : Mode silencieux
    status=$(curl -o /dev/null -s -w "%{http_code}" -k "$url")

    # Gestion des statuts spécifiques suite au Hardening
    if [ "$status" = "000" ]; then
        status="DOWN / Port $port fermé ou inaccessible"
    elif [ "$status" = "400" ]; then
        status="HTTP 400 (Rejeté - Host Header non valide / Cloisonnement OK)"
    fi

    echo "[$app] -> $url : $status"
done
