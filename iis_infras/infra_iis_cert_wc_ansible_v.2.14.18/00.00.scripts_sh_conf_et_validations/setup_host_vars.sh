#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/iis_infras/infra_iis_cert_wc_ansible_v.2.14.18/00.00.audit_winrm_certs/00.00.scripts_sh_conf_et_validations
# Fichier      : setup_host_vars.sh
# Date : 29/05/2026
# DESCRIPTION : Initialise le dossier host_vars et les IPs pour srv_iis
# ==============================================================================
# 1. Création du dossier racine host_vars s'il n'existe pas
mkdir -p host_vars

echo "🚀 Génération des fichiers dans host_vars..."

# 2. Définition des serveurs et de leurs IPs respectives
# On utilise un tableau associatif (nécessite Bash 4+)
declare -A SERVERS=(
    ["OPT-IIS-01.optimedit.eu"]="192.168.3.62"
    ["OPT-IIS-02.optimedit.eu"]="192.168.3.64"
    ["OPT-IIS-03.optimedit.eu"]="192.168.3.65"
    ["OPT-IIS-04.optimedit.eu"]="192.168.3.91"
    ["OPT-IIS-05.optimedit.eu"]="192.168.3.92"
    ["OPT-IIS-06.optimedit.eu"]="192.168.3.93"
)

# 3. Boucle de création des fichiers
for host in "${!SERVERS[@]}"; do
    cat <<EOF > "host_vars/${host}.yml"
---
# Configuration spécifique pour ${host}
srv_ip_address: "${SERVERS[$host]}"
EOF
    echo "✅ Fichier créé : host_vars/${host}.yml (IP: ${SERVERS[$host]})"
done

echo "🏁 Terminé. La structure host_vars est prête."
