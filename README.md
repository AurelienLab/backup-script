# 🧰 Backup Script (V3)

Un script Bash complet et modulaire pour automatiser la sauvegarde de bases de données **MySQL / SQLite** et de **dossiers** avec support de versioning, compression et synchronisation S3 via **rclone**.

---

## 🚀 Fonctionnalités principales

- Sauvegardes organisées dans des dossiers datés (`YYYYMMDD_HHMMSS`)
- Gestion des intervalles de sauvegarde (pas de backup si intervalle non dépassé)
- Support MySQL / SQLite (fichiers `.tar.gz`)
- Sauvegarde de dossiers :
  - **Versionnée** (chaque backup contient une copie ou archive)
  - **Non versionnée** (synchronisée vers un dossier persistant)
- Option de **compression** des dossiers versionnés (`FILES_COMPRESS=true`)
- **Fichier metadata.json** par sauvegarde (date, type, contenu…)
- **Nettoyage automatique** des anciennes sauvegardes (`KEEP_VERSIONS`)
- **Synchronisation vers S3** via `rclone`
- Logs détaillés et mode `--debug`
- Vérification automatique des dépendances

---

## 📦 Dépendances requises

| Commande | Rôle |
|-----------|------|
| `jq` | lecture / écriture JSON (`metadata.json`) |
| `rclone` | synchronisation vers S3 ou autre backend |
| `rsync` | sauvegarde incrémentale de dossiers |
| `tar` | compression des bases et dossiers |
| `date` | gestion des intervalles de sauvegarde |

> 💡 Installation sur Debian / Ubuntu :
> ```bash
> sudo apt install jq rclone rsync tar coreutils
> ```

---

## ⚙️ Configuration (`config.conf`)

Fichier INI placé à côté du script (`backup.sh`).

### Exemple complet

```ini
[mon_projet]
LOCAL_BACKUP_PATH=/srv/backups/mon_projet
S3_BUCKET_NAME=s3:backups/mon_projet
INTERVAL_DAYS=1
KEEP_VERSIONS=3

# Base de données (facultatif)
DB_TYPE=mysql
DB_NAME=mon_site
DB_USER=root
DB_PASSWORD=secret

# Dossiers à sauvegarder
FOLDER_TO_SAVE=/var/www/mon_site;/etc/nginx
FILES_VERSIONED=true
FILES_COMPRESS=true
```

### Paramètres disponibles

| Clé | Description |
|-----|--------------|
| **LOCAL_BACKUP_PATH** | Dossier racine où stocker les sauvegardes locales |
| **S3_BUCKET_NAME** | Destination rclone (ex: `s3:backups/mon_projet`) |
| **INTERVAL_DAYS** | Nombre de jours entre deux backups |
| **KEEP_VERSIONS** | Nombre de versions à conserver |
| **DB_TYPE** | Type de base (`mysql`, `sqlite`, ou vide) |
| **DB_NAME** | Nom de la base de données |
| **DB_USER** / **DB_PASSWORD** | Identifiants MySQL |
| **DB_FILE** | Fichier SQLite à sauvegarder |
| **FOLDER_TO_SAVE** | Liste des dossiers séparés par `;` |
| **FILES_VERSIONED** | `true` → chaque backup a sa copie de fichiers |
| **FILES_COMPRESS** | `true` → compresse les fichiers versionnés (`.tar.gz`) |

---

## 🧠 Arborescence générée

```
LOCAL_BACKUP_PATH/
├── backups/
│   ├── 20251031_231720/
│   │   ├── metadata.json
│   │   ├── database/
│   │   │   └── site_db.tar.gz
│   │   └── files/
│   │       └── www.tar.gz
│   ├── 20251030_221500/
│   └── ...
├── files/            # dossiers non versionnés
└── metadata.json     # (optionnel, historique)
```

---

## 🔧 Utilisation

### Lancer le backup manuellement
```bash
./backup.sh
```

### Forcer une sauvegarde immédiate
```bash
./backup.sh --force
```

### Sauvegarder uniquement une section
```bash
./backup.sh --database mon_projet
```

### Activer les logs détaillés
```bash
./backup.sh --debug
```

### Vérifier uniquement les dépendances
```bash
./backup.sh --check
```

---

## 🧩 Fichier `metadata.json`

Chaque dossier de backup contient un fichier de métadonnées utilisé pour calculer les intervalles :

```json
{
  "section": "mon_projet",
  "date": "20251031_231720",
  "database": {
    "enabled": true,
    "type": "mysql"
  },
  "files": {
    "paths": "/var/www/mon_site;/etc/nginx",
    "versioned": true,
    "compressed": true
  }
}
```

---

## 🪣 Intégration avec rclone / S3

Le script utilise :
```bash
rclone --size-only sync LOCAL_BACKUP_PATH remote/current --backup-dir remote/trash
```

Configurer un remote `rclone` S3 :
```bash
rclone config
```
puis créer une section :
```
[backups]
type = s3
provider = AWS
env_auth = true
region = eu-west-1
bucket_acl = private
```

---

## 🧹 Nettoyage automatique

Le script supprime automatiquement les sauvegardes dépassant `KEEP_VERSIONS` :
- Les plus récentes sont conservées
- Les plus anciennes sont supprimées proprement

---

## 🧩 Exemple de cron (tous les jours à 2h du matin)

```
0 2 * * * /srv/scripts/backup.sh >> /var/log/backup.log 2>&1
```

---

## 🧾 Licence

MIT – libre d’utilisation, modification et redistribution.
