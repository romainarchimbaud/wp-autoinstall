#!/usr/bin/env bash
# make ssh-alias : crée les alias SSH du projet (<projet>-prod, <projet>-staging) quand on reçoit
# les accès d'un hébergeur, les écrit dans .env (PROD_SSH, STAGING_SSH) et les teste (spec 002).
# Écrit ~/.ssh/config.d/<projet>.conf (réécrit à chaque lancement) ; ajoute une fois l'Include en tête
# de ~/.ssh/config, après une copie datée ; ne touche à aucun autre bloc.
# Questions : écrans whiptail dans un terminal (comme make setup), sinon une réponse par ligne.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=.env
PROJECT=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')
SSH_DIR=$HOME/.ssh
CONF_DIR=$SSH_DIR/config.d
CONF=$CONF_DIR/$PROJECT.conf
# Chemin absolu : ssh résout un Include relatif dans le ~/.ssh du compte, pas dans $HOME
INCLUDE="Include $CONF_DIR/*.conf"
# ssh lit la config et les empreintes du compte, pas de $HOME : on les lui désigne
SSH_OPTS=(-F "$SSH_DIR/config" -o UserKnownHostsFile="$SSH_DIR/known_hosts" -o StrictHostKeyChecking=accept-new)

die() { echo "❌ $*" >&2; exit 1; }
[ -f "$ENV_FILE" ] || die "Fichier .env introuvable : lance make setup."

UI=0
if [ -t 0 ] && [ -t 1 ] && command -v whiptail > /dev/null; then
	UI=1
	WT_TITLE="Alias SSH : $PROJECT"
	# shellcheck source=scripts/ui.sh
	. scripts/ui.sh
fi
cancel() { echo "🛑 Annulé : rien n'a été écrit." >&2; exit 1; }

env_val() { grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true; }
env_set() { # remplace la clé du .env, ou l'ajoute
	if grep -qE "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

# Valeur d'un alias déjà écrit (relance : réponses pré-remplies)
conf_val() { # conf_val <Host> <clé>
	[ -f "$CONF" ] || return 0
	awk -v h="$1" -v k="$2" '$1 == "Host" { in_h = ($2 == h) } in_h && tolower($1) == tolower(k) { print $2; exit }' "$CONF"
}

line() { # line <question> <défaut>
	local a
	printf '%s%s : ' "$1" "${2:+ [$2]}" >&2
	IFS= read -r a || a=""
	printf '%s' "${a:-$2}"
}

# Question libre : écran ou ligne. Code 1 = Retour.
input() { # input <question> <défaut>
	local out rc=0
	if [ $UI -eq 1 ]; then
		out=$(ask --inputbox "$1" 9 74 "$2") || rc=$?
		case $rc in 0) printf '%s' "$out" ;; 1) return 1 ;; *) cancel ;; esac
	else
		line "$1" "$2"
	fi
}

# Oui/non : écran ou ligne (o/n). Sortie « o » ou « n ». Code 1 = Retour.
yesno() { # yesno <question> <défaut o|n>
	local rc=0 a
	if [ $UI -eq 1 ]; then
		local def=()
		[ "$2" = n ] && def=(--defaultno)
		ask --yes-button Oui --no-button Non "${def[@]}" --yesno "$1" 10 74 || rc=$?
		case $rc in 0) printf o ;; 1) printf n ;; *) cancel ;; esac
	else
		a=$(line "$1 (o/n)" "$2")
		case $a in [oOyY]*) printf o ;; *) printf n ;; esac
	fi
}

# Réponses : pré-remplies par l'alias existant, sinon valeurs par défaut
P=$PROJECT-prod S=$PROJECT-staging
p_host=$(conf_val "$P" HostName); p_user=$(conf_val "$P" User); p_port=$(conf_val "$P" Port)
p_key=$(conf_val "$P" IdentityFile)
s_host=$(conf_val "$S" HostName); s_user=$(conf_val "$S" User); s_port=$(conf_val "$S" Port)
s_key=$(conf_val "$S" IdentityFile)
p_port=${p_port:-22}; p_key=${p_key:-$SSH_DIR/id_ed25519}
# Dossiers du site sur le serveur : pré-remplis par le .env, vérifiés après la connexion
p_path=$(env_val PROD_PATH); s_path=$(env_val STAGING_PATH)
p_path=${p_path:-public_html}; s_path=${s_path:-$p_path}
same=o
[ -n "$s_host" ] && [ "$s_host:$s_user:$s_port" != "$p_host:$p_user:$p_port" ] && same=n
copy_id=n

# Pas à pas : Valider = suivante, Retour = précédente, Échap = tout annuler (comme make setup)
step=0 dir=1 out=""
while [ $step -le 12 ]; do
	rc=0
	case $step in
		0) out=$(input "Prod : serveur SSH (nom d'hôte ou IP)" "$p_host") || rc=$?
			[ $rc -eq 0 ] && { [ -n "$out" ] || { [ $UI -eq 1 ] && continue; die "Serveur de la prod requis."; }; p_host=$out; } ;;
		1) out=$(input "Prod : utilisateur SSH" "$p_user") || rc=$?
			[ $rc -eq 0 ] && { [ -n "$out" ] || { [ $UI -eq 1 ] && continue; die "Utilisateur de la prod requis."; }; p_user=$out; } ;;
		2) out=$(input "Prod : port SSH" "$p_port") || rc=$?
			[ $rc -eq 0 ] && { [[ $out =~ ^[0-9]+$ ]] || { [ $UI -eq 1 ] && continue; die "Port invalide : $out"; }; p_port=$out; } ;;
		3) out=$(input "Prod : clé privée (générée si absente)" "$p_key") || rc=$?
			[ $rc -eq 0 ] && { p_key=${out:-$SSH_DIR/id_ed25519}; p_key=${p_key/#\~/$HOME}; } ;;
		4) out=$(yesno "Le staging est-il sur le même serveur que la prod (même hôte, utilisateur, port, clé) ?" "$same") || rc=$?
			[ $rc -eq 0 ] && same=$out ;;
		5) [ "$same" = o ] && { step=$((step + dir)); continue; }
			out=$(input "Staging : serveur SSH (nom d'hôte ou IP)" "${s_host:-$p_host}") || rc=$?
			[ $rc -eq 0 ] && { [ -n "$out" ] || { [ $UI -eq 1 ] && continue; die "Serveur du staging requis."; }; s_host=$out; } ;;
		6) [ "$same" = o ] && { step=$((step + dir)); continue; }
			out=$(input "Staging : utilisateur SSH" "${s_user:-$p_user}") || rc=$?
			[ $rc -eq 0 ] && { [ -n "$out" ] || { [ $UI -eq 1 ] && continue; die "Utilisateur du staging requis."; }; s_user=$out; } ;;
		7) [ "$same" = o ] && { step=$((step + dir)); continue; }
			out=$(input "Staging : port SSH" "${s_port:-$p_port}") || rc=$?
			[ $rc -eq 0 ] && { [[ $out =~ ^[0-9]+$ ]] || { [ $UI -eq 1 ] && continue; die "Port invalide : $out"; }; s_port=$out; } ;;
		8) [ "$same" = o ] && { step=$((step + dir)); continue; }
			out=$(input "Staging : clé privée (générée si absente)" "${s_key:-$p_key}") || rc=$?
			[ $rc -eq 0 ] && { s_key=${out:-$p_key}; s_key=${s_key/#\~/$HOME}; } ;;
		9) out=$(yesno "Copier la clé publique sur le(s) serveur(s) (ssh-copy-id, mot de passe SSH demandé une fois) ?" "$copy_id") || rc=$?
			[ $rc -eq 0 ] && copy_id=$out ;;
		10) out=$(input "Prod : dossier du site sur le serveur (relatif au dossier de connexion)" "$p_path") || rc=$?
			[ $rc -eq 0 ] && { [ -n "$out" ] || { [ $UI -eq 1 ] && continue; die "Dossier de la prod requis."; }; p_path=${out%/}; } ;;
		11) out=$(input "Staging : dossier du site sur le serveur (relatif au dossier de connexion)" "$s_path") || rc=$?
			[ $rc -eq 0 ] && { [ -n "$out" ] || { [ $UI -eq 1 ] && continue; die "Dossier du staging requis."; }; s_path=${out%/}; } ;;
		12) if [ "$same" = o ]; then s_host=$p_host s_user=$p_user s_port=$p_port s_key=$p_key; fi
			[ $UI -eq 1 ] || { step=13; continue; }
			ask --yes-button Oui --no-button Retour --yesno "Récapitulatif

$P      : $p_user@$p_host:$p_port
             clé $p_key$([ -f "$p_key" ] || printf ' (à générer)')
             dossier $p_path
$S   : $s_user@$s_host:$s_port
             clé $s_key$([ -f "$s_key" ] || printf ' (à générer)')
             dossier $s_path
ssh-copy-id  : $([ "$copy_id" = o ] && echo oui || echo non)

Écrit $CONF,
l'Include en tête de $SSH_DIR/config (une fois, copie datée avant),
PROD_SSH, STAGING_SSH, PROD_PATH et STAGING_PATH dans .env. Continuer ?" 22 78 || rc=$?
			[ $rc -eq 0 ] && { step=13; continue; } ;;
	esac
	case $rc in 0) dir=1 ;; 1) dir=-1 ;; *) cancel ;; esac
	step=$((step + dir)); [ $step -lt 0 ] && step=0
done

# Clés absentes : générées sans phrase de passe (les synchros se connectent sans question, BatchMode)
for key in "$p_key" "$s_key"; do
	[ -f "$key" ] && continue
	echo "🔑 Génération de la clé $key (sans phrase de passe)..."
	mkdir -p "$(dirname "$key")" && chmod 700 "$SSH_DIR"
	ssh-keygen -q -t ed25519 -f "$key" -N "" -C "$PROJECT"
done

# Alias du projet : fichier réécrit en entier, rien d'autre n'est touché
mkdir -p "$CONF_DIR" && chmod 700 "$SSH_DIR" "$CONF_DIR"
cat > "$CONF" << EOF
# Généré par make ssh-alias ($PROJECT) : relancer la commande pour le modifier
Host $P
  HostName $p_host
  User $p_user
  Port $p_port
  IdentityFile $p_key
  IdentitiesOnly yes

Host $S
  HostName $s_host
  User $s_user
  Port $s_port
  IdentityFile $s_key
  IdentitiesOnly yes
EOF
chmod 600 "$CONF"
echo "✅ Alias écrits : $CONF"

if ! grep -qxF "$INCLUDE" "$SSH_DIR/config" 2> /dev/null; then
	if [ -f "$SSH_DIR/config" ]; then
		backup=$SSH_DIR/config.bak-$(date +%Y%m%d-%H%M%S)
		cp -p "$SSH_DIR/config" "$backup"
		{ printf '%s\n\n' "$INCLUDE"; cat "$backup"; } > "$SSH_DIR/config"
		echo "✅ Include ajouté en tête de $SSH_DIR/config (copie : $backup)"
	else
		printf '%s\n' "$INCLUDE" > "$SSH_DIR/config"; chmod 600 "$SSH_DIR/config"
		echo "✅ $SSH_DIR/config créé avec l'Include"
	fi
fi

env_set PROD_SSH "$P"; env_set STAGING_SSH "$S"
env_set PROD_PATH "$p_path"; env_set STAGING_PATH "$s_path"
echo "✅ .env : PROD_SSH=$P, STAGING_SSH=$S, PROD_PATH=$p_path, STAGING_PATH=$s_path"

if [ "$copy_id" = o ]; then
	ssh-copy-id -i "$p_key.pub" "${SSH_OPTS[@]:2}" -p "$p_port" "$p_user@$p_host"
	[ "$same" = o ] || ssh-copy-id -i "$s_key.pub" "${SSH_OPTS[@]:2}" -p "$s_port" "$s_user@$s_host"
fi

# Test de chaque alias : connexion, dossier du site (PROD_PATH / STAGING_PATH), WP-CLI
ok=0
for env in prod staging; do
	alias=$PROJECT-$env
	path=$(env_val "$(tr '[:lower:]' '[:upper:]' <<< "$env")_PATH")
	rc=0
	out=$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "$alias" \
		"cd ${path:-.} 2> /dev/null || exit 3
		for c in ${WP_CMD:-wp wp-cli}; do command -v \$c > /dev/null && { w=\$c; break; }; done
		[ -n \"\${w-}\" ] || exit 4
		[ -f wp-config.php ] || exit 5; \$w core is-installed 2> /dev/null || exit 6; \$w --version" 2>&1 < /dev/null) || rc=$?
	case $rc in
		0) echo "✅ $alias : connexion OK, WordPress trouvé dans ${path:-~} ($out)" ;;
		3) echo "❌ $alias : connexion OK, mais dossier « $path » absent : corriger ${env^^}_PATH dans .env."; ok=1 ;;
		4) echo "❌ $alias : connexion OK, mais WP-CLI absent (ni « wp » ni « wp-cli » dans le PATH)."
			echo "   S'il est installé sous un autre nom, l'indiquer par WP_CMD dans .env. Sinon :"
			echo "   - demander à l'hébergeur d'installer WP-CLI (commande wp), ou"
			echo "   - l'installer soi-même : ssh $alias puis"
			echo "     mkdir -p ~/bin && curl -o ~/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x ~/bin/wp"
			echo "     et vérifier que ~/bin est dans le PATH d'une connexion ssh : ssh $alias 'wp --version'"
			ok=1 ;;
		5) echo "❌ $alias : dossier « $path » trouvé, mais pas de wp-config.php : ce n'est pas la racine d'un WordPress."
			echo "   Corriger ${env^^}_PATH (relancer make ssh-alias) : ssh $alias 'ls' pour voir les dossiers disponibles."
			ok=1 ;;
		6) echo "❌ $alias : WordPress présent dans « $path », mais pas installé (base vide ou inaccessible)."
			echo "   Vérifier le site dans un navigateur, ou ssh $alias 'cd $path && wp core is-installed'."
			ok=1 ;;
		*) echo "❌ $alias : connexion refusée ou impossible ($out)."
			echo "   Clé publique à déposer sur le serveur (ssh-copy-id, relancer make ssh-alias et répondre oui), ou hôte/port à corriger."
			ok=1 ;;
	esac
done
exit $ok
