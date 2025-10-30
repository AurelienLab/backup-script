#!/bin/bash
set -euo pipefail

# ========================
# BACKUP SCRIPT — V3
# ========================

SCRIPT_PATH=$(dirname "$0")
CONFIG_FILE="${SCRIPT_PATH}/config.conf"

force_backup=0
db_filter=""

# -------- CLI --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) force_backup=1; shift ;;
    -d|--database)
      [[ -n "${2:-}" ]] || { echo "Erreur: --database nécessite un nom de section"; exit 1; }
      db_filter="$2"; shift 2 ;;
    *) echo "Option invalide: $1"; exit 1 ;;
  esac
done

# -------- Utils --------
die() { echo "Erreur: $*" >&2; exit 1; }

jq_set() {
  # $1 dest file, $2 jq program, $3 stdin json
  local out; out=$(echo "$3" | jq -c "$2") || return 1
  echo "$out" > "$1"
}

now_ts() { date +'%Y%m%d_%H%M%S'; }

# -------- Checks --------
[[ -f "$CONFIG_FILE" ]] || die "Le fichier de configuration \"$CONFIG_FILE\" n'existe pas."

# -------- should_perform_backup: via metadata du dernier backup --------
should_perform_backup() {
  local base_dir="$1" interval_days="$2"
  local backups_dir="${base_dir}/backups"

  [[ -d "$backups_dir" ]] || return 0

  local last_dir
  last_dir=$(find "$backups_dir" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" \
            | sort -r | head -n1)
  [[ -n "$last_dir" ]] || return 0

  local meta="${backups_dir}/${last_dir}/metadata.json"
  if [[ -f "$meta" ]]; then
    local last_date
    last_date=$(jq -r '.date // empty' "$meta" 2>/dev/null || true)
    if [[ -n "$last_date" ]]; then
      local last_ts current_ts diff
      last_ts=$(date -d "${last_date:0:8} ${last_date:9:2}:${last_date:11:2}:${last_date:13:2}" +%s)
      current_ts=$(date +%s)
      diff=$(( current_ts - last_ts ))
      local need=$(( interval_days * 86400 ))
      (( diff >= need )) && return 0 || return 1
    fi
  fi

  # Pas de metadata lisible -> faire une sauvegarde
  return 0
}

# -------- DB backups --------
backup_mysql_database() {
  local db_name="$1" user="$2" pass="$3" backup_root="$4" ts="$5"
  local db_dir="${backup_root}/database"
  local tmp="${db_dir}/tmp_${db_name}_${ts}"
  mkdir -p "$tmp"

  echo "→ Dump MySQL ${db_name}"
  mysqldump -u "$user" -p"$pass" "$db_name" > "${tmp}/${db_name}.sql"
  mkdir -p "$db_dir"
  tar -C "$tmp" -czf "${db_dir}/${db_name}.tar.gz" "${db_name}.sql"
  rm -rf "$tmp"
}

backup_sqlite_database() {
  local db_name="$1" db_file="$2" backup_root="$3" ts="$4"
  local db_dir="${backup_root}/database"
  local tmp="${db_dir}/tmp_${db_name}_${ts}"
  mkdir -p "$tmp"

  echo "→ Copie SQLite ${db_name}"
  cp "$db_file" "${tmp}/${db_name}.db"
  mkdir -p "$db_dir"
  tar -C "$tmp" -czf "${db_dir}/${db_name}.tar.gz" "${db_name}.db"
  rm -rf "$tmp"
}

# -------- Files backups --------
backup_folders() {
  local folders="$1" base_dir="$2" ts="$3" versioned="$4" compress="$5"

  IFS=';' read -ra arr <<< "$folders"
  if [[ "$versioned" == "true" ]]; then
    local ver_dir="${base_dir}/backups/${ts}/files"
    mkdir -p "$ver_dir"
    for src in "${arr[@]}"; do
      [[ -z "$src" ]] && continue
      if [[ -d "$src" ]]; then
        local name; name=$(basename "$src")
        if [[ "$compress" == "true" ]]; then
          echo "→ Versionné + compressé: $src → ${ver_dir}/${name}.tar.gz"
          tar -C "$src" -czf "${ver_dir}/${name}.tar.gz" .
        else
          echo "→ Versionné: $src → ${ver_dir}/${name}/"
          mkdir -p "${ver_dir}/${name}"
          rsync -a --stats "$src/" "${ver_dir}/${name}/"
        fi
      else
        echo "⚠️  Dossier introuvable: $src"
      fi
    done
  else
    local live_dir="${base_dir}/files"
    mkdir -p "$live_dir"
    for src in "${arr[@]}"; do
      [[ -z "$src" ]] && continue
      if [[ -d "$src" ]]; then
        local name; name=$(basename "$src")
        echo "→ Sync non-versionné: $src → ${live_dir}/${name}/"
        mkdir -p "${live_dir}/${name}"
        rsync -a --stats --delete "$src/" "${live_dir}/${name}/"
      else
        echo "⚠️  Dossier introuvable: $src"
      fi
    done
  fi
}

# -------- Cleanup --------
cleanup_old_backups() {
  local base_dir="$1" keep="$2"
  local backups_dir="${base_dir}/backups"
  [[ -d "$backups_dir" ]] || return 0

  local count
  count=$(find "$backups_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
  if (( count > keep )); then
    find "$backups_dir" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" \
      | sort -r | tail -n +"$((keep + 1))" \
      | while read -r old; do
          rm -rf "${backups_dir}/${old}"
          echo "🧹 Suppression ancien backup dossier: ${old}"
        done
  fi
}

# -------- S3 (rclone) --------
transfer_to_s3() {
  local base_dir="$1" remote="$2"
  echo "→ Upload S3 (rclone sync)"
  # Sync de la racine locale vers remote/current, move des remplacements vers remote/trash
  rclone --size-only sync "${base_dir}" "${remote}/current" --backup-dir "${remote}/trash"
}

# -------- Metadata --------
write_metadata() {
  local backup_dir="$1" section="$2" ts="$3" db_type="$4" folders="$5" versioned="$6" compress="$7"
  local meta="${backup_dir}/metadata.json"
  local data=$(cat <<JSON
{
  "section": "$section",
  "date": "$ts",
  "database": { "enabled": $( [[ -n "$db_type" ]] && echo true || echo false ), "type": "${db_type:-}" },
  "files": { "paths": "$(echo "$folders" | sed 's/"/\\"/g')", "versioned": $([[ "$versioned" == "true" ]] && echo true || echo false), "compressed": $([[ "$compress" == "true" ]] && echo true || echo false) }
}
JSON
)
  if command -v jq >/dev/null 2>&1; then
    echo "$data" | jq -c . > "$meta"
  else
    echo "$data" > "$meta"
  fi
}

# -------- Section processing --------
process_section() {
  local section="$1" content="$2"

  local db_name="$section" db_type="" db_user="" db_password="" db_file=""
  local keep_versions=0 local_backup_path="" s3_bucket_name="" interval_days=0
  local folders_to_save="" files_versioned="false" files_compress="false"

  while IFS="=" read -r k v; do
    k=$(echo "$k" | tr '[:lower:]' '[:upper:]' | xargs); v=$(echo "$v" | xargs)
    case "$k" in
      DB_NAME) db_name="$v" ;;
      DB_TYPE) db_type="$v" ;;
      DB_USER) db_user="$v" ;;
      DB_PASSWORD) db_password="$v" ;;
      DB_FILE) db_file="$v" ;;
      KEEP_VERSIONS) keep_versions="$v" ;;
      LOCAL_BACKUP_PATH) local_backup_path="$v" ;;
      S3_BUCKET_NAME) s3_bucket_name="$v" ;;
      INTERVAL_DAYS) interval_days="$v" ;;
      FOLDER_TO_SAVE) folders_to_save="$v" ;;
      FILES_VERSIONED) files_versioned="$v" ;;
      FILES_COMPRESS) files_compress="$v" ;;
    esac
  done <<< "$content"

  [[ -n "$local_backup_path" ]] || { echo "⚠️  LOCAL_BACKUP_PATH manquant pour [$section], ignoré."; return; }
  mkdir -p "$local_backup_path"

  # Décision via metadata du dernier backup
  if (( force_backup == 0 )) && ! should_perform_backup "$local_backup_path" "$interval_days"; then
    echo "⏩ Pas de backup pour [$section] (intervalle non dépassé)."
    return
  fi

  local ts; ts=$(now_ts)
  local this_backup_root="${local_backup_path}/backups/${ts}"
  mkdir -p "$this_backup_root"

  echo "=== Backup [$section] @ ${ts} ==="

  # DB
  if [[ -n "$db_type" ]]; then
    mkdir -p "${this_backup_root}/database"
    case "$db_type" in
      mysql)  backup_mysql_database  "$db_name" "$db_user" "$db_password" "$this_backup_root" "$ts" ;;
      sqlite) backup_sqlite_database "$db_name" "$db_file" "$this_backup_root" "$ts" ;;
      *) echo "⚠️  DB_TYPE inconnu ($db_type) pour [$section], DB ignorée." ;;
    esac
  else
    echo "→ Aucune DB pour [$section]"
  fi

  # Files
  if [[ -n "$folders_to_save" ]]; then
    backup_folders "$folders_to_save" "$local_backup_path" "$ts" "$files_versioned" "$files_compress"
  fi

  # Metadata (dans le dossier du backup courant)
  write_metadata "$this_backup_root" "$section" "$ts" "$db_type" "$folders_to_save" "$files_versioned" "$files_compress"

  # Cleanup des versions de backups (dossiers horodatés)
  if (( keep_versions > 0 )); then
    cleanup_old_backups "$local_backup_path" "$keep_versions"
  fi

  # Upload S3 (entière racine locale)
  if [[ -n "$s3_bucket_name" ]]; then
    transfer_to_s3 "$local_backup_path" "$s3_bucket_name"
  fi

  echo "=== Fin backup [$section] ==="
  echo
}

# -------- INI reader --------
read_config_and_run() {
  local current="" block=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[(.*)\]$ ]]; then
      if [[ -n "$current" ]]; then
        [[ -z "$db_filter" || "$db_filter" == "$current" ]] && process_section "$current" "$block"
        block=""
      fi
      current="${BASH_REMATCH[1]}"
    else
      block+="$line"$'\n'
    fi
  done < "$CONFIG_FILE"

  if [[ -n "$current" ]]; then
    [[ -z "$db_filter" || "$db_filter" == "$current" ]] && process_section "$current" "$block"
  fi
}

# -------- MAIN --------
read_config_and_run
echo "✅ Sauvegardes terminées."