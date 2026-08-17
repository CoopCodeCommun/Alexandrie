#!/bin/bash
# =============================================================================
# bin/restore.sh — Restaure Alexandrie depuis une archive borg
# / bin/restore.sh — Restores Alexandrie from a borg archive
#
# S'EXECUTE DEPUIS L'HOTE.   Lance par :  make restore [ARCHIVE=<nom>]
#
# CETTE COMMANDE ECRASE LA BASE ET LES FICHIERS EN SERVICE. Elle demande
# donc une confirmation tapee au clavier, et refuse de tourner sans.
# / This overwrites the live database and files; it asks for typed
# confirmation.
#
# CE QU'ELLE FAIT, DANS L'ORDRE
#
#   1. choisit l'archive (la derniere par defaut) et la fait confirmer
#   2. ARRETE frontend, backend et rustfs :
#      - le backend tient des connexions ouvertes sur la base, et
#        `DROP DATABASE` resterait bloque a attendre ses verrous ;
#      - rustfs tient son dossier de donnees ouvert : remplacer les
#        fichiers sous ses pieds lui laisserait un index qui ne
#        correspond plus a rien.
#      MySQL, lui, RESTE ALLUME : c'est par lui que passe la restauration.
#   3. supprime et recree la base, puis y charge le dump
#   4. vide le volume S3 et y deplie les fichiers de l'archive
#   5. depose le .env de l'archive A COTE, sans jamais l'installer
#   6. redemarre les trois services
#
# LES MIGRATIONS SE REJOUENT TOUTES SEULES. Le dump ramene aussi la table
# `schema_migrations` a l'etat de l'archive : un code plus recent que
# l'archive — le cas normal d'un sinistre, images `latest` plus une
# archive d'il y a trois jours — se retrouverait sur un schema en retard.
# Mais le backend embarque ses migrations et les rejoue AU DEMARRAGE,
# avant de servir quoi que ce soit : le redemarrage de l'etape 6 remet le
# schema a niveau.
# / Migrations replay by themselves: the backend embeds them and runs them
# at startup, before serving anything.
#
# LE .env COURANT N'EST JAMAIS ECRASE, et c'est delibere : il porte
# BORG_PASSPHRASE, la passphrase du depot EN SERVICE. Celui d'une vieille
# archive peut en porter une autre — l'installer rendrait le depot
# inaccessible, et on ne s'en apercevrait qu'a la restauration suivante.
# / The live .env is never overwritten: it holds the passphrase of the
# repository in service.
#
# RESTAURATION COMPLETE, SUR UNE MACHINE NEUVE
#
#   git clone <depot> && cd Alexandrie
#   cp <le .env sorti du coffre> .env
#   make install                # la stack, vide
#   make restore                # les donnees
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"

FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"
FICHIER_COMPOSE="$REPERTOIRE_DU_PROJET/docker-compose.yml"
VOLUME_S3="alexandrie_rustfs_data"

# Les services a eteindre le temps de la restauration. MySQL n'y est pas :
# c'est par lui qu'on restaure. / MySQL is absent: the restore goes
# through it.
SERVICES_A_ETEINDRE="frontend backend rustfs"

[ -f "$FICHIER_ENV" ] || {
    echo "[restauration] .env introuvable : $FICHIER_ENV" >&2
    exit 1
}
# `UID` et `GID` sont en LECTURE SEULE sous bash : les ecarter evite qu'un
# `.env` qui en porterait une tue le script sur place, sous `set -e`.
set -a
# shellcheck disable=SC1090
. <(grep -vE '^[[:space:]]*(UID|GID)=' "$FICHIER_ENV")
set +a

: "${BORG_PREFIX:?BORG_PREFIX absent du .env — aucune sauvegarde configuree}"
: "${BORG_REPO:?BORG_REPO absent du .env — aucune sauvegarde configuree}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"
command -v borg   >/dev/null || { echo "[restauration] borg introuvable" >&2; exit 1; }
command -v docker >/dev/null || { echo "[restauration] docker introuvable" >&2; exit 1; }

CLE_SSH="$REPERTOIRE_DU_SCRIPT/.ssh/${BORG_PREFIX}_ed25519"
if [ -f "$CLE_SSH" ]; then
    # Chemin entre quotes simples : borg decoupe BORG_RSH comme un shell.
    export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i '$CLE_SSH'"
elif [ "${BORG_REPO#ssh://}" != "$BORG_REPO" ]; then
    # LE CAS DE LA MACHINE DE SECOURS. Sans ce message, borg echoue sur un
    # refus SSH qui parle de permissions et jamais de nom de fichier — or
    # c'est presque toujours le nom qui cloche : les scripts cherchent
    # EXACTEMENT `${BORG_PREFIX}_ed25519`, et une cle sortie du coffre sous
    # un autre nom n'est tout simplement pas vue.
    # / The recovery-machine case: SSH's refusal talks about permissions
    # and never about the file name, which is what is actually wrong.
    echo "[restauration] Aucune cle SSH a $CLE_SSH." >&2
    echo "               Le depot est distant : sans elle, le serveur" >&2
    echo "               refusera la connexion." >&2
    echo "               Sortir la cle privee du coffre et la reposer SOUS" >&2
    echo "               CE NOM EXACT, dans bin/.ssh/ :" >&2
    echo "                 ${BORG_PREFIX}_ed25519      (chmod 600)" >&2
    echo "               Un autre nom ne serait pas vu, et le refus SSH ne" >&2
    echo "               le dirait pas." >&2
    echo >&2
fi

# Une restauration se fait souvent sur une AUTRE machine, ou le depot n'est
# plus au meme chemin : borg demande alors une confirmation. Meme reglage
# que dans bin/backup.sh, sans quoi la sauvegarde passerait la ou la
# restauration s'arreterait. / Same setting as backup.sh.
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes


#### CHOIX DE L'ARCHIVE ####
if [ "${1:-}" = "--liste" ]; then
    borg list --glob-archives "$BORG_PREFIX-*" \
        --format '{archive}{TAB}{time:%Y-%m-%d %H:%M}{NL}' "$BORG_REPO"
    exit 0
fi

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
    ARCHIVE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
        --format '{archive}{NL}' "$BORG_REPO")"
    [ -n "$ARCHIVE" ] || {
        echo "[restauration] aucune archive '$BORG_PREFIX-*' dans le depot." >&2
        exit 1
    }
fi

# `make backup-check` appelle ce script apres avoir pose SA propre
# confirmation et pris une sauvegarde fraiche : redemander ici bloquerait
# une repetition generale qui, elle, a deja tout verifie.
# / backup-check has already asked and already taken a fresh backup.
if [ "${RESTAURATION_CONFIRMEE:-}" != "oui" ]; then
    echo
    echo "================================================================"
    echo " RESTAURATION — cette operation ECRASE la base ET les fichiers"
    echo " en service."
    echo
    echo " Archive  : $ARCHIVE"
    echo " Depot    : $BORG_REPO"
    echo " Base     : $MYSQL_DATABASE"
    echo " Fichiers : volume $VOLUME_S3"
    echo
    echo " Toute donnee saisie depuis cette archive sera perdue."
    echo " Le .env courant est PROTEGE : celui de l'archive sera depose a"
    echo " cote, jamais installe (il porte la passphrase du depot)."
    echo "================================================================"
    echo
    echo " Choisir une autre archive :  make restore ARCHIVE=<nom>"
    echo " Les lister :                 bash bin/restore.sh --liste"
    echo
    [ -t 0 ] || {
        echo "[restauration] entree non interactive : la confirmation est impossible." >&2
        exit 1
    }
    read -r -p "Taper RESTAURER pour continuer : " CONFIRMATION
    [ "$CONFIRMATION" = "RESTAURER" ] || {
        echo "[restauration] annule."
        exit 1
    }
fi


#### LE MEME VERROU QUE LA SAUVEGARDE ####
# Le cron ne sait pas qu'une restauration est en cours. S'il tombe au
# milieu, il archive une base a moitie restauree — un dump parfaitement
# valide, que la verification declarera restaurable, et qui ne porte
# qu'une moitie des donnees. Le verrou existe deja cote sauvegarde ;
# l'etendre ici ne coute rien.
# / The cron does not know a restore is running: it would archive a
# half-restored database into a perfectly valid-looking dump.
exec 9>"$REPERTOIRE_DU_PROJET/.backup-$BORG_PREFIX.lock"
flock -n 9 || {
    echo "[restauration] une sauvegarde est en cours — reessayer apres." >&2
    exit 1
}


#### EXTRACTION ####
DOSSIER_DE_RESTAURATION="$REPERTOIRE_DU_PROJET/.restauration-$(date +%Y-%m-%d-%H-%M-%S)"
mkdir -p "$DOSSIER_DE_RESTAURATION"

echo
echo "[restauration] extraction de l'archive $ARCHIVE..."
(
    cd "$DOSSIER_DE_RESTAURATION"
    # borg restitue les chemins absolus prives de leur `/` initial :
    # l'archive se deplie donc dans une arborescence miniature ici.
    # / borg strips the leading slash.
    borg extract "$BORG_REPO::$ARCHIVE"
)

# Les trois contenus sont CHERCHES, pas reconstruits. Reconstruire revient
# a supposer que la machine qui restaure porte le projet au MEME chemin que
# celle qui a sauvegarde — l'hypothese qui tombe precisement le jour d'un
# vrai sinistre, quand on remonte ailleurs, souvent sous un autre chemin.
# On ne s'en apercevrait qu'a ce moment-la.
# / Searched, not rebuilt: rebuilding assumes the same path on both
# machines, which is exactly what fails on the day of a real disaster.
DUMP_EXTRAIT="$(find "$DOSSIER_DE_RESTAURATION" -type f -name 'alexandrie.sql' -print -quit)"
TAR_EXTRAIT="$(find "$DOSSIER_DE_RESTAURATION" -type f -name 'rustfs.tar' -print -quit)"
ENV_DE_L_ARCHIVE="$(find "$DOSSIER_DE_RESTAURATION" -type f -name '.env' -print -quit)"

[ -n "$DUMP_EXTRAIT" ] || {
    echo "[restauration] aucun dump dans cette archive — abandon." >&2
    exit 1
}


#### L'ARCHIVE EST-ELLE EXPLOITABLE ? A VERIFIER AVANT DE DETRUIRE ####
# CE CONTROLE MANQUAIT, ET C'ETAIT LE PLUS GRAVE DEFAUT DE CE SCRIPT.
#
# Les etapes suivantes font `DROP DATABASE` puis vident le volume S3.
# Elles etaient lancees sans jamais avoir regarde si l'archive tenait la
# route, alors que bin/verifier_archive.sh sait le faire depuis toujours.
# Le seul garde-fou etait en aval — « la table users a-t-elle des
# lignes ? » — et il ne suffit pas : `users` est la PREMIERE table sortie
# par mysqldump, donc un dump ampute de sa moitie passe au vert
# (« base restauree — 3 compte(s) ») pendant que `nodes` reste vide.
#
# Cote S3, c'etait pire : on vidait le volume, PUIS on decouvrait que le
# tar etait tronque. rustfs repartait sur un /data ampute de son
# format.json, sans rien pour revenir en arriere.
#
# `make backup-check` etait couvert — il verifie l'archive en amont —
# mais `make restore` est justement la commande du jour du sinistre.
# / This check was missing, and it was this script's worst flaw: the
# downstream guard passes on a dump truncated in half, because `users` is
# the first table mysqldump writes. And the S3 volume was emptied BEFORE
# discovering the tar was cut.
if [ "${FORCER:-}" = "oui" ]; then
    echo "[restauration] [!] FORCER=oui : controles d'exploitabilite sautes." >&2
else
    echo "[restauration] verification de l'archive avant de rien detruire..."

    # `mysqldump` n'ecrit sa derniere ligne qu'une fois TOUTES les tables
    # sorties : sa presence est la seule preuve que le dump est complet.
    # `mysql` avalerait un fichier coupe et sortirait en 0.
    if ! tail -c 200 "$DUMP_EXTRAIT" | grep -q -- '-- Dump completed'; then
        echo "[restauration] ABANDON : le dump de cette archive est TRONQUE." >&2
        echo "               mysqldump n'a pas ecrit son marqueur de fin." >&2
        echo "               RIEN n'a ete detruit, le site tourne toujours." >&2
        echo "               Choisir une autre archive :" >&2
        echo "                 bash bin/restore.sh --liste" >&2
        echo "               Passer outre (au risque d'une base amputee) :" >&2
        echo "                 FORCER=oui make restore ARCHIVE=$ARCHIVE" >&2
        exit 1
    fi
    echo "  [ok]   dump complet"

    if [ -n "$TAR_EXTRAIT" ] && ! tar -tf "$TAR_EXTRAIT" >/dev/null 2>&1; then
        echo "[restauration] ABANDON : le stockage S3 de cette archive est TRONQUE." >&2
        echo "               Vider le volume avant de s'en apercevoir laisserait" >&2
        echo "               rustfs sans ses fichiers ET sans son index." >&2
        echo "               RIEN n'a ete detruit." >&2
        exit 1
    fi
    [ -n "$TAR_EXTRAIT" ] && echo "  [ok]   stockage S3 deroulable"
fi


#### ARRET DES SERVICES QUI TIENNENT LES DONNEES ####
echo "[restauration] arret de : $SERVICES_A_ETEINDRE"
# shellcheck disable=SC2086
docker compose -f "$FICHIER_COMPOSE" stop $SERVICES_A_ETEINDRE
# Quoi qu'il arrive ensuite, les services repartent : une restauration
# ratee ne doit pas laisser le site eteint.
# / Whatever happens, the services come back up.
# shellcheck disable=SC2064
trap "echo '[restauration] redemarrage des services...'; docker compose -f '$FICHIER_COMPOSE' start $SERVICES_A_ETEINDRE" EXIT

# MySQL doit repondre : c'est par lui que tout passe. S'il est arrete, les
# commandes suivantes echoueraient l'une apres l'autre, et le diagnostic
# se lirait « la base est vide » sur une archive parfaitement saine.
# / MySQL must answer: otherwise the diagnosis would read "empty
# database" on a perfectly healthy archive.
docker compose -f "$FICHIER_COMPOSE" exec -T mysql true >/dev/null 2>&1 || {
    echo "[restauration] le conteneur mysql ne repond pas." >&2
    echo "               Demarrer la stack (make install), puis relancer." >&2
    exit 1
}


#### RESTAURATION DE LA BASE ####
echo "[restauration] remise a zero de la base $MYSQL_DATABASE..."
# On SUPPRIME avant de recreer. Sans cela, le dump s'empile sur les
# donnees en place : chaque `INSERT` bute sur une contrainte d'unicite et
# la base finit a moitie ancienne, a moitie restauree.
#
# En root : l'utilisateur applicatif recoit tous les droits SUR sa base,
# mais pas celui d'en creer une. / As root: the application user has every
# right on its database but cannot create one.
docker compose -f "$FICHIER_COMPOSE" exec -T mysql \
    sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot \
        -e "DROP DATABASE IF EXISTS \`'"$MYSQL_DATABASE"'\`; \
            CREATE DATABASE \`'"$MYSQL_DATABASE"'\`;"'

echo "[restauration] chargement du dump..."
docker compose -f "$FICHIER_COMPOSE" exec -T mysql \
    sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$MYSQL_DATABASE"' \
    < "$DUMP_EXTRAIT"

# ON VERIFIE LE RESULTAT, PAS LE CODE DE RETOUR. `mysql` rend 0 sur un
# fichier tronque comme sur un fichier entier : son code ne distingue pas
# une base restauree d'une base a moitie chargee. La seule question dont
# la reponse ne ment pas est « qu'y a-t-il dans la base, maintenant ? ».
#
# Le `|| true` est indispensable : sous `set -e`, une substitution de
# commande qui echoue dans une affectation tue le script SUR PLACE —
# exactement dans le cas que ce controle existe pour attraper. On sortirait
# alors en erreur sans avoir affiche le diagnostic ci-dessous.
# / We check the outcome, not the exit code. Under set -e, a failing
# command substitution kills the script on the spot — precisely in the
# case this check exists to catch.
NOMBRE_DE_COMPTES="$(docker compose -f "$FICHIER_COMPOSE" exec -T mysql \
    sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -B -u"$MYSQL_USER" \
        -e "select count(*) from users" "$MYSQL_DATABASE"' \
    2>/dev/null | tr -d '[:space:]' || true)"

case "$NOMBRE_DE_COMPTES" in
    ''|*[!0-9]*)
        # ON DESARME LE TRAP, ET C'EST TOUT L'INTERET DE CE BLOC. Sans
        # cette ligne, le message ci-dessous disait « ne pas remettre le
        # site en service » et le trap EXIT le remettait en service dans
        # la seconde : le backend rejouait ses migrations sur une base
        # VIDE, le site repondait 200, et un utilisateur pouvait se
        # reinscrire et ecrire par-dessus le sinistre. Un script qui
        # contredit son propre avertissement est pire qu'un script muet.
        # / Without this, the trap put the site back online one second
        # after saying not to: the backend re-migrated an EMPTY database
        # and answered 200.
        trap - EXIT
        echo >&2
        echo "[restauration] ECHEC : la base ne repond pas apres la restauration." >&2
        echo "               La table users est introuvable — rien n'a ete" >&2
        echo "               restaure. Causes habituelles : mot de passe root" >&2
        echo "               change depuis l'archive, dump illisible (le" >&2
        echo "               verifier : make verif-archive)." >&2
        echo >&2
        echo "               frontend, backend et rustfs sont RESTES ARRETES," >&2
        echo "               volontairement : la base est probablement vide, et" >&2
        echo "               les redemarrer laisserait le site accepter des" >&2
        echo "               ecritures par-dessus le sinistre." >&2
        echo "               Les relancer quand la restauration aura abouti :" >&2
        echo "                 docker compose start $SERVICES_A_ETEINDRE" >&2
        exit 1
        ;;
esac
echo "[restauration] base restauree — $NOMBRE_DE_COMPTES compte(s)."


#### RESTAURATION DU STOCKAGE S3 ####
if [ -n "$TAR_EXTRAIT" ] && [ -f "$TAR_EXTRAIT" ]; then
    # Le meme garde-fou que dans bin/backup.sh, et pour la meme raison :
    # `docker run -v <nom>:/data` CREE le volume s'il n'existe pas. Sans
    # ce controle, une restauration lancee avant `make install`, ou apres
    # un renommage, remplissait consciencieusement un volume que personne
    # ne monte — et annoncait « stockage S3 restaure — 42 entrees ».
    # / docker would CREATE the volume: the restore would fill a volume
    # nobody mounts, and report success.
    docker volume inspect "$VOLUME_S3" >/dev/null 2>&1 || {
        echo "[restauration] volume introuvable : $VOLUME_S3" >&2
        echo "               La stack a-t-elle deja demarre une fois ?" >&2
        echo "               Lancer make install, puis relancer la restauration." >&2
        exit 1
    }
    echo "[restauration] remise en place des fichiers televerses..."
    # On VIDE le volume avant de deplier. Contrairement aux medias d'un
    # dossier applicatif, ce volume porte l'INDEX interne de rustfs : y
    # superposer une archive laisserait un index qui decrit des objets
    # absents et des objets que l'index ignore. Le seul etat coherent est
    # celui de l'archive, en entier.
    #
    # `--numeric-owner` : le tar a ete cree en lisant des fichiers de
    # l'uid 10001, celui de rustfs. Sans cette option, tar chercherait un
    # NOM d'utilisateur qui n'existe pas dans le conteneur jetable et
    # reposerait tout en root — rustfs ne pourrait plus rien lire.
    # / The volume holds rustfs's own index: overlaying would leave it
    # describing objects that are not there. --numeric-owner keeps uid
    # 10001, without which rustfs could no longer read its own files.
    # LE MEME DESARMEMENT QUE POUR LA BASE, ET POUR LA MEME RAISON. Le
    # `tar -tf` en amont attrape une archive tronquee, mais pas un echec
    # PENDANT l'extraction : disque plein, conteneur tue, et le volume
    # reste a moitie vide. Sans ce bloc, le trap relancait rustfs sur un
    # /data ampute de son format.json — c'est-a-dire un stockage qui ne
    # sait plus ce qu'il contient — sans un mot d'avertissement.
    # / The upstream tar -tf catches a truncated archive, not a failure
    # DURING extraction: the trap restarted rustfs on a half-emptied
    # volume, silently.
    docker run --rm -i -v "$VOLUME_S3":/data alpine:3.20 \
        sh -c 'find /data -mindepth 1 -delete && exec tar -xpf - --numeric-owner -C /data' \
        < "$TAR_EXTRAIT" || {
        trap - EXIT
        echo >&2
        echo "[restauration] ECHEC en pleine extraction du stockage S3." >&2
        echo "               Le volume est dans un etat INCOHERENT : a moitie" >&2
        echo "               vide, sans forcement son index." >&2
        echo >&2
        echo "               LES TROIS SERVICES RESTENT ARRETES, volontairement." >&2
        echo "               Le backend refuserait de toute facon de demarrer :" >&2
        echo "               il cree ses buckets au lancement et s'arrete si le" >&2
        echo "               stockage ne repond pas. Le relancer ne donnerait" >&2
        echo "               qu'une boucle de redemarrage." >&2
        echo >&2
        echo "               Cause habituelle : disque plein (df -h)." >&2
        echo "               Puis refaire une restauration complete :" >&2
        echo "                 make restore ARCHIVE=$ARCHIVE" >&2
        exit 1
    }
    NOMBRE_D_OBJETS="$(tar -tf "$TAR_EXTRAIT" | wc -l)"
    echo "[restauration] stockage S3 restaure — $NOMBRE_D_OBJETS entrees."
    rm -f "$TAR_EXTRAIT"
else
    echo "[restauration] [INFO] aucun stockage S3 dans cette archive." >&2
fi


#### LE .env DE L'ARCHIVE : DEPOSE, JAMAIS INSTALLE ####
rm -f "$DUMP_EXTRAIT"
echo
if [ -n "$ENV_DE_L_ARCHIVE" ] && [ -f "$ENV_DE_L_ARCHIVE" ]; then
    echo "[restauration] Le .env de l'archive est ici, a comparer a la main :"
    echo "               $ENV_DE_L_ARCHIVE"
    echo "               Le .env courant n'a PAS ete touche (il porte la"
    echo "               passphrase du depot en service)."
else
    echo "[restauration] [INFO] aucun .env dans cette archive." >&2
fi
echo "[restauration] Dossier de travail a supprimer quand tu as fini :"
echo "               rm -rf $DOSSIER_DE_RESTAURATION"
echo
echo "[restauration] Terminee depuis l'archive $ARCHIVE."
echo "[restauration] Le redemarrage du backend rejoue ses migrations : le"
echo "               schema sera remis a niveau avant que le site ne serve."
