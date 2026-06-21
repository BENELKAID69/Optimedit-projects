#!/bin/bash
# A executer sur le Master Ansible
# ==============================================================================
# Emplacement : /projets_optimedit/iis_infras/infra_iis_cert_wc_ansible_v.2.14.18/00.00.audit_winrm_certs
# Fichier      : audit_dynamique_winrm_certs_with_host_vars.sh
# ==============================================================================
# --- Détection dynamique du dossier du script et création du sous-dossier CSV ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/csv_result"
mkdir -p "$RESULT_DIR"

# --- Configuration Dynamique ---
HOST_VARS_DIR="${SCRIPT_DIR}/../host_vars"
CA_PATH="/etc/ssl/certs/"
DATE_STR=$(date +%Y%m%d_%H%M)
OUTPUT_CSV="${RESULT_DIR}/audit_winrm_${DATE_STR}.csv"

# Remplissage automatique du tableau SERVERS
if [ -d "$HOST_VARS_DIR" ]; then
    SERVERS=($(find "$HOST_VARS_DIR" -maxdepth 1 -name "*.yml" -exec basename {} .yml \; | sort))
else
    echo -e "\e[31m[ERREUR] Le dossier $HOST_VARS_DIR n'existe pas.\e[0m"
    exit 1
fi

if [ ${#SERVERS[@]} -eq 0 ]; then
    echo -e "\e[31m[ERREUR] Aucun serveur trouvé dans $HOST_VARS_DIR\e[0m"
    exit 1
fi

# Initialisation du CSV
echo "FQDN;Thumbprint;ExpirationDate;Status" > "$OUTPUT_CSV"

printf "%-25s | %-42s | %-25s | %s\n" "FQDN" "THUMBPRINT" "EXPIRATION" "STATUS"
echo "------------------------------------------------------------------------------------------------------------------------"

for SRV in "${SERVERS[@]}"; do
    # 1. Capture du flux complet
    RAW_DATA=$(echo | openssl s_client -connect "${SRV}:5986" -CApath "$CA_PATH" 2>&1)

    # 2. PARSING ROBUSTE
    FQDN_CERT=$(echo "$RAW_DATA" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN = //' | xargs)
    [ -z "$FQDN_CERT" ] && FQDN_CERT="$SRV"

    EXPIRY=$(echo "$RAW_DATA" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 | xargs)
    THUMB=$(echo | openssl x509 -in <(echo "$RAW_DATA") -noout -fingerprint -sha1 2>/dev/null | cut -d= -f2 | sed 's/://g' | xargs)

    # 3. Détermination du statut
    if echo "$RAW_DATA" | grep -q "Verification: OK"; then
        STATUS="VALIDE"
    elif echo "$RAW_DATA" | grep -q "expired"; then
        STATUS="EXPIRE"
    else
        STATUS="ERREUR_CA"
    fi

    # --- Sortie ---
    printf "%-25s | %-42s | %-25s | %s\n" "$FQDN_CERT" "$THUMB" "$EXPIRY" "$STATUS"
    echo "${FQDN_CERT};${THUMB};${EXPIRY};${STATUS}" >> "$OUTPUT_CSV"
done

echo "------------------------------------------------------------------------------------------------------------------------"
echo "[OK] (Dynamique) Rapport généré avec $(echo ${#SERVERS[@]}) serveurs : $OUTPUT_CSV"
