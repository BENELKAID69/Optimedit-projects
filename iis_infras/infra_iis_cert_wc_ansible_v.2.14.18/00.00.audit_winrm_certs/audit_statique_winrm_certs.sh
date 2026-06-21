#!/bin/bash
# A executer sur le Master Ansible
# ==============================================================================
# Emplacement : /projets_optimedit/iis_infras/infra_iis_cert_wc_ansible_v.2.14.18/00.00.audit_winrm_certs
# Fichier      : audit_statique_winrm_certs.sh
# ==============================================================================

# --- Détection dynamique du dossier du script et création du sous-dossier CSV ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/csv_result"
mkdir -p "$RESULT_DIR"

# --- Configuration ---
SERVERS=(
    "opt-iis-01.optimedit.eu"
    "opt-iis-02.optimedit.eu"
    "opt-iis-03.optimedit.eu"
    "opt-iis-04.optimedit.eu"
    "opt-iis-05.optimedit.eu"
    "opt-iis-06.optimedit.eu"
    "opt-iis-07.optimedit.eu"
    "opt-FS01.optimedit.eu"
)

DATE_STR=$(date +%Y%m%d_%H%M)
OUTPUT_CSV="${RESULT_DIR}/audit_winrm_${DATE_STR}.csv"
CA_PATH="/etc/ssl/certs/"

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
echo "[OK] Rapport généré : $OUTPUT_CSV"
