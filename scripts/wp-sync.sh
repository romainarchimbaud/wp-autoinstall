#!/usr/bin/env bash
# Synchro local, staging, prod (spec 002). Appelé par les cibles « Synchro » du Makefile, qui
# passent la config du .env en variables : LOCAL_URL, STAGING_SSH, STAGING_PATH, STAGING_URL,
# PROD_SSH, PROD_PATH, PROD_URL, THEME_SLUG, SYNC_EXCLUDES, WHAT. Environnements : local, staging, prod.
#
# Moteur (un verbe = une étape) :
#   dump <env>                    SQL des tables du site sur la sortie standard
#   transform <sql> <src> <cible> SQL prêt pour la cible (URL, préfixe, collations) sur la sortie standard
#   load <env> <sql>              backup local de la cible, import, purge des permaliens et du cache
#   files <src> <cible>           uploads, plugins, themes (hors thème enfant), sans --delete
# Commandes (questions puis enchaînement, pour make) :
#   run <src> <cible>   theme <env>   restore   backups-clean
#
# Le serveur ne reçoit qu'un SQL fini : tout se prépare dans la base temporaire sync_tmp du
# conteneur db. Rien n'est écrit sur le serveur hors la base et les fichiers du site.
# shellcheck disable=SC2029 # les commandes distantes sont composées ici, arguments passés par printf %q
set -euo pipefail

cd "$(dirname "$0")/.."
BACKUP_DIR=db_backups
# Backups gardés par environnement : purge automatique après chaque import réussi
BACKUP_KEEP=$(tr -d "\"' " <<< "${BACKUP_KEEP-}")
[[ $BACKUP_KEEP =~ ^[1-9][0-9]*$ ]] || BACKUP_KEEP=3
LOCAL_CONTENT=wordpress/wp-content
CONTENT_DIRS=(uploads plugins themes)
# Exclus de tout transfert, à la racine de chaque dossier : caches, sauvegardes, mises à jour en cours
RSYNC_EXCLUDES=(--exclude=/cache/ --exclude=/updraft/ --exclude=/upgrade/ --exclude=/upgrade-temp-backup/
	--exclude=/backups/ --exclude=.DS_Store)
TMP_DB=sync_tmp
WORK=""
# Avertissements de search-replace (classes de plugins non chargées) : comptés, expliqués à la fin
SKIPPED_LOG=$(mktemp)
# Dumps et backups contiennent les données du site : lisibles par ce seul compte
umask 077
# make garde les guillemets d'une valeur du .env : retirés ici
THEME_SLUG=$(tr -d "\"'" <<< "${THEME_SLUG-}")
SYNC_EXCLUDES=$(tr -d "\"'" <<< "${SYNC_EXCLUDES-}")
for e in $SYNC_EXCLUDES; do
	[[ $e =~ ^(uploads|plugins|themes)(/.*)?$ ]] || { echo "❌ SYNC_EXCLUDES : « $e » doit commencer par uploads, plugins ou themes." >&2; exit 1; }
done

die() { echo "❌ $*" >&2; exit 1; }
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; rm -f "$SKIPPED_LOG"; return 0; }
trap cleanup EXIT

# Questions : écrans whiptail dans un terminal (comme make setup), sinon une réponse par ligne sur
# l'entrée standard (printf '1\nyes\n' | make pull-prod). Les réponses sont lues sur le descripteur 4 :
# ssh et docker lisent /dev/null et ne consomment jamais les réponses suivantes.
UI=0
if [ -t 0 ] && [ -t 1 ] && command -v whiptail > /dev/null; then
	UI=1
	WT_TITLE="Synchro : $(basename "$PWD")"
	# shellcheck source=scripts/ui.sh
	. scripts/ui.sh
fi
exec 4<&0 < /dev/null

# Config ---------------------------------------------------------------------------
conf() { # conf <env> ssh|path|url
	local var
	var=$(printf '%s_%s' "$1" "$2" | tr '[:lower:]' '[:upper:]')
	[ -n "${!var-}" ] || case $2 in
		ssh) die "$var vide dans .env : lance make ssh-alias." ;;
		*) die "$var vide dans .env." ;;
	esac
	local v=${!var}
	[ "$2" = url ] && v=${v%/}
	printf '%s' "$v"
}

check_env() {
	case $1 in local|staging|prod) ;; *) die "environnement inconnu : « $1 » (local, staging ou prod)." ;; esac
}

# WP-CLI sur un environnement, sans charger thème ni plugins (un fatal PHP ne bloque rien).
# L'entrée standard est transmise (import).
# Nom de la commande WP-CLI sur un serveur : « wp » le plus souvent, mais certains hébergeurs
# l'installent sous « wp-cli » (Evoliatis). Forçable par WP_CMD dans .env ; résolu une fois par env.
declare -A WP_CMD_CACHE=()
wp_cmd() { # wp_cmd <env>
	local c=${WP_CMD-}
	[ -n "$c" ] && { printf '%s' "$c"; return 0; }
	c=${WP_CMD_CACHE[$1]-}
	[ -n "$c" ] && { printf '%s' "$c"; return 0; }
	# < /dev/null impératif : l'appelant (wp_on ... db import - < fichier.sql) redirige toute la
	# fonction, donc sans cela ce ssh consomme le SQL avant l'import, qui démarre alors au milieu
	# d'un INSERT (« ERROR at line 1: Unknown command »).
	c=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$(conf "$1" ssh)" \
		'for c in wp wp-cli; do command -v "$c" > /dev/null && { printf %s "$c"; exit 0; }; done; exit 4' \
		< /dev/null 2> /dev/null) || return 4
	printf '%s' "$c"
}

# Résout le nom de WP-CLI et le met en cache : hors substitution de commande, sinon l'affectation
# se perd avec le sous-shell et un ssh de détection repart à chaque appel distant.
wp_cmd_cached() { # wp_cmd_cached <env> — renseigne WP_CMD_CACHE[env]
	[ -n "${WP_CMD_CACHE[$1]-}" ] && return 0
	local c
	c=$(wp_cmd "$1") || return 4
	WP_CMD_CACHE[$1]=$c
}

wp_on() { # wp_on <env> <arguments wp>...
	if [ "$1" = local ]; then
		shift
		docker compose exec -T wordpress wp --skip-plugins --skip-themes "$@"
	else
		local ssh path cmd env=$1
		# wp_cmd_cached AVANT toute substitution : ainsi aucun ssh de détection ne tourne pendant
		# que l'entrée standard de cette fonction est un fichier SQL (cf. wp_cmd).
		wp_cmd_cached "$env" < /dev/null || die "$env : WP-CLI introuvable sur le serveur."
		ssh=$(conf "$1" ssh); path=$(conf "$1" path); cmd=${WP_CMD_CACHE[$env]}; shift
		ssh "$ssh" "cd $(printf '%q' "$path") && $cmd --skip-plugins --skip-themes $(printf '%q ' "$@")"
	fi
}

# MariaDB du conteneur db, en root (mot de passe lu dans le conteneur, jamais affiché)
db_root() {
	docker compose exec -T db sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"' sh "$@"
}

# Avant tout transfert : l'environnement répond et WP-CLI y trouve un WordPress installé
preflight() {
	local rc=0 ssh path
	if [ "$1" = local ]; then
		docker compose exec -T wordpress true 2> /dev/null || die "Conteneur wordpress arrêté : lance make up."
		return 0
	fi
	ssh=$(conf "$1" ssh); path=$(conf "$1" path); conf "$1" url > /dev/null
	ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh" \
		"cd $(printf '%q' "$path") 2> /dev/null || exit 3
		for c in ${WP_CMD:-wp wp-cli}; do command -v \$c > /dev/null && { \$c core is-installed --skip-plugins --skip-themes 2> /dev/null || exit 5; exit 0; }; done
		exit 4" || rc=$?
	case $rc in
		0) ;;
		3) die "$1 : dossier « $path » introuvable sur $ssh ($(printf '%s_PATH' "${1^^}") dans .env)." ;;
		4) die "$1 : WP-CLI absent sur $ssh (ni « wp » ni « wp-cli » dans le PATH d'une connexion ssh). S'il est installé sous un autre nom, l'indiquer par WP_CMD dans .env ; sinon le faire installer (hébergeur, ou https://wp-cli.org/fr/#installation)." ;;
		5) die "$1 : aucun WordPress installé dans « $path » sur $ssh (ou base injoignable depuis le serveur)." ;;
		*) die "$1 : alias SSH « $ssh » injoignable (code $rc). Tester : ssh $ssh ; le créer : make ssh-alias." ;;
	esac
}

# Dump mysqldump complet : sa dernière ligne est « -- Dump completed … » (absente si coupé en route)
check_dump() { # check_dump <fichier> <libellé>
	check_sql "$1" "$2"
	grep -q '^-- Dump completed' < <(tail -n 3 "$1") || die "$2 incomplet ($1) : rien n'a été écrit sur la cible."
}

check_sql() { # check_sql <fichier> <libellé>
	if [ ! -s "$1" ] || ! grep -q 'CREATE TABLE' "$1"; then
		die "$2 vide ou invalide ($1) : rien n'a été écrit sur la cible."
	fi
	# Une requête de plusieurs Mo sur une seule ligne est tronquée par le client mysql du serveur
	# (max_allowed_packet), qui répond alors « Unknown command » sur un fragment de chaîne.
	local long
	long=$(awk -v m=$((4 * 1024 * 1024)) 'length($0)>m {print NR": "int(length($0)/1048576)" Mo"; exit}' "$1")
	[ -z "$long" ] || echo "⚠️  $2 : une requête dépasse 4 Mo sur une seule ligne ($long). Si l'import échoue avec « Unknown command », c'est la cause : identifier la donnée avec sed -n '<ligne>p' $1 | head -c 300" >&2
}

# Questions ------------------------------------------------------------------------
cancel() { echo "❌ Annulé : rien n'a été modifié." >&2; exit 1; }

line() { # line <question> : une ligne de l'entrée standard
	local a
	printf '%s' "$1" >&2
	IFS= read -r -u 4 a || a=""
	printf '%s' "$a"
}

screen() { ask "$@" <&4; } # écran whiptail (ui.sh) : 0 Valider, 1 Retour, 255 Échap

# Confirmation avant toute écriture : PROD tapé pour la prod, yes ailleurs (règle unique).
# Retour (écran) : code 1, la question précédente est reposée.
confirm() { # confirm <env cible> <récapitulatif>
	local want=yes out rc=0
	[ "$1" = prod ] && want=PROD
	if [ $UI -eq 1 ]; then
		out=$(screen --inputbox "$2

Pour confirmer, tape $want" 18 78) || rc=$?
		case $rc in 0) ;; 1) return 1 ;; *) cancel ;; esac
	else
		echo "⚠️  $2" >&2
		out=$(line "Pour confirmer, tape $want : ")
	fi
	[ "$out" = "$want" ] || cancel
}

# Quoi copier : WHAT, sinon écran ou ligne ; Retour sur la première question la repose
ask_what() { # ask_what <src> <cible>
	local w=${WHAT-} rc=0
	if [ -z "$w" ] && [ $UI -eq 1 ]; then
		while :; do
			rc=0
			w=$(screen --menu "Copier quoi de $1 vers $2 ? (flèches pour choisir, Entrée pour valider)" 13 78 3 \
				all "Base et fichiers" db "Base seule" files "Fichiers seuls (uploads, plugins, thèmes hors thème enfant)") || rc=$?
			case $rc in 0) break ;; 1) ;; *) cancel ;; esac
		done
	elif [ -z "$w" ]; then
		case $(line "Quoi ? [1] tout [2] base [3] fichiers : ") in
			1) w=all ;; 2) w=db ;; 3) w=files ;; *) die "Réponse attendue : 1, 2 ou 3." ;;
		esac
	fi
	case $w in all|db|files) printf '%s' "$w" ;; *) die "WHAT=$w : attendu db, files ou all." ;; esac
}

label_what() { case $1 in all) echo "base et fichiers" ;; db) echo "base" ;; files) echo "fichiers" ;; esac; }

# Moteur ---------------------------------------------------------------------------
dump() { # dump <env>
	local tables
	tables=$(wp_on "$1" db tables --all-tables-with-prefix --format=csv)
	[ -n "$tables" ] || die "$1 : aucune table trouvée."
	wp_on "$1" db export - --tables="$tables"
}

transform() { # transform <sql> <src> <cible>
	local sql=$1 sp dp su du tables t renames=""
	check_dump "$sql" "Dump $2"
	sp=$(wp_on "$2" db prefix); dp=$(wp_on "$3" db prefix)
	su=$(conf "$2" url); du=$(conf "$3" url)
	echo "🔧 $2 → $3 : $su → $du, préfixe $sp → $dp (base temporaire $TMP_DB)" >&2

	db_root -e "DROP DATABASE IF EXISTS $TMP_DB; CREATE DATABASE $TMP_DB; GRANT ALL ON $TMP_DB.* TO 'userdb'@'%';"
	# La ligne « sandbox » des dumps MariaDB récents n'est comprise que par MariaDB : retirée
	sed '/^\/\*M!999999\\- enable the sandbox mode \*\//d' "$sql" | db_root "$TMP_DB"

	# Préfixe réécrit en SQL (tables, rôles, réglages utilisateur préfixés), pas par sed sur le dump
	if [ "$sp" != "$dp" ]; then
		tables=$(db_root -N "$TMP_DB" -e 'SHOW TABLES')
		for t in $tables; do
			[[ $t == "$sp"* ]] && renames+="${renames:+, }\`$t\` TO \`$dp${t#"$sp"}\`"
		done
		db_root "$TMP_DB" -e "RENAME TABLE $renames;
			UPDATE \`${dp}options\` SET option_name = '${dp}user_roles' WHERE option_name = '${sp}user_roles';
			UPDATE \`${dp}usermeta\` SET meta_key = CONCAT('$dp', SUBSTRING(meta_key, $((${#sp} + 1)))) WHERE meta_key LIKE '${sp//_/\\_}%';"
	fi
	# L'URL du .env doit être celle du site source, sinon rien ne serait remplacé (sans erreur)
	local home
	home=$(db_root -N "$TMP_DB" -e "SELECT option_value FROM \`${dp}options\` WHERE option_name = 'home'")
	[ "${home%/}" = "$su" ] || die "L'URL de $2 dans .env ($su) n'est pas celle du site ($home) : corrige ${2^^}_URL. Rien n'a été écrit sur $3."
	# URL échappées en JSON (éditeur de blocs : https:\/\/site.fr) : remplacées sur place dans la base temporaire
	docker compose exec -T -e WORDPRESS_DB_NAME="$TMP_DB" -e WORDPRESS_TABLE_PREFIX="$dp" wordpress \
		wp search-replace "${su//\//\\/}" "${du//\//\\/}" --all-tables --skip-columns=guid --skip-plugins --skip-themes --quiet \
		2>> "$SKIPPED_LOG"
	# CSS GenerateBlocks mis en cache par article : il garderait les URL et styles de la source
	db_root "$TMP_DB" -e "DELETE FROM \`${dp}options\` WHERE option_name LIKE 'generateblocks\\_dynamic\\_css\\_%';"
	# Transients : caches temporaires que WordPress régénère seul. Inutiles dans une migration, et
	# certains sont énormes (cache des Google Fonts : une ligne INSERT de plusieurs Mo, tronquée à
	# l'import chez un hébergeur, d'où « ERROR at line 1: Unknown command »).
	db_root "$TMP_DB" -e "DELETE FROM \`${dp}options\` WHERE option_name LIKE '\\_transient\\_%'
		OR option_name LIKE '\\_transient\\_timeout\\_%' OR option_name LIKE '\\_site\\_transient\\_%'
		OR option_name LIKE '\\_site\\_transient\\_timeout\\_%';"

	# En-tête d'un dump mysqldump, absent de --export : sans lui, MySQL 8 en mode strict refuse
	# les dates par défaut 0000-00-00 des tables WordPress (erreur 1067)
	printf '%s\n' 'SET NAMES utf8mb4;' "SET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO';" 'SET FOREIGN_KEY_CHECKS = 0;'
	docker compose exec -T -e WORDPRESS_DB_NAME="$TMP_DB" -e WORDPRESS_TABLE_PREFIX="$dp" wordpress \
		wp search-replace "$su" "$du" --all-tables --precise --skip-columns=guid --skip-plugins --skip-themes --export 2>> "$SKIPPED_LOG" |
		# Collations propres à un moteur, inconnues de l'autre (« Unknown collation » à l'import) :
		# _uca1400_ (MariaDB 11) refusées par MySQL 8, _0900_ (MySQL 8) refusées par MariaDB.
		sed -E -e 's/utf8mb3_uca1400_ai_ci/utf8mb3_general_ci/g' -e 's/[a-z0-9]+_uca1400_ai_ci/utf8mb4_unicode_ci/g' \
			-e 's/[a-z0-9]+_0900_[a-z_]+/utf8mb4_unicode_ci/g'
	db_root -e "DROP DATABASE $TMP_DB;"
}

# Backup de wp-content avant écrasement, par liens durs : instantané, et ne coûte du disque que
# pour les fichiers réellement remplacés ensuite (rsync écrit un nouveau fichier au lieu de modifier
# l'ancien, que le backup garde). Local seulement : pas de liens durs à travers ssh sans déposer
# d'outils sur le serveur. Même horodatage que le backup de base : un seul point de retour.
backup_files() { # backup_files <env cible> <horodatage>
	[ "$1" = local ] || { backup_files_remote "$1" "$2"; return $?; }
	[ -d "$LOCAL_CONTENT" ] || return 0
	local dir=$BACKUP_DIR/local_$2_files
	mkdir -p "$BACKUP_DIR"
	rm -rf "$dir.part"
	# cp -al échoue si la cible existe : on copie chaque dossier du site, pas wp-content entier
	mkdir -p "$dir.part"
	local d
	for d in "${CONTENT_DIRS[@]}"; do
		[ -d "$LOCAL_CONTENT/$d" ] || continue
		cp -al "$LOCAL_CONTENT/$d" "$dir.part/$d" 2> /dev/null ||
			cp -a "$LOCAL_CONTENT/$d" "$dir.part/$d" || { rm -rf "$dir.part"; die "Backup des fichiers de local échoué : rien n'a été transféré."; }
	done
	mv "$dir.part" "$dir"
	echo "💾 Backup des fichiers de local : $dir" >&2
}

# Sur un serveur, le backup des fichiers se fait sur place, par liens durs (cp -al) : instantané
# et quasi gratuit en disque, même sur un gros site. Déposé à CÔTÉ du dossier du site
# (<site>-wp-backups), jamais dedans : il n'est ni servi par le web, ni repris par une synchro.
# Un seul point gardé par environnement : le précédent est remplacé.
REMOTE_BACKUP_SUFFIX=-wp-backups
backup_files_remote() { # backup_files_remote <env> <horodatage>
	local ssh path dirs
	ssh=$(conf "$1" ssh); path=$(conf "$1" path)
	dirs=$(printf '%s ' "${CONTENT_DIRS[@]}")
	echo "💾 Backup des fichiers de $1 (sur le serveur)..." >&2
	ssh -o BatchMode=yes "$ssh" "set -e
		site=$(printf '%q' "$path"); bk=\$site$REMOTE_BACKUP_SUFFIX
		[ -d \"\$site/wp-content\" ] || exit 0
		rm -rf \"\$bk.part\"; mkdir -p \"\$bk.part\"
		for d in $dirs; do
			[ -d \"\$site/wp-content/\$d\" ] || continue
			cp -al \"\$site/wp-content/\$d\" \"\$bk.part/\$d\" 2> /dev/null || cp -a \"\$site/wp-content/\$d\" \"\$bk.part/\$d\"
		done
		rm -rf \"\$bk\"; mv \"\$bk.part\" \"\$bk\"
		printf '%s' \"\$bk\"" < /dev/null > /dev/null ||
		die "$1 : backup des fichiers sur le serveur échoué. Rien n'a été transféré."
	echo "   → $path$REMOTE_BACKUP_SUFFIX sur $ssh (remplacé à chaque synchro)" >&2
}

load() { # load <env> <sql>
	local backup prefix
	check_sql "$2" "SQL à importer"
	# Un backup d'un autre site (ancien alias, autre serveur) ajouterait ses tables sans rien remplacer
	prefix=$(wp_on "$1" db prefix)
	if grep -oE "CREATE TABLE \`[^\`]+\`" "$2" | grep -v "CREATE TABLE \`$prefix" > /dev/null; then
		die "$2 : des tables n'ont pas le préfixe $prefix de $1 (backup d'un autre site ?). Rien n'a été importé."
	fi
	mkdir -p "$BACKUP_DIR"
	backup=$BACKUP_DIR/$1_${3:-$(date +%Y%m%d_%H%M%S)}.sql
	echo "💾 Backup de $1 : $backup" >&2
	# Écrit en .part puis renommé : un backup coupé n'est jamais proposé par make restore
	dump "$1" > "$backup.part" || { rm -f "$backup.part"; die "Backup de $1 échoué : rien n'a été importé."; }
	(check_dump "$backup.part" "Backup de $1") || { rm -f "$backup.part"; exit 1; }
	mv "$backup.part" "$backup"
	echo "📥 Import dans $1..." >&2
	wp_on "$1" db import - < "$2" || die "Import dans $1 échoué : la base peut être incomplète. Revenir à l'état d'avant : make restore ($backup)."
	# Permaliens : flush complet (plugins chargés, pour leurs types de contenu) ; si un plugin
	# plante, on vide les règles et WordPress les régénère à la prochaine page.
	if [ "$1" = local ]; then
		docker compose exec -T wordpress wp rewrite flush > /dev/null 2>&1 || wp_on "$1" option delete rewrite_rules > /dev/null
	else
		ssh "$(conf "$1" ssh)" "cd $(printf '%q' "$(conf "$1" path)") && $(wp_cmd "$1") rewrite flush" > /dev/null 2>&1 ||
			wp_on "$1" option delete rewrite_rules > /dev/null
	fi
	wp_on "$1" cache flush > /dev/null
	# Import réussi : les anciens points de retour peuvent partir (jamais avant, ni si l'import échoue)
	QUIET_CLEAN=1 backups_clean "$1" > /dev/null
	echo "✅ Base $1 importée (restaurer l'état d'avant : make restore)." >&2
	# Une migration (pull, UpdraftPlus, import à la main) remplace les comptes : le .env ne les décrit plus
	if [ "$1" = local ]; then check_admin_creds; fi
}

# Dossier wp-content d'un environnement, au format rsync
content_of() {
	if [ "$1" = local ]; then printf '%s' "$LOCAL_CONTENT"
	else printf '%s:%s/wp-content' "$(conf "$1" ssh)" "$(conf "$1" path)"; fi
}

same_host() { # deux alias vers le même compte du même serveur ?
	[ "$(ssh -G "$(conf "$1" ssh)" | grep -E '^(hostname|port|user) ')" = "$(ssh -G "$(conf "$2" ssh)" | grep -E '^(hostname|port|user) ')" ]
}

fail_files() { die "Copie de $1 vers $2 échouée (rsync, voir ci-dessus) : la base de $2 n'a pas été touchée."; }

files() { # files <src> <cible>
	local d e opts src dst relay=""
	[ "$1" = local ] || { conf "$1" ssh > /dev/null; conf "$1" path > /dev/null; }
	[ "$2" = local ] || { conf "$2" ssh > /dev/null; conf "$2" path > /dev/null; }
	[ "$1" != local ] && [ "$2" != local ] && ! same_host "$1" "$2" && WORK=${WORK:-$(mktemp -d)} && relay=$WORK/files
	for d in "${CONTENT_DIRS[@]}"; do
		opts=("${RSYNC_EXCLUDES[@]}")
		# Le thème enfant vient de git et se déploie à part (make deploy-theme-*)
		[ "$d" = themes ] && [ -n "${THEME_SLUG-}" ] && opts+=("--exclude=/$THEME_SLUG/")
		for e in $SYNC_EXCLUDES; do
			[ "$e" = "$d" ] && continue 2
			[[ $e == "$d"/* ]] && opts+=("--exclude=/${e#"$d"/}")
		done
		echo "📦 $d : $1 → $2" >&2
		src=$(content_of "$1")/$d/; dst=$(content_of "$2")/$d/
		if [ "$2" = local ]; then mkdir -p "$LOCAL_CONTENT/$d"; fi
		if [ "$1" = local ] || [ "$2" = local ]; then
			rsync -az "${opts[@]}" "$src" "$dst" || fail_files "$d" "$2"
		elif [ -z "$relay" ]; then
			# Même serveur : copie sur place, rien ne transite par le poste
			ssh "$(conf "$1" ssh)" "rsync -a $(printf '%q ' "${opts[@]}") $(printf '%q' "$(conf "$1" path)/wp-content/$d/") $(printf '%q' "$(conf "$2" path)/wp-content/$d/")" || fail_files "$d" "$2"
		else
			mkdir -p "$relay/$d"
			rsync -az "${opts[@]}" "$src" "$relay/$d/" || fail_files "$d" "$2"
			rsync -az "${opts[@]}" "$relay/$d/" "$dst" || fail_files "$d" "$2"
		fi
	done
	echo "✅ Fichiers copiés : $1 → $2 (aucune suppression)." >&2
}

# Commandes ------------------------------------------------------------------------
run() { # run <src> <cible>
	local what txt
	check_env "$1"; check_env "$2"
	preflight "$1"; preflight "$2"
	while :; do
		what=$(ask_what "$1" "$2")
		txt=$(label_what "$what")
		# Ce que contiendra le point de retour : les fichiers ne sont sauvegardés qu'en local
		local saved=base
		[ "$what" = files ] && saved=""
		[ "$2" = local ] && [ "$what" != db ] && saved="base et fichiers"
		[ "$2" = local ] && [ "$what" = files ] && saved=fichiers
		if [ -n "$saved" ]; then
			saved="Point de retour créé avant : $saved (make restore)."
		else
			saved="Pas de point de retour (fichiers seuls sur un serveur) : rien n'est supprimé, les fichiers sont ajoutés ou remplacés."
		fi
		confirm "$2" "Récapitulatif

Source   : $1 ($(conf "$1" url))
Cible    : $2 ($(conf "$2" url))
Contenu  : $txt$([ "$what" != db ] && printf '\nThème    : %s' "${THEME_SLUG:-aucun thème enfant exclu (THEME_SLUG vide) : tous les thèmes sont copiés}")

Écrase $txt de $2. $saved" && break
		[ -z "${WHAT-}" ] || cancel
	done
	WORK=$(mktemp -d)
	# Un seul horodatage : le backup des fichiers et celui de la base forment un point de retour
	local stamp; stamp=$(date +%Y%m%d_%H%M%S)
	# Purge avant de créer le nouveau point : sinon les backups d'une synchro échouée s'accumulent
	# (la purge de fin de load ne tourne qu'après un import réussi).
	QUIET_CLEAN=1 backups_clean "$2" > /dev/null
	# Fichiers d'abord (sans suppression) : un rsync en échec arrête tout avant l'écrasement de la base
	if [ "$what" != db ]; then
		backup_files "$2" "$stamp"
		files "$1" "$2"
	fi
	if [ "$what" != files ]; then
		echo "📤 Export de $1..." >&2
		dump "$1" > "$WORK/src.sql"
		transform "$WORK/src.sql" "$1" "$2" > "$WORK/dst.sql"
		load "$2" "$WORK/dst.sql" "$stamp"
	fi
	echo "✅ Synchro terminée : $1 → $2 ($txt)."
	if [ "$2" != local ] && [ "$what" != db ]; then
		echo "ℹ️  Un backup des fichiers de $2 est resté sur le serveur ($(conf "$2" path)$REMOTE_BACKUP_SUFFIX)." >&2
		echo "   Il est remplacé à chaque synchro. Pour l'effacer maintenant : make backups-purge" >&2
	fi
	skipped_note "$1"
}

theme() { # theme <env> : build puis envoi du thème enfant, le distant devient le local moins .deployignore
	local slug dir dest
	check_env "$1"; [ "$1" != local ] || die "deploy-theme vise staging ou prod."
	slug=${THEME_SLUG-}; [ -n "$slug" ] || die "THEME_SLUG vide dans .env."
	dir=$LOCAL_CONTENT/themes/$slug
	[ -d "$dir" ] || die "Thème introuvable : $dir"
	preflight "$1"
	dest=$(content_of "$1")/themes/$slug/
	confirm "$1" "Récapitulatif

Thème    : $slug
Cible    : $1 ($dest)

Le distant devient le thème local moins .deployignore : ses fichiers absents du local sont supprimés." || cancel
	if [ -f "$dir/package.json" ] && grep -Eq '"build"[[:space:]]*:' "$dir/package.json"; then
		echo "🔨 npm run build..." >&2
		if docker compose exec -T wordpress sh -c 'command -v npm' > /dev/null 2>&1; then
			docker compose exec -T -w "/var/www/html/wp-content/themes/$slug" wordpress npm run build
		elif command -v npm > /dev/null; then
			(cd "$dir" && npm run build)
		else
			die "npm absent (conteneur et poste) : coche npm dans make setup puis make build."
		fi
	fi
	# Jamais sur un serveur, .deployignore ou pas
	local opts=(--delete --delete-excluded --exclude=.git/ --exclude=node_modules/ --exclude=.env)
	[ -f "$dir/.deployignore" ] && opts+=("--exclude-from=$dir/.deployignore")
	rsync -az "${opts[@]}" "$dir/" "$dest"
	echo "✅ Thème $slug déployé sur $1."
}

restore() {
	local env="" files=() f n pick="" step=0 rc items=()
	while :; do
		rc=0
		case $step in
			0) if [ $UI -eq 1 ]; then
					env=$(screen --menu "Restaurer quel environnement ? (flèches pour choisir, Entrée pour valider)" 12 70 3 \
						local "Base locale" staging "Staging" prod "Prod") || rc=$?
				else
					case $(line "Restaurer quel environnement ? [1] local [2] staging [3] prod : ") in
						1) env=local ;; 2) env=staging ;; 3) env=prod ;; *) die "Réponse attendue : 1, 2 ou 3." ;;
					esac
				fi
				case $rc in 0) ;; 1) continue ;; *) cancel ;; esac
				mapfile -t files < <(ls -t "$BACKUP_DIR/${env}"_*.sql 2> /dev/null)
				if [ ${#files[@]} -eq 0 ]; then
					[ $UI -eq 1 ] || die "Aucun backup de $env dans $BACKUP_DIR/."
					screen --msgbox "Aucun backup de $env dans $BACKUP_DIR/." 8 70 || true; continue
				fi
				step=1 ;;
			1) if [ $UI -eq 1 ]; then
					items=(); n=1
					for f in "${files[@]}"; do items+=("$n" "${f#"$BACKUP_DIR"/}"); n=$((n + 1)); done
					pick=$(screen --menu "Backup à restaurer, le plus récent en haut
(flèches pour choisir, Entrée pour valider)" 20 78 8 "${items[@]}") || rc=$?
					case $rc in 0) ;; 1) step=0; continue ;; *) cancel ;; esac
				else
					n=1
					for f in "${files[@]}"; do echo "  [$n] $f" >&2; n=$((n + 1)); done
					pick=$(line "Backup à restaurer [1, le plus récent] : "); pick=${pick:-1}
				fi
				[[ $pick =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#files[@]} ] || die "Numéro invalide : $pick"
				f=${files[$((pick - 1))]}
				step=2 ;;
			2) confirm "$env" "Récapitulatif

Cible    : $env
Backup   : $f
Fichiers : $(if [ "$env" != local ]; then echo "restaurés depuis le backup du serveur, s'il existe"; elif files_of_backup "$f" > /dev/null; then echo "restaurés avec la base (uploads, plugins, themes)"; else echo "base seule (pas de backup de fichiers pour ce point)"; fi)

L'état actuel de $env est sauvegardé avant (restaurable à son tour)." && break
				[ $UI -eq 1 ] || cancel
				step=1 ;;
		esac
	done
	preflight "$env"
	local fdir
	fdir=$(files_of_backup "$f") || fdir=""
	load "$env" "$f"
	restore_files "$env" "$fdir"
	return 0
}

# Dossier de fichiers associé à un backup de base (même horodatage), s'il existe
files_of_backup() { # files_of_backup <backup.sql>
	local d=${1%.sql}_files
	[ -d "$d" ] || return 1
	printf '%s' "$d"
}

# Remet wp-content depuis un backup : les fichiers du backup écrasent ceux du site. Les fichiers
# ajoutés depuis ne sont pas supprimés (on ne détruit jamais ce que la spec ne nomme pas).
restore_files() { # restore_files <env> <dossier de backup local, vide pour un serveur>
	local d
	if [ "$1" = local ]; then
		[ -n "${2-}" ] && [ -d "$2" ] || return 0
		echo "📦 Restauration des fichiers depuis $2..." >&2
		for d in "${CONTENT_DIRS[@]}"; do
			[ -d "$2/$d" ] || continue
			rsync -a "$2/$d/" "$LOCAL_CONTENT/$d/" || die "Restauration des fichiers échouée ($d) : la base, elle, a été restaurée."
		done
	else
		local ssh path dirs
		ssh=$(conf "$1" ssh); path=$(conf "$1" path); dirs=$(printf '%s ' "${CONTENT_DIRS[@]}")
		echo "📦 Restauration des fichiers de $1 depuis le backup du serveur..." >&2
		local out
		out=$(ssh -o BatchMode=yes "$ssh" "set -e
			site=$(printf '%q' "$path"); bk=\$site$REMOTE_BACKUP_SUFFIX
			[ -d \"\$bk\" ] || { echo ABSENT; exit 0; }
			for d in $dirs; do
				[ -d \"\$bk/\$d\" ] || continue
				rsync -a \"\$bk/\$d/\" \"\$site/wp-content/\$d/\"
			done" < /dev/null) || die "Restauration des fichiers de $1 échouée : la base, elle, a été restaurée."
		if [ "$out" = ABSENT ]; then
			echo "ℹ️  Aucun backup de fichiers sur $ssh : seule la base a été restaurée." >&2
			return 0
		fi
	fi
	echo "✅ Fichiers restaurés (les fichiers ajoutés depuis le backup sont conservés)." >&2
}

# Les comptes du .env ne décrivent plus la base après une migration (pull, UpdraftPlus, import
# à la main) : on ne détecte pas la migration mais son effet, et on vide les deux lignes plutôt
# que d'y écrire un mot de passe qu'on ne connaît pas (WordPress n'en garde qu'une empreinte).
# Jamais bloquant : une base injoignable ou un .env absent laisse tout en place.
check_admin_creds() {
	local u p env=.env
	[ -f $env ] || return 0
	u=$(grep -E '^WORDPRESS_ADMIN_USER=' $env | tail -n 1 | cut -d= -f2- | tr -d "\"'") || return 0
	p=$(grep -E '^WORDPRESS_ADMIN_PASSWORD=' $env | tail -n 1 | cut -d= -f2- | tr -d "\"'") || return 0
	# Déjà vidées par un passage précédent, ou jamais renseignées : rien à faire
	[ -n "$u" ] && [ -n "$p" ] || return 0
	# L'utilisateur doit exister : sinon (base injoignable, compte absent) on ne conclut rien
	docker compose exec -T -e U="$u" wordpress sh -c 'wp user get "$U" --field=ID' > /dev/null 2>&1 || return 0
	docker compose exec -T -e U="$u" -e P="$p" wordpress \
		sh -c 'wp user check-password "$U" "$P"' > /dev/null 2>&1 && return 0
	sed -i 's|^WORDPRESS_ADMIN_USER=.*|WORDPRESS_ADMIN_USER=|; s|^WORDPRESS_ADMIN_PASSWORD=.*|WORDPRESS_ADMIN_PASSWORD=|' $env
	grep -q '^# Comptes remplacés par la dernière migration' $env ||
		sed -i '/^WORDPRESS_ADMIN_USER=/i # Comptes remplacés par la dernière migration : voir la base importée' $env
	echo "ℹ️  Les comptes du .env ne correspondent plus à la base : connecte-toi avec ceux du site importé." >&2
	echo "   WORDPRESS_ADMIN_USER et WORDPRESS_ADMIN_PASSWORD ont été vidés (ils ne servaient qu'à make install)." >&2
}

# « Skipping an uninitialized class » : search-replace tourne avec --skip-plugins (une extension
# cassée ne doit pas faire échouer une synchro), donc il ne désérialise pas les objets de plugins
# et prévient au lieu de les corrompre. Sans conséquence en général : ces valeurs sont des données
# internes de plugins (journaux, caches), pas du contenu affiché.
# Cherche en local les URL d'un environnement distant restées après une synchro. Toutes ne sont pas
# des erreurs : le nom de domaine cité dans un texte (mentions légales) ou une adresse e-mail est
# normal, seule une URL complète (https://…) dans un contenu ou une option mérite un coup d'œil.
check_urls() { # check_urls [env source]
	local env=${1:-} url host n p table col e
	if [ -z "$env" ]; then
		# Sans argument : les URL du .env. Si une synchro a été lancée avec une autre URL en ligne
		# de commande (PROD_URL=… make pull-prod), c'est celle-là qu'il faut repasser ici.
		[ "${STAGING_URL-}" != "${PROD_URL-}" ] || echo "ℹ️  STAGING_URL et PROD_URL sont identiques dans .env : un seul contrôle." >&2
		for e in staging prod; do
			local v=${e^^}_URL
			[ -n "${!v-}" ] && check_urls "$e"
			[ "${STAGING_URL-}" != "${PROD_URL-}" ] || break
		done
		return 0
	fi
	check_env "$env"
	preflight local
	url=$(conf "$env" url); host=${url#*://}; host=${host%%/*}
	p=$(docker compose exec -T wordpress wp db prefix --skip-plugins --skip-themes 2> /dev/null | tr -d '\r\n')
	echo "🔍 URL de $env ($host) restées dans la base locale :" >&2
	for t in "options:option_value" "posts:post_content" "postmeta:meta_value"; do
		IFS=: read -r table col <<< "$t"
		n=$(docker compose exec -T wordpress wp db query \
			"SELECT COUNT(*) FROM \`${p}${table}\` WHERE \`$col\` LIKE '%${host}%'" \
			--skip-plugins --skip-themes 2> /dev/null | sed -n '2p') || n=""
		echo "   ${p}${table} : ${n:-?}" >&2
	done
	echo "   Détail : wp db query \"SELECT … LIKE '%${host}%'\", ou wp search-replace '$url' '\$LOCAL_URL' --dry-run --all-tables" >&2
}

skipped_note() { # skipped_note <env source>
	local n classes
	n=$(grep -c 'Skipping an uninitialized class' "$SKIPPED_LOG" 2> /dev/null) || n=0
	[ "$n" -gt 0 ] || return 0
	classes=$(grep -o 'class "[^"]*"' "$SKIPPED_LOG" | sort -u | sed 's/class //' | paste -sd' ' -)
	echo "ℹ️  $n avertissement(s) « uninitialized class » de search-replace." >&2
	echo "   Normal : les plugins ne sont pas chargés pendant la réécriture des URL." >&2
	echo "   Classes concernées : $classes" >&2
	echo "   Vérifier si des URL de $1 sont restées : make check-urls" >&2
}

# Tout supprimer (comme « delete all » d'UpdraftPlus) : pour libérer la place quand les points de
# retour ne servent plus. Demande confirmation : après, plus aucun make restore n'est possible.
# Backup de fichiers laissé sur un serveur : présent ? et quel poids ?
remote_backup_info() { # remote_backup_info <env> — « <chemin> <taille> » ou rien
	local ssh path
	ssh=$(conf "$1" ssh 2> /dev/null) || return 1
	path=$(conf "$1" path 2> /dev/null) || return 1
	ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh" \
		"bk=$(printf '%q' "$path")$REMOTE_BACKUP_SUFFIX; [ -d \"\$bk\" ] || exit 1; printf '%s %s' \"\$bk\" \"\$(du -sh \"\$bk\" | cut -f1)\"" \
		< /dev/null 2> /dev/null || return 1
}

# Supprime le backup de fichiers d'un serveur (le « delete all folders » d'UpdraftPlus)
remote_backup_delete() { # remote_backup_delete <env>
	local ssh path
	ssh=$(conf "$1" ssh 2> /dev/null) || return 0
	path=$(conf "$1" path 2> /dev/null) || return 0
	ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh" \
		"rm -rf $(printf '%q' "$path")$REMOTE_BACKUP_SUFFIX*" < /dev/null 2> /dev/null ||
		echo "⚠️  $1 : suppression du backup distant impossible (serveur injoignable ?)." >&2
}

backups_purge() {
	local n place env info remotes=""
	n=$(find "$BACKUP_DIR" -maxdepth 1 \( -name '*.sql' -o -name '*_files' \) 2> /dev/null | wc -l)
	# Backups déposés sur les serveurs : ils comptent aussi, c'est ce qu'on ne veut pas laisser traîner
	for env in staging prod; do
		info=$(remote_backup_info "$env") && remotes="$remotes
   $env : $info"
	done
	if [ "$n" -eq 0 ] && [ -z "$remotes" ]; then echo "✅ Aucun backup à supprimer." >&2; return 0; fi
	place=$(du -sh "$BACKUP_DIR" 2> /dev/null | cut -f1)
	if [ $UI -eq 1 ]; then
		screen --yesno "Supprimer TOUS les backups ?

$n point(s) de retour en local, $place.${remotes:+
Sur les serveurs :$remotes}

Après, plus aucun make restore n'est possible." 16 74 || cancel
	else
		echo "⚠️  $n point(s) de retour en local, $place.${remotes:+ Sur les serveurs :$remotes}" >&2
		echo "   Après, plus aucun make restore n'est possible." >&2
		[ "$(line "Pour confirmer, tape yes : ")" = yes ] || cancel
	fi
	rm -rf "$BACKUP_DIR"/*.sql "$BACKUP_DIR"/*_files "$BACKUP_DIR"/*.part
	for env in staging prod; do remote_backup_delete "$env"; done
	echo "✅ Backups supprimés, en local ($place libérés) et sur les serveurs." >&2
}

# Rétention : plusieurs points en local (on s'y trompe, on recommence), un seul pour staging et
# prod (une mise en ligne est un geste ponctuel ; le backup ne sert qu'à revenir dans la minute).
# Tous les backups sont locaux : rien n'est jamais déposé sur un serveur.
keep_for() { # keep_for <env>
	[ "$1" = local ] && { printf '%s' "$BACKUP_KEEP"; return 0; }
	printf '1'
}

backups_clean() { # backups_clean <env>...
	local env old keep
	for env in "$@"; do
		keep=$(keep_for "$env")
		# shellcheck disable=SC2012
		while IFS= read -r old; do
			# Le dossier de fichiers du même point de retour part avec son SQL
			rm -rf "${old%.sql}_files"
			rm -f -- "$old"
		done < <(ls -t "$BACKUP_DIR/${env}"_*.sql 2> /dev/null | tail -n +$((keep + 1)))
	done
	# Restes d'un backup interrompu : jamais un point de retour valide. Un dossier _files sans .sql
	# est légitime (synchro WHAT=files : les fichiers seuls sont sauvegardés), il n'est donc pas
	# supprimé ici — la rétention par environnement s'en charge, ci-dessous.
	rm -rf "$BACKUP_DIR"/*.part "$BACKUP_DIR"/*_files.part 2> /dev/null || true
	# Rétention des dossiers de fichiers sans .sql associé (WHAT=files) : mêmes règles que les bases
	for env in "$@"; do
		keep=$(keep_for "$env")
		# shellcheck disable=SC2012
		while IFS= read -r old; do
			[ -f "${old%_files}.sql" ] || rm -rf "$old"
		done < <(ls -td "$BACKUP_DIR/${env}"_*_files 2> /dev/null | tail -n +$((keep + 1)))
	done
	[ "${QUIET_CLEAN-}" = 1 ] || echo "✅ Backups : $BACKUP_KEEP gardés pour local, 1 pour staging et prod." >&2
}

case ${1-} in
	dump) check_env "${2-}"; dump "$2" ;;
	transform) [ $# -eq 4 ] || die "usage : $0 transform <sql> <src> <cible>"; check_env "$3"; check_env "$4"; transform "$2" "$3" "$4" ;;
	load) [ $# -eq 3 ] || die "usage : $0 load <env> <sql>"; check_env "$2"; load "$2" "$3" ;;
	files) [ $# -eq 3 ] || die "usage : $0 files <src> <cible>"; check_env "$2"; check_env "$3"; files "$2" "$3" ;;
	run) [ $# -eq 3 ] || die "usage : $0 run <src> <cible>"; run "$2" "$3" ;;
	theme) theme "${2-}" ;;
	restore) restore ;;
	backups-clean) backups_clean local staging prod ;;
	backups-purge) backups_purge ;;
	check-urls) check_urls "${2-}" ;;
	*) die "usage : $0 dump|transform|load|files|run|theme|restore|backups-clean …" ;;
esac
