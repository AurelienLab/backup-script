#!/bin/bash

# Chemin du script
SCRIPT_PATH=$(dirname "$0")

# Chemin du fichier de configuration en utilisant le chemin du script
CONFIG_FILE="$SCRIPT_PATH/config.conf"

# Gestion des options en ligne de commande
force_backup=0  # Valeur par défaut
db_to_backup=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f | --force)
            force_backup=1
            shift
            ;;
        -d | --database)
            if [ -n "$2" ]; then
                db_to_backup="$2"
                shift 2
            else
                echo "Erreur : L'option --database nécessite un argument." >&2
                exit 1
            fi
            ;;
        *)
            echo "Option invalide : $1" >&2
            exit 1
            ;;
    esac
done


# Vérifier si le fichier de configuration existe
function check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Erreur: Le fichier de configuration \"$CONFIG_FILE\" n'existe pas."
        exit 1
    fi
}

# Lire le fichier de configuration et effectuer les sauvegardes pour chaque base de données spécifiée
function read_config_and_backup() {
    local section=""
    local section_content=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [ -n "$section" ]; then
                if [ -z "$db_to_backup" ] || [ "$db_to_backup" == "$section" ]; then
                    process_section "$section" "$section_content"
                fi
                section_content=""
            fi
            section="${BASH_REMATCH[1]}"
        else
            section_content+="$line"$'\n'
        fi
    done < "$CONFIG_FILE"

    if [ -n "$section" ]; then
        if [ -z "$db_to_backup" ] || [ "$db_to_backup" == "$section" ]; then
            process_section "$section" "$section_content"
        fi
    fi
}

# Traiter une section de configuration
function process_section() {
    local section_name="$1"
    local section_content="$2"
    local db_name="$1"
    local db_type=""
    local db_user=""
    local db_password=""
    local db_file=""

    local backup_datetime="$(date +'%Y%m%d_%H%M%S')"
    local backup_file="${backup_datetime}_${db_name}.tar.gz"

    local keep_versions=0
    local local_backup_path=""
    local s3_bucket_name=""
    local interval_days=0
    local folders_to_save=""

    while IFS="=" read -r key value; do
        key=$(echo "$key" | tr '[:lower:]' '[:upper:]' | xargs)
        value=$(echo "$value" | xargs)

        case "$key" in
            DB_NAME) db_name="$value" ;;
            DB_TYPE) db_type="$value" ;;
            DB_USER) db_user="$value" ;;
            DB_FILE) db_file="$value" ;;
            DB_PASSWORD) db_password="$value" ;;
            KEEP_VERSIONS) keep_versions="$value" ;;
            LOCAL_BACKUP_PATH) local_backup_path="$value" ;;
            S3_BUCKET_NAME) s3_bucket_name="$value" ;;
            INTERVAL_DAYS) interval_days="$value" ;;
            FOLDER_TO_SAVE) folders_to_save="$value" ;;
        esac
    done <<< "$section_content"

    # Vérifier si une nouvelle sauvegarde est nécessaire en fonction de l'intervalle de jours spécifié
    if [ "$force_backup" -eq 1 ] || should_perform_backup "$local_backup_path" "$section_name" "$interval_days"; then
        # Effectuer la sauvegarde de la base de données
        if [ "$db_type" == "mysql" ]; then
            backup_mysql_database "$db_name" "$db_user" "$db_password" "$local_backup_path" "$backup_datetime"
        elif [ "$db_type" == "sqlite" ]; then
            backup_sqlite_database "$db_name" "$db_file" "$local_backup_path" "$backup_datetime"
        fi

        # Appeler la fonction pour sauvegarder les dossiers spécifiés
        backup_folders "$folders_to_save" "$local_backup_path" "$backup_datetime"

        # Supprimer les anciennes versions de sauvegardes en gardant seulement les dernières N versions
        cleanup_old_backups "$local_backup_path" "$db_name" "$keep_versions"

        # Transférer la sauvegarde vers le bucket S3
        transfer_to_s3 "$local_backup_path" "$backup_file" "$s3_bucket_name" "$db_name"

        echo "Sauvegarde terminée pour la base de données : $db_name"
        echo "-------------------------------------------------"
    else
        echo "L'intervalle de jours pour la base de données [$db_name] n'est pas dépassé (Intervalle : $interval_days jours). Pas de nouvelle sauvegarde."
    fi
}


# Vérifier si une nouvelle sauvegarde est nécessaire en fonction de l'intervalle de jours spécifié
function should_perform_backup() {
    local local_backup_path="$1"
    local db_name="$2"
    local interval_days="$3"
    local interval_seconds=$((interval_days * 86400)) # Convertir l'intervalle de jours en secondes
    local margin_of_error=60 # Marge d'erreur en secondes (par exemple, 60 secondes)

    # Vérifier s'il y a des fichiers de sauvegarde existants dans le répertoire local
    latest_backup_file=$(find "${local_backup_path}/database" -maxdepth 1 -type f -name "*_${db_name}.tar.gz" | sort -r | head -n 1)

    if [ -z "$latest_backup_file" ]; then
        # Aucun fichier de sauvegarde trouvé, effectuer la sauvegarde
        return 0
    else
        # Fichier de sauvegarde trouvé, vérifier si une nouvelle sauvegarde est nécessaire
        last_backup_date=$(echo "$latest_backup_file" | sed -n 's/.*\([0-9]\{8\}\)_[0-9]\{6\}.*/\1/p')
        last_backup_timestamp=$(date -d "$last_backup_date" +"%s")
        current_timestamp=$(date +"%s")
        time_difference=$((current_timestamp - last_backup_timestamp))

        if [ "$time_difference" -ge "$((interval_seconds - margin_of_error))" ]; then
            # Interval de jours dépassé ou marge d'erreur atteinte, effectuer la sauvegarde
            return 0
        else
            # Interval de jours non dépassé, pas de nouvelle sauvegarde nécessaire
            return 1
        fi
    fi
}

# Effectuer la sauvegarde de la base de données
function backup_mysql_database() {
    local db_name="$1"
    local mysql_user="$2"
    local mysql_password="$3"
    local local_backup_path="$4"
    local backup_datetime="$5"

    # Créer un répertoire temporaire pour effectuer l'archivage
    local temp_backup_dir="${local_backup_path}/database/temp_${db_name}_${backup_datetime}"
    mkdir -p "$temp_backup_dir"

    echo "---- Sauvegarde de la base de données : $db_name ----"
    echo "Date/Heure de la sauvegarde : $backup_datetime"
    echo "Répertoire temporaire : $temp_backup_dir"

    # Effectuer la sauvegarde de la base de données
    mysqldump -u "$mysql_user" -p"$mysql_password" "$db_name" > "${temp_backup_dir}/${db_name}.sql"

    create_tar_archive "$local_backup_path" "${db_name}.sql" "$backup_datetime" "${backup_datetime}_${db_name}.tar.gz"
}

function backup_sqlite_database() {
    local db_name="$1"
    local db_file="$2"
    local local_backup_path="$3"
    local backup_datetime="$4"

    # Créer un répertoire temporaire pour effectuer l'archivage
    local temp_backup_dir="${local_backup_path}/database/temp_${db_name}_${backup_datetime}"
    mkdir -p "$temp_backup_dir"

    echo "---- Sauvegarde de la base de données : $db_name ----"
    echo "Date/Heure de la sauvegarde : $backup_datetime"
    echo "Répertoire temporaire : $temp_backup_dir"

    # Effectuer la sauvegarde de la base de données
    cp "$db_file" "$temp_backup_dir/${db_name}.db"

    create_tar_archive "$local_backup_path" "${db_name}.db" "$backup_datetime" "${backup_datetime}_${db_name}.tar.gz"
}

# Créer une archive tar.gz avec la date et l'heure dans le nom du fichier
function create_tar_archive() {
    local local_backup_path="$1"
    local temp_file_name="$2"
    local backup_datetime="$3"
    local backup_file="$4"

    cd "${local_backup_path}/database" || exit 1
    tar -czf "$backup_file" --directory="temp_${db_name}_${backup_datetime}" "$temp_file_name"

    # Supprimer le répertoire temporaire
    rm -r "${local_backup_path}/database/temp_${db_name}_${backup_datetime}"

    # Revenir au répertoire initial
    cd - || exit 1
}

function backup_folders() {
    local folders_to_save="$1"
    local local_backup_path="$2"
    local backup_datetime="$3"

    IFS=';' read -ra folders <<< "$folders_to_save"
    for folder_path in "${folders[@]}"; do
        folder_name=$(basename "$folder_path")
        target_folder="${local_backup_path}/files/${folder_name}"

        if [ -d "$folder_path" ]; then
            echo "---- Sauvegarde du dossier : $folder_path ----"
            mkdir -p "$target_folder"
            rsync -a --stats --ignore-existing "$folder_path/" "$target_folder/"
        else
            echo "Le dossier spécifié n'existe pas : $folder_path"
        fi
    done
}

# Transférer la sauvegarde vers le bucket S3
function transfer_to_s3() {
    local local_backup_path="$1"
    local backup_file="$2"
    local s3_bucket_name="$3"
    local db_name="$4"

    echo "Transfert de la sauvegarde vers S3..."
    rclone --size-only sync "${local_backup_path}" "${s3_bucket_name}/current" --backup-dir "${s3_bucket_name}/trash"
}

# Supprimer les anciennes versions de sauvegardes en gardant seulement les dernières N versions
function cleanup_old_backups() {
    local local_backup_path="$1"
    local db_name="$2"
    local keep_versions="$3"

    cd "$local_backup_path/database" || exit 1
    backup_count=$(ls -1 | grep -E "^[0-9]{8}_[0-9]{6}_${db_name}.*\.tar\.gz$" | wc -l)

    if [ "$backup_count" -gt "$keep_versions" ]; then
        ls -1t | grep -E "^[0-9]{8}_[0-9]{6}_${db_name}.*\.tar\.gz$" | tail -n +"$((keep_versions + 1))" | xargs -I {} rm {}
        echo "Anciennes sauvegardes supprimées (Garder les dernières $keep_versions versions)"
    else
        echo "Nombre de sauvegardes actuelles : $backup_count (Garder les dernières $keep_versions versions)"
    fi

    cd - || exit 1
}

# Fonction principale du script
function main() {
    check_config_file
    read_config_and_backup
    echo "Toutes les sauvegardes ont été effectuées avec succès."
}

# Appel de la fonction principale
main