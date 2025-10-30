#!/bin/bash

# ========================
# SCRIPT DE SAUVEGARDE V2
# ========================
# - Support MySQL / SQLite / Dossiers
# - Gestion des versions et des intervalles
# - Fichier metadata.json
# - Upload S3 via rclone
# ========================

SCRIPT_PATH=$(dirname "$0")
CONFIG_FILE="$SCRIPT_PATH/config.conf"

force_backup=0
db_to_backup=""

# -------------------------
# Lecture des arguments CLI
# -------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            force_backup=1
            shift
            ;;
        -d|--database)
            db_to_backup="$2"
            shift 2
            ;;
        *)
            echo "Option invalide : $1" >&2
            exit 1
            ;;
    esac
done

# -------------------------
# Vérification config
# -------------------------
function check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Erreur: Le fichier de configuration \"$CONFIG_FILE\" n'existe pas."
        exit 1
    fi
}

# -------------------------
# Lecture du fichier INI
# -------------------------
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

# -------------------------
# Traitement d'une section
# -------------------------
function process_section() {
    local section_name="$1"
    local section_content="$2"
    local db_name="$1"
    local db_type=""
    local db_user=""
    local db_password=""
    local db_file=""
    local keep_versions=0
    local local_backup_path=""
    local s3_bucket_name=""
    local interval_days=0
    local folders_to_save=""
    local files_versioned="false"

    local backup_datetime
    backup_datetime="$(date +'%Y%m%d_%H%M%S')"
    local backup_file="${backup_datetime}_${db_name}.tar.gz"

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
            FILES_VERSIONED) files_versioned="$value" ;;
        esac
    done <<< "$section_content"

    if [ -z "$local_backup_path" ]; then
        echo "⚠️  LOCAL_BACKUP_PATH non défini pour [$section_name], section ignorée."
        return
    fi

    mkdir -p "$local_backup_path"

    if [ "$force_backup" -eq 1 ] || should_perform_backup "$local_backup_path" "$section_name" "$interval_days"; then
        echo "=== Début de la sauvegarde [$section_name] ==="

        # 1️⃣ Sauvegarde base de données
        if [ -n "$db_type" ]; then
            mkdir -p "${local_backup_path}/database"
            if [ "$db_type" == "mysql" ]; then
                backup_mysql_database "$db_name" "$db_user" "$db_password" "$local_backup_path" "$backup_datetime"
            elif [ "$db_type" == "sqlite" ]; then
                backup_sqlite_database "$db_name" "$db_file" "$local_backup_path" "$backup_datetime"
            else
                echo "⚠️  Type de base de données inconnu pour [$section_name], ignoré."
            fi
        else
            echo "Aucune base de données à sauvegarder pour [$section_name] (DB_TYPE non défini)."
        fi

        # 2️⃣ Sauvegarde des dossiers
        if [ -n "$folders_to_save" ]; then
            mkdir -p "${local_backup_path}/files"
            backup_folders "$folders_to_save" "$local_backup_path" "$backup_datetime" "$files_versioned"
        fi

        # 3️⃣ Nettoyage des anciennes sauvegardes
        if [ -n "$db_type" ] && [ "$keep_versions" -gt 0 ]; then
            cleanup_old_backups "$local_backup_path" "$db_name" "$keep_versions"
        fi
        if [ "$files_versioned" == "true" ] && [ "$keep_versions" -gt 0 ]; then
            cleanup_old_folder_backups "$local_backup_path" "$keep_versions"
        fi

        # 4️⃣ Transfert S3
        if [ -n "$s3_bucket_name" ]; then
            transfer_to_s3 "$local_backup_path" "$backup_file" "$s3_bucket_name" "$db_name"
        fi

        # 5️⃣ Metadata
        update_metadata "$local_backup_path" "$db_name" "$backup_datetime" "$backup_file" "$folders_to_save" "$files_versioned"

        echo "=== Fin de la sauvegarde [$section_name] ==="
        echo
    else
        echo "⏩ Pas de nouvelle sauvegarde pour [$section_name] (intervalle non dépassé)."
    fi
}

# -------------------------
# Vérifie si une sauvegarde est requise
# -------------------------
function should_perform_backup() {
    local local_backup_path="$1"
    local db_name="$2"
    local interval_days="$3"
    local interval_seconds=$((interval_days * 86400))
    local margin_of_error=60

    latest_backup_file=$(find "${local_backup_path}/database" -maxdepth 1 -type f -name "*_${db_name}.tar.gz" 2>/dev/null | sort -r | head -n 1)
    if [ -z "$latest_backup_file" ]; then
        return 0
    fi

    last_backup_date=$(echo "$latest_backup_file" | sed -n 's/.*\([0-9]\{8\}\)_[0-9]\{6\}.*/\1/p')
    last_backup_timestamp=$(date -d "$last_backup_date" +"%s")
    current_timestamp=$(date +"%s")
    time_difference=$((current_timestamp - last_backup_timestamp))

    [ "$time_difference" -ge "$((interval_seconds - margin_of_error))" ]
}

# -------------------------
# Sauvegarde MySQL
# -------------------------
function backup_mysql_database() {
    local db_name="$1" mysql_user="$2" mysql_password="$3" local_backup_path="$4" backup_datetime="$5"
    local temp_dir="${local_backup_path}/database/temp_${db_name}_${backup_datetime}"
    mkdir -p "$temp_dir"

    echo "→ Sauvegarde MySQL de $db_name"
    mysqldump -u "$mysql_user" -p"$mysql_password" "$db_name" > "${temp_dir}/${db_name}.sql"
    create_tar_archive "$local_backup_path" "$db_name" "${db_name}.sql" "$backup_datetime" "${backup_datetime}_${db_name}.tar.gz"
}

# -------------------------
# Sauvegarde SQLite
# -------------------------
function backup_sqlite_database() {
    local db_name="$1" db_file="$2" local_backup_path="$3" backup_datetime="$4"
    local temp_dir="${local_backup_path}/database/temp_${db_name}_${backup_datetime}"
    mkdir -p "$temp_dir"

    echo "→ Sauvegarde SQLite de $db_name"
    cp "$db_file" "$temp_dir/${db_name}.db"
    create_tar_archive "$local_backup_path" "$db_name" "${db_name}.db" "$backup_datetime" "${backup_datetime}_${db_name}.tar.gz"
}

# -------------------------
# Création archive tar.gz
# -------------------------
function create_tar_archive() {
    local local_backup_path="$1"
    local db_name="$2"
    local temp_file_name="$3"
    local backup_datetime="$4"
    local backup_file="$5"

    local db_dir="${local_backup_path}/database"
    local temp_dir="${db_dir}/temp_${db_name}_${backup_datetime}"

    mkdir -p "$db_dir"
    if [ ! -d "$temp_dir" ]; then
        echo "⚠️  Dossier temporaire manquant : $temp_dir"
        return 1
    fi

    (
        cd "$db_dir" || return 1
        tar -czf "$backup_file" --directory="temp_${db_name}_${backup_datetime}" "$temp_file_name"
        rm -rf "temp_${db_name}_${backup_datetime}"
    )
}

# -------------------------
# Sauvegarde de dossiers
# -------------------------
function backup_folders() {
    local folders_to_save="$1"
    local local_backup_path="$2"
    local backup_datetime="$3"
    local files_versioned="${4:-false}"

    IFS=';' read -ra folders <<< "$folders_to_save"
    for folder_path in "${folders[@]}"; do
        folder_name=$(basename "$folder_path")

        if [ "$files_versioned" == "true" ]; then
            target_folder="${local_backup_path}/files/${backup_datetime}/${folder_name}"
            echo "→ Sauvegarde versionnée du dossier $folder_path → $target_folder"
            mkdir -p "$target_folder"
            rsync -a --stats "$folder_path/" "$target_folder/"
        else
            target_folder="${local_backup_path}/files/${folder_name}"
            echo "→ Synchronisation du dossier $folder_path → $target_folder"
            mkdir -p "$target_folder"
            rsync -a --stats --ignore-existing "$folder_path/" "$target_folder/"
        fi
    done
}

# -------------------------
# Nettoyage anciennes sauvegardes DB
# -------------------------
function cleanup_old_backups() {
    local local_backup_path="$1" db_name="$2" keep_versions="$3"
    local db_dir="${local_backup_path}/database"
    [ ! -d "$db_dir" ] && return

    cd "$db_dir" || return
    local count
    count=$(ls -1 | grep -E "^[0-9]{8}_[0-9]{6}_${db_name}.*\.tar\.gz$" | wc -l)
    if [ "$count" -gt "$keep_versions" ]; then
        ls -1t | grep -E "^[0-9]{8}_[0-9]{6}_${db_name}.*\.tar\.gz$" | tail -n +"$((keep_versions + 1))" | xargs -r rm
        echo "🧹 Anciennes sauvegardes supprimées (garde $keep_versions dernières)"
    fi
}

# -------------------------
# Nettoyage anciennes sauvegardes dossiers
# -------------------------
function cleanup_old_folder_backups() {
    local local_backup_path="$1"
    local keep_versions="$2"
    local files_path="${local_backup_path}/files"

    [ ! -d "$files_path" ] && return

    local count
    count=$(find "$files_path" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | grep -E '^[0-9]{8}_[0-9]{6}$' | wc -l)
    if [ "$count" -gt "$keep_versions" ]; then
        find "$files_path" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | grep -E '^[0-9]{8}_[0-9]{6}$' | sort -r | tail -n +"$((keep_versions + 1))" | while read -r old_dir; do
            rm -rf "${files_path}/${old_dir}"
            echo "🧹 Ancienne sauvegarde de dossier supprimée : $old_dir"
        done
    fi
}

# -------------------------
# Transfert vers S3
# -------------------------
function transfer_to_s3() {
    local local_backup_path="$1" backup_file="$2" s3_bucket_name="$3"
    echo "→ Transfert S3..."
    rclone --size-only sync "${local_backup_path}" "${s3_bucket_name}/current" --backup-dir "${s3_bucket_name}/trash"
}

# -------------------------
# Metadata JSON
# -------------------------
function update_metadata() {
    local local_backup_path="$1"
    local db_name="$2"
    local backup_datetime="$3"
    local db_file_name="$4"
    local folders_to_save="$5"
    local files_versioned="$6"

    local metadata_file="${local_backup_path}/metadata.json"
    local existing_content="{}"

    if [ -f "$metadata_file" ]; then
        existing_content=$(cat "$metadata_file")
    fi

    if command -v jq >/dev/null 2>&1; then
        new_entry="{\"date\":\"${backup_datetime}\",\"database\":\"${db_file_name}\",\"folders_versioned\":${files_versioned}}"
        updated=$(echo "$existing_content" | jq \
            --argjson entry "$new_entry" \
            --arg date "$backup_datetime" \
            '.last_backup = $date | .backups = (.backups // []) + [$entry]' 2>/dev/null)
        echo "$updated" > "$metadata_file"
    else
        echo "{\"last_backup\":\"${backup_datetime}\",\"database\":\"${db_file_name}\",\"folders_versioned\":${files_versioned}}" > "$metadata_file"
    fi
}

# -------------------------
# MAIN
# -------------------------
function main() {
    check_config_file
    read_config_and_backup
    echo "✅ Toutes les sauvegardes terminées."
}

main