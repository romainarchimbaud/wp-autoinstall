#!/usr/bin/env bash
# make setup  : questionnaire (whiptail) qui écrit .env, ports libres choisis automatiquement.
# make doctor : bash scripts/setup.sh doctor, vérifie que les ports du .env sont utilisables.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
ENV_FILE=.env
EXAMPLE=.env.example
REGISTRY_DIR=$HOME/.config/wp-autoinstall
REGISTRY=$REGISTRY_DIR/ports
TMP_ENV=""
# Ports souvent déjà pris par d'anciens projets (WordPress, phpMyAdmin) : jamais attribués
LEGACY_PORTS="80 8080"

die() { echo "❌ $*" >&2; exit 1; }
trap '[ -n "$TMP_ENV" ] && rm -f "$TMP_ENV"' EXIT

# Lecture du .env ---------------------------------------------------------------
# Valeur d'une clé, déséchappée comme la lit Compose ("…" : \\ \" $$ ; '…' : littéral).
env_get() { # env_get CLÉ FICHIER
	local line v out="" i c
	[ -f "$2" ] || return 0
	line=$(grep -E "^$1=" "$2" | tail -n 1) || return 0
	v=${line#*=}
	case $v in
		\"*)
			v=${v:1}
			for ((i = 0; i < ${#v}; i++)); do
				c=${v:i:1}
				if [ "$c" = '\' ]; then i=$((i + 1)); out+=${v:i:1}
				elif [ "$c" = '$' ] && [ "${v:i+1:1}" = '$' ]; then i=$((i + 1)); out+='$'
				elif [ "$c" = '"' ]; then break
				else out+=$c; fi
			done
			printf '%s' "$out" ;;
		\'*) v=${v:1}; printf '%s' "${v%\'}" ;;
		*) printf '%s' "$v" ;;
	esac
}

# Écriture au format .env : brut si sans risque, sinon entre guillemets échappés (cf. spec 004, T2).
env_fmt() {
	local s=$1
	local safe='[A-Za-z0-9_./:@%+,=-]+'
	if [ -z "$s" ] || [[ $s =~ ^$safe(\ $safe)*$ ]]; then printf '%s' "$s"; return; fi
	s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\$\$}
	printf '"%s"' "$s"
}

# URL distante : vide, ou http(s)://domaine.tld[/chemin] sans espace ; slash final retiré
url_ok() { [ -z "$1" ] || [[ $1 =~ ^https?://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/[^[:space:]]*)?$ ]]; }

gen_secret() { # lettres et chiffres
	local s=""
	while [ ${#s} -lt "$1" ]; do s+=$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9'); done
	printf '%s' "${s:0:$1}"
}

# Ports ---------------------------------------------------------------------------
listening() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

# Ports publiés par tous les conteneurs, même arrêtés : "port<TAB>dossier<TAB>projet<TAB>conteneur"
docker_ports() {
	local ids
	ids=$(docker ps -aq 2>/dev/null) || return 0
	[ -n "$ids" ] || return 0
	# shellcheck disable=SC2086
	docker inspect --format '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.Name}}' $ids 2>/dev/null |
		while IFS='|' read -r ports dir project name; do
			for p in $ports; do printf '%s\t%s\t%s\t%s\n' "$p" "$dir" "$project" "${name#/}"; done
		done
}

# Qui tient ce port, hors ce projet ? (vide si personne)
port_holder() { # port_holder PORT DOCKER_PORTS
	local p=$1 port dir project name path
	while IFS=$'\t' read -r port dir project name; do
		[ "$port" = "$p" ] && [ "$dir" != "$ROOT" ] && { echo "projet ${project:-hors Compose} (conteneur $name${dir:+, $dir})"; return; }
	done <<< "$2"
	if [ -f "$REGISTRY" ]; then
		while read -r port path; do
			[ "$port" = "$p" ] && [ "$path" != "$ROOT" ] && [ -d "$path" ] && { echo "projet $(basename "$path") ($path, registre)"; return; }
		done < "$REGISTRY"
	fi
	return 0
}

pick_port() { # pick_port DÉBUT DOCKER_PORTS DÉJÀ_PRIS...
	local p=$1 dp=$2 taken
	shift 2
	for ((; p < 65535; p++)); do
		for taken in $LEGACY_PORTS "$@"; do [ "$taken" = "$p" ] && continue 2; done
		listening "$p" && continue
		[ -n "$(port_holder "$p" "$dp")" ] && continue
		echo "$p"; return
	done
	die "aucun port libre trouvé à partir de $1"
}

# Registre : les lignes de ce projet deviennent exactement les ports donnés ; orphelines purgées.
registry_set() {
	local port path tmp
	mkdir -p "$REGISTRY_DIR"; touch "$REGISTRY"
	tmp=$(mktemp "$REGISTRY.XXXXXX")
	while read -r port path; do
		[ -n "$port" ] && [ "$path" != "$ROOT" ] && [ -d "$path" ] && printf '%s %s\n' "$port" "$path"
	done < "$REGISTRY" > "$tmp"
	for port in "$@"; do [ -n "$port" ] && printf '%s %s\n' "$port" "$ROOT"; done >> "$tmp"
	mv "$tmp" "$REGISTRY"
}

lock_registry() { mkdir -p "$REGISTRY_DIR"; exec 9> "$REGISTRY.lock"; flock 9; }

# doctor -------------------------------------------------------------------------
doctor() {
	[ -f "$ENV_FILE" ] || die "Fichier .env introuvable : lance make setup."
	local key p holder dp seen=" " ok=0
	dp=$(docker_ports)
	echo -e "\n🔎 Vérification des ports hôte..."
	for key in HTTP_PORT PHPMYADMIN_PORT VITE_PORT NODE_PORT; do
		p=$(env_get "$key" "$ENV_FILE")
		if [ -z "$p" ]; then
			case $key in HTTP_PORT|PHPMYADMIN_PORT) echo "❌ $key vide dans .env : lance make setup."; ok=1 ;; esac
			continue
		fi
		case $seen in *" $p "*) echo "❌ Port $p utilisé deux fois dans .env ($key)."; ok=1; continue ;; esac
		seen+="$p "
		holder=$(port_holder "$p" "$dp")
		if [ -n "$holder" ]; then
			echo "❌ Port $p ($key) déjà pris par le $holder."; ok=1
		elif grep -qP "^$p\t\Q$ROOT\E\t" <<< "$dp"; then
			echo "✅ Port $p ($key) tenu par ce projet"
		elif listening "$p"; then
			echo "❌ Port $p ($key) déjà pris par un programme hors Docker (ss -ltnp 'sport = :$p')."; ok=1
		else
			echo "✅ Port $p libre ($key)"
		fi
	done
	[ $ok -eq 0 ] || { echo "Libère ce port ou arrête le projet qui le tient, puis relance."; exit 1; }
}

# Questionnaire -------------------------------------------------------------------
WT_TITLE="wp-autoinstall : $(basename "$ROOT")"
# shellcheck source=scripts/ui.sh
. "$ROOT/scripts/ui.sh"
# Annulation : si des ports ont été réservés pendant ce questionnaire, le registre revient à l'état du .env
RESERVED=0 OLD_PORTS=""
cancel() {
	# shellcheck disable=SC2086
	[ $RESERVED -eq 1 ] && { lock_registry; registry_set $OLD_PORTS; }
	echo "🛑 Installation annulée : .env inchangé, rien n'a été lancé." >&2; exit 1
}

# Liste de plugins.md : "section<TAB>coché(ON/OFF)<TAB>slug<TAB>libellé"
plugins_list() {
	local section="" kind line
	[ -f plugins.md ] || return 0
	while IFS= read -r line; do
		case $line in
			"## "*) section=${line#\#\# } ;;
			"- ["[\ xX]"] \`"*)
				local box=${line:3:1} rest=${line#*\`} slug label
				slug=${rest%%\`*}; label=${rest#*\`}; label=${label# }
				[ "$box" = " " ] && box=OFF || box=ON
				case $section in Th*) kind=theme ;; *) kind=plugin ;; esac
				printf '%s\t%s\t%s\t%s\n' "$kind" "$box" "$slug" "${label:-$slug}" ;;
		esac
	done < plugins.md
}

setup() {
	local interactive=0 src key
	if [ -t 0 ] && [ -t 1 ] && command -v whiptail > /dev/null; then interactive=1; fi
	[ -f "$EXAMPLE" ] || die "$EXAMPLE introuvable."
	src=$EXAMPLE; [ -f "$ENV_FILE" ] && src=$ENV_FILE

	# Valeur de départ : variable d'environnement, sinon .env actuel, sinon .env.example
	start() { local v=${!1-}; [ -n "$v" ] && { printf '%s' "$v"; return; }; env_get "$1" "$src"; }
	local title user email pass install_node staging prod theme plugins
	title=$(start WORDPRESS_WEBSITE_TITLE); user=$(start WORDPRESS_ADMIN_USER)
	email=$(start WORDPRESS_ADMIN_EMAIL); pass=$(start WORDPRESS_ADMIN_PASSWORD)
	install_node=$(start INSTALL_NODE); staging=$(start STAGING_URL); prod=$(start PROD_URL)
	local old_http old_pma old_vite old_node
	old_http=$(env_get HTTP_PORT "$ENV_FILE"); old_pma=$(env_get PHPMYADMIN_PORT "$ENV_FILE")
	old_vite=$(env_get VITE_PORT "$ENV_FILE"); old_node=$(env_get NODE_PORT "$ENV_FILE")
	local want_vite=0 want_node=0
	[ -n "$old_vite" ] && want_vite=1; [ -n "$old_node" ] && want_node=1

	# Cases : plugins.md, ou le choix déjà enregistré si ce .env a déjà été configuré
	local list configured=0 sec box slug label
	list=$(plugins_list)
	grep -q '^WP_PLUGINS=' "$ENV_FILE" 2>/dev/null && configured=1
	theme=""; plugins=""
	while IFS=$'\t' read -r sec box slug label; do
		[ -n "$slug" ] || continue
		if [ $interactive -eq 1 ] && [ $configured -eq 1 ]; then
			box=OFF
			case " $(env_get WP_THEME "$ENV_FILE") $(env_get WP_PLUGINS "$ENV_FILE") " in *" $slug "*) box=ON ;; esac
		fi
		[ "$box" = ON ] || continue
		if [ "$sec" = theme ]; then theme+=" $slug"; else plugins+=" $slug"; fi
	done <<< "$list"
	[ -n "${WP_THEME-}" ] && theme=$WP_THEME
	[ -n "${WP_PLUGINS-}" ] && plugins=$WP_PLUGINS

	# Questions pas à pas : Valider = suivante, Retour = précédente, Échap = tout annuler
	local step=0 dir=1 last=7 rc out choice picked
	questions() {
		while [ $step -le $last ]; do
			rc=0
			case $step in
				0) out=$(ask --inputbox "Titre du site" 8 70 "$title") || rc=$?
					[ $rc -eq 0 ] && title=$out ;;
				1) out=$(ask --inputbox "Identifiant de connexion à wp-admin (évite admin et wordpress)" 8 70 "$user") || rc=$?
					if [ $rc -eq 0 ]; then [ -n "$out" ] || continue; user=$out; fi ;;
				2) out=$(ask --inputbox "E-mail admin" 8 70 "$email") || rc=$?
					if [ $rc -eq 0 ]; then
						email=$out
						[[ $email == ?*@?*.?* ]] || { ask --msgbox "E-mail invalide : « $email »." 8 70 || true; continue; }
					fi ;;
				3) local items=()
					[ -n "$pass" ] && items+=(garder "Garder le mot de passe actuel")
					items+=(generer "Générer un mot de passe" saisir "Saisir le mien (tous caractères acceptés)")
					choice=$(ask --menu "Mot de passe admin (flèches pour choisir, Entrée pour valider)" 12 74 3 "${items[@]}") || rc=$?
					if [ $rc -eq 0 ]; then
						case $choice in
							generer) pass=$(gen_secret 20) ;;
							saisir)
								out=$(ask --passwordbox "Mot de passe admin" 8 70) || rc=$?
								[ $rc -eq 1 ] && continue
								[ $rc -eq 0 ] && { [ -n "$out" ] || continue; pass=$out; } ;;
						esac
					fi ;;
				4) local args=()
					while IFS=$'\t' read -r sec box slug label; do
						[ -n "$slug" ] || continue
						box=OFF
						case " $theme $plugins " in *" $slug "*) box=ON ;; esac
						[ "$sec" = theme ] && label="thème : $label"
						args+=("$slug" "$label" "$box")
					done <<< "$list"
					if [ ${#args[@]} -eq 0 ]; then [ $dir -eq 1 ] || rc=1
					else
						picked=$(ask --separate-output --checklist "Thème et plugins (espace pour cocher, Entrée pour valider)" 20 70 12 "${args[@]}") || rc=$?
						if [ $rc -eq 0 ]; then
							theme=""; plugins=""
							while IFS=$'\t' read -r sec box slug label; do
								grep -qxF -- "$slug" <<< "$picked" || continue
								if [ "$sec" = theme ]; then theme+=" $slug"; else plugins+=" $slug"; fi
							done <<< "$list"
							theme=${theme# }; plugins=${plugins# }
						fi
					fi ;;
				5) picked=$(ask --separate-output --checklist "npm et ports de dev (espace pour cocher, Entrée pour valider)\nCocher vite ou node ajoute npm." 12 78 3 \
						npm "Installer npm (build plus long)" "$([ "$install_node" = true ] && echo ON || echo OFF)" \
						vite "Publier le port Vite (5173 du conteneur)" "$([ $want_vite -eq 1 ] && echo ON || echo OFF)" \
						node "Publier le port Node (3000 du conteneur)" "$([ $want_node -eq 1 ] && echo ON || echo OFF)") || rc=$?
					if [ $rc -eq 0 ]; then
						install_node=false; want_vite=0; want_node=0
						grep -qx vite <<< "$picked" && want_vite=1
						grep -qx node <<< "$picked" && want_node=1
						{ grep -qx npm <<< "$picked" || [ $want_vite -eq 1 ] || [ $want_node -eq 1 ]; } && install_node=true
					fi ;;
				6) out=$(ask --inputbox "URL du staging (vide accepté)" 8 70 "$staging") || rc=$?
					if [ $rc -eq 0 ]; then
						staging=${out%/}
						url_ok "$staging" || { ask --msgbox "URL invalide : « $staging ». Exemple : https://staging.monsite.fr" 8 70 || true; continue; }
					fi ;;
				7) out=$(ask --inputbox "URL de la prod (vide accepté)" 8 70 "$prod") || rc=$?
					if [ $rc -eq 0 ]; then
						prod=${out%/}
						url_ok "$prod" || { ask --msgbox "URL invalide : « $prod ». Exemple : https://staging.monsite.fr" 8 70 || true; continue; }
					fi ;;
			esac
			case $rc in 0) dir=1 ;; 1) dir=-1 ;; *) cancel ;; esac
			step=$((step + dir)); [ $step -lt 0 ] && step=0
		done
		return 0
	}

	while :; do
	if [ $interactive -eq 1 ]; then
		questions
	else
		echo "⚠️ Pas de terminal interactif (ou whiptail absent) : aucune question, valeurs de l'environnement, du .env ou par défaut, cases de plugins.md."
		[ -n "$pass" ] || pass=$(gen_secret 20)
		[ -n "$user" ] || user=wordpress
		staging=${staging%/}; prod=${prod%/}
		url_ok "$staging" || die "STAGING_URL invalide : « $staging » (attendu : https://staging.monsite.fr)."
		url_ok "$prod" || die "PROD_URL invalide : « $prod » (attendu : https://www.monsite.fr)."
	fi
	[ "$install_node" = true ] || { install_node=false; want_vite=0; want_node=0; }
	theme=${theme# }; plugins=${plugins# }
	local db_pass
	db_pass=$(env_get DATABASE_PASSWORD "$src"); [ -n "$db_pass" ] || db_pass=$(gen_secret 24)

	# Ports : gardés s'ils existent, sinon choisis ; réservés au registre sous verrou
	local http pma vite="" node="" dp
	lock_registry
	dp=$(docker_ports)
	http=${old_http:-$(pick_port 8080 "$dp")}
	pma=${old_pma:-$(pick_port $((http + 1)) "$dp" "$http")}
	[ $want_vite -eq 1 ] && vite=${old_vite:-$(pick_port 5173 "$dp" "$http" "$pma")}
	[ $want_node -eq 1 ] && node=${old_node:-$(pick_port 3000 "$dp" "$http" "$pma" "$vite")}
	registry_set "$http" "$pma" "$vite" "$node"
	flock -u 9
	RESERVED=1 OLD_PORTS="$old_http $old_pma $old_vite $old_node"

	local compose_file=""
	[ -n "$vite" ] && compose_file+=":compose.vite.yml"
	[ -n "$node" ] && compose_file+=":compose.node.yml"
	[ -n "$compose_file" ] && compose_file="compose.yml$compose_file"

	if [ $interactive -eq 1 ]; then
		local npm_txt="non"
		[ "$install_node" = true ] && npm_txt="oui${vite:+, Vite sur $vite}${node:+, Node sur $node}"
		rc=0
		ask --yes-button Oui --no-button Retour --yesno "Récapitulatif

URL locale    : http://localhost:$http
phpMyAdmin    : http://localhost:$pma
Titre         : $title
Identifiant   : $user
E-mail        : $email
Mot de passe  : $pass
Thème         : ${theme:-aucun}
Plugins       : ${plugins:-aucun}
npm           : $npm_txt
Staging       : ${staging:-aucune}
Prod          : ${prod:-aucune}

Écrire le .env et continuer ?" 22 78 || rc=$?
		case $rc in
			0) break ;;
			1) step=$last; dir=-1 ;;
			*) cancel ;;
		esac
	else
		break
	fi
	done

	# Écriture : forme du .env actuel (ou du modèle), valeurs remplacées sur place
	declare -A val=(
		[WORDPRESS_WEBSITE_TITLE]=$title [WORDPRESS_ADMIN_USER]=$user [WORDPRESS_ADMIN_EMAIL]=$email
		[WORDPRESS_ADMIN_PASSWORD]=$pass [WP_THEME]=$theme [WP_PLUGINS]=$plugins
		[INSTALL_NODE]=$install_node [HTTP_PORT]=$http [PHPMYADMIN_PORT]=$pma
		[DATABASE_PASSWORD]=$db_pass [STAGING_URL]=$staging [PROD_URL]=$prod
		[VITE_PORT]=$vite [NODE_PORT]=$node [COMPOSE_FILE]=$compose_file
	)
	TMP_ENV=$(mktemp "$ROOT/.env.tmp.XXXXXX")
	local line done_keys=" "
	while IFS= read -r line || [ -n "$line" ]; do
		key=${line%%=*}
		[[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && done_keys+="$key "
		if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && [ -n "${val[$key]+x}" ]; then
			[ -z "${val[$key]}" ] && case $key in VITE_PORT|NODE_PORT|COMPOSE_FILE) continue ;; esac
			printf '%s=%s\n' "$key" "$(env_fmt "${val[$key]}")"
		else
			printf '%s\n' "$line"
		fi
	done < "$src" > "$TMP_ENV"
	# Clés du modèle absentes d'un ancien .env, puis ports Vite/Node cochés : ajoutées à la fin
	while IFS= read -r line; do
		[[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
		key=${BASH_REMATCH[1]}
		case $done_keys in *" $key "*) continue ;; esac
		done_keys+="$key "
		if [ -n "${val[$key]+x}" ]; then printf '%s=%s\n' "$key" "$(env_fmt "${val[$key]}")"; else printf '%s\n' "$line"; fi
	done < "$EXAMPLE" >> "$TMP_ENV"
	for key in VITE_PORT NODE_PORT COMPOSE_FILE; do
		case $done_keys in *" $key "*) continue ;; esac
		[ -n "${val[$key]}" ] && printf '%s=%s\n' "$key" "${val[$key]}" >> "$TMP_ENV"
	done
	mv "$TMP_ENV" "$ENV_FILE"; TMP_ENV=""

	echo "✅ .env écrit."
	echo "   URL          : http://localhost:$http/wp-admin"
	echo "   Identifiant  : $user"
	echo "   Mot de passe : $pass"
}

case ${1:-setup} in
	setup) setup ;;
	doctor) doctor ;;
	*) die "usage : $0 [setup|doctor]" ;;
esac
