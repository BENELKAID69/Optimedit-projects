#!/bin/bash
# A executer sur le Master Ansible
# ==============================================================================
# Emplacement : /projets_optimedit/infra_iis_ansible/infra_iis_cert_wc_ansible_v.2.14.18/00.00.audit_winrm_certs
# Fichier      : audit_dynamique_winrm_certs_with_group_vars.sh
# ==============================================================================

# --- Détection dynamique du dossier du script et création du sous-dossier CSV ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/csv_result"
mkdir -p "$RESULT_DIR"

# --- Configuration ---
INVENTORY_FILE="${SCRIPT_DIR}/../inventory.yml"
CA_PATH="/etc/ssl/certs/"
DATE_STR=$(date +%Y%m%d_%H%M)

# Sécurité : Vérification de la présence de l'inventaire et de jq
if [ ! -f "$INVENTORY_FILE" ]; then
    echo -e "\e[31m[ERREUR] Le fichier d'inventaire $INVENTORY_FILE n'existe pas.\e[0m"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "\e[31m[ERREUR] 'jq' est requis mais non installé. Lance : sudo apt install jq\e[0m"
    exit 1
fi

echo -e "\e[33m=== DEBUT DE L'AUDIT DYNAMIQUE DES GROUPES ANSIBLE ===\e[0m\n"

# 1. Récupération de tous les groupes de l'inventaire (en excluant 'all' et 'ungrouped')
GROUPES=$(ansible-inventory -i "$INVENTORY_FILE" --list | jq -r 'keys[]' | grep -E -v '^(all|ungrouped)$')

for GROUPE in $GROUPES; do
    # 2. Récupération des hôtes spécifiques à ce groupe
    SERVERS=($(ansible-inventory -i "$INVENTORY_FILE" --list | jq -r ".${GROUPE}.hosts[]?" 2>/dev/null))

    # Si le groupe n'a pas d'hôtes directs (ex: groupe de groupes), on passe au suivant
    if [ ${#SERVERS[@]} -eq 0 ]; then
        continue
    fi

    # Nom du CSV personnalisé stocké dans le répertoire csv_result dédié
    OUTPUT_CSV="${RESULT_DIR}/audit_winrm_${GROUPE}_${DATE_STR}.csv"
    echo "FQDN;Thumbprint;ExpirationDate;Status" > "$OUTPUT_CSV"

    echo -e "\e[36m👉 Groupe : [$GROUPE] ($(echo ${#SERVERS[@]}) serveurs)\e[0m"
    printf "%-25s | %-42s | %-25s | %s\n" "FQDN" "THUMBPRINT" "EXPIRATION" "STATUS"
    echo "------------------------------------------------------------------------------------------------------------------------"

    for SRV in "${SERVERS[@]}"; do
        # Capture du flux TLS WinRM (5986)
        RAW_DATA=$(echo | openssl s_client -connect "${SRV}:5986" -CApath "$CA_PATH" 2>&1)

        # Parsing des données du certificat
        FQDN_CERT=$(echo "$RAW_DATA" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN = //' | xargs)
        [ -z "$FQDN_CERT" ] && FQDN_CERT="$SRV"

        EXPIRY=$(echo "$RAW_DATA" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 | xargs)
        THUMB=$(echo | openssl x509 -in <(echo "$RAW_DATA") -noout -fingerprint -sha1 2>/dev/null | cut -d= -f2 | sed 's/://g' | xargs)

        # Détermination du statut de validation
        if echo "$RAW_DATA" | grep -q "Verification: OK"; then
            STATUS="VALIDE"
        elif echo "$RAW_DATA" | grep -q "expired"; then
            STATUS="EXPIRE"
        else
            STATUS="ERREUR_CA"
        fi

        # Affichage console + écriture dans le CSV du groupe
        printf "%-25s | %-42s | %-25s | %s\n" "$FQDN_CERT" "$THUMB" "$EXPIRY" "$STATUS"
        echo "${FQDN_CERT};${THUMB};${EXPIRY};${STATUS}" >> "$OUTPUT_CSV"
    done

    echo "------------------------------------------------------------------------------------------------------------------------"
    echo -e "\e[32m[OK] Rapport généré : $OUTPUT_CSV\e[0m\n"
done

echo -e "\e[33m=== FIN DE L'AUDIT GLOBAL ===\e[0m"
