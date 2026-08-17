#!/bin/bash
# =============================================================================
# bin/backup.sh — Sauvegarde Alexandrie vers un depot borg
# / bin/backup.sh — Alexandrie backup to a borg repository
#
# S'EXECUTE DEPUIS L'HOTE, jamais dans un conteneur. Il pilote Docker et
# sera pose dans le crontab de la machine : un script qui vit dans le
# conteneur ne peut faire ni l'un ni l'autre.
# / Runs from the HOST: it drives Docker and sits in the crontab.
#
# CE QUI PART DANS L'ARCHIVE, ET POURQUOI SEULEMENT CA
#
#   le dump MySQL    la base entiere (comptes, documents, arborescence,
#                    permissions), au format SQL
#   rustfs.tar       le contenu du volume S3 : images, PDF, pieces
#                    jointes. Hors git, hors base, irremplacable.
#   .env             la cle JWT, les mots de passe et les cles S3
#
# Le reste est dans git ou dans les images publiees : docker-compose.yml,
# Makefile, bin/. Les rearchiver chaque nuit n'apporterait rien qu'un
# `git clone` ne rende deja. Une restauration complete se lit donc :
#
#   git clone <depot> && cp <.env du coffre> .env && make install
#   make restore
#
# CONFIGURATION : ce script ne contient AUCUN secret. Il lit le `.env` de
# la racine, que git ignore. Un script est fait pour etre versionne et
# partage — une passphrase ecrite dedans finit poussee sur la forge au
# premier `git add -A` distrait.
#
# Le `.env` part donc dans l'archive, passphrase du depot comprise. C'est
# sans consequence : il faut deja connaitre cette passphrase pour ouvrir
# l'archive qui la contient.
#
# USAGE
#   make backup     c'est tout.
#
# UNE SEULE COMMANDE, ET C'EST VOULU
#
# Au premier lancement sur une machine, rien n'est configure : ce script
# enchaine alors sur `bin/init_backup.sh` — cle SSH, depot, .env, cron —
# qui se termine par une premiere sauvegarde et sa verification.
#
# Il n'y a donc PAS de commande d'initialisation a retenir. Une commande
# qu'on ne tape qu'une fois dans la vie d'une machine est une commande
# qu'on ne retrouve pas le jour ou on en a besoin.
# / One command only. A command typed once in a machine's lifetime is a
# command nobody finds again.
#
# Le mot de passe MySQL n'est pas recopie dans une ligne de commande : il
# est lu DANS le conteneur, au moment du dump.
# / The MySQL password is read inside the container at dump time.
# =============================================================================
set -euo pipefail

## Surveillance optionnelle via Sentry :
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"

FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"
FICHIER_COMPOSE="$REPERTOIRE_DU_PROJET/docker-compose.yml"

# Le nom est FIXE par `name:` dans docker-compose.yml, pas derive du nom du
# dossier. Voir le commentaire de la section `volumes:` : un prefixe qui
# bouge ferait sauvegarder un volume vide.
# / Fixed by `name:` in the compose file, not derived from the directory.
VOLUME_S3="alexandrie_rustfs_data"

[ -f "$FICHIER_ENV" ] || {
    echo "[sauvegarde] .env introuvable : $FICHIER_ENV" >&2
    exit 1
}
# `UID` et `GID` sont des variables en LECTURE SEULE de bash : si le .env
# venait a en porter une, un `. "$FICHIER_ENV"` brut echouerait, et avec
# `set -e` le script s'arreterait LA — sortie en quelques millisecondes,
# rien d'archive, une seule ligne d'erreur. On les ecarte a la lecture.
# / UID and GID are read-only in bash: a plain source would abort the
# script under set -e, silently producing no backup at all.
set -a
# shellcheck disable=SC1090
. <(grep -vE '^[[:space:]]*(UID|GID)=' "$FICHIER_ENV")
set +a

#### PREMIER LANCEMENT : RIEN N'EST ENCORE CONFIGURE ####
# `make backup` sur une machine neuve doit SAUVEGARDER, pas refuser. Le
# script sait deja que rien n'est configure : c'est a lui d'enchainer sur
# l'initialisation, qui se termine justement par une premiere sauvegarde
# et sa verification.
#
# `exec` remplace ce process au lieu de l'appeler : aucune pile ne
# s'empile, et le .env desormais complet fait que la sauvegarde relancee
# par l'initialisation ne repasse pas par ici.
# / `exec` replaces this process, so nothing stacks up, and the now
# complete .env means the backup it launches will not come back here.
if [ -z "${BORG_PREFIX:-}" ] || [ -z "${BORG_REPO:-}" ] || [ -z "${BORG_PASSPHRASE:-}" ]; then
    echo "[sauvegarde] Aucune sauvegarde configuree sur cette machine."
    if [ ! -t 0 ]; then
        echo "[sauvegarde] La configuration demande un terminal : elle" >&2
        echo "             genere une cle SSH, cree le depot, et te fait" >&2
        echo "             mettre la passphrase au coffre." >&2
        echo "[sauvegarde] La lancer une premiere fois a la main :  make backup" >&2
        exit 1
    fi
    echo "[sauvegarde] Configuration, puis premiere sauvegarde."
    exec bash "$REPERTOIRE_DU_SCRIPT/init_backup.sh"
fi

PREFIXE="$BORG_PREFIX"

# Cle SSH DEDIEE a ce depot. Sur borgwarehouse, une cle publique donne
# acces a UN depot et un seul ; une machine qui sauvegarde deux cibles a
# donc besoin de deux cles. Le nom vient du prefixe, ce qui les fait
# cohabiter sans collision. / One SSH key = one repository.
CLE_SSH="$REPERTOIRE_DU_SCRIPT/.ssh/${PREFIXE}_ed25519"

# Dossier de travail, supprime apres l'archivage. Ce chemin n'est PAS
# surchargeable : une variable egaree dans le .env, lu juste au-dessus,
# le detournerait en silence.
# / Not overridable: a stray variable in the sourced .env would silently
# redirect it.
REPERTOIRE_DU_DUMP="$REPERTOIRE_DU_PROJET/.dump-$PREFIXE"


#### PREPARATION ####
# Le depot peut avoir change d'adresse (serveur renomme, dossier deplace,
# restauration sur une autre machine) : borg demande alors une
# confirmation interactive, qu'un cron ne pourra jamais donner. Les
# scripts posent tous la MEME variable — sans quoi la sauvegarde passerait
# et la verification echouerait, ou l'inverse.
# / Set identically in all the scripts.
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Les outils AVANT de s'en servir : verifier `flock` apres l'avoir utilise
# ferait rendre « une sauvegarde est deja en cours » quand il manque — un
# message qui envoie chercher un probleme qui n'existe pas.
# / Tools checked before use.
for outil in borg docker flock; do
    command -v "$outil" >/dev/null || {
        echo "[sauvegarde] $outil introuvable dans le PATH" >&2
        exit 1
    }
done
[ -f "$FICHIER_COMPOSE" ] || {
    echo "[sauvegarde] docker-compose.yml introuvable : $FICHIER_COMPOSE" >&2
    exit 1
}

# Une seule sauvegarde a la fois. Sans ce verrou, un lancement manuel qui
# tombe pendant le cron partage le meme dossier de travail : le premier a
# finir le supprime — trap EXIT — pendant que l'autre archive encore, et
# on obtient une archive SANS DUMP, silencieusement.
# / Without this lock, one run deletes the working directory while the
# other is still archiving: an archive with no dump, silently.
exec 9>"$REPERTOIRE_DU_PROJET/.backup-$PREFIXE.lock"
flock -n 9 || {
    echo "[sauvegarde] une sauvegarde est deja en cours — abandon." >&2
    exit 1
}

# UNE REPETITION GENERALE EST-ELLE EN COURS ? Le verrou ci-dessus ne suffit
# pas : `make backup-check` detruit les volumes, remonte la stack A VIDE,
# puis restaure. Entre le remontage et la restauration, la stack est
# parfaitement SAINE et parfaitement VIDE, et le verrou est libre — chaque
# script le prend pour lui seul. Un cron qui tombe pile dans cette fenetre
# archiverait cette base vide : dump complet, marqueur de fin present, tar
# coherent avec un volume neuf. L'archive passerait toutes les
# verifications, et deviendrait LA PLUS RECENTE — donc la cible par defaut
# du prochain `make restore` sans ARCHIVE=.
#
# Le marqueur est pose par bin/check_backup.sh avant le `down -v` et
# retire a sa sortie, quoi qu'il arrive.
# / The lock is not enough: between the drill's re-up and its restore, the
# stack is healthy AND empty and the lock is free. A cron falling there
# would archive that empty database, and the poisoned archive would become
# the most recent one.
MARQUEUR_DE_REPETITION="$REPERTOIRE_DU_PROJET/.repetition-$PREFIXE.encours"
if [ -f "$MARQUEUR_DE_REPETITION" ]; then
    echo "[sauvegarde] une repetition generale est en cours depuis $(cat "$MARQUEUR_DE_REPETITION" 2>/dev/null)." >&2
    echo "[sauvegarde] La stack est peut-etre vide : sauvegarder maintenant" >&2
    echo "             creerait une archive vide qui deviendrait la plus" >&2
    echo "             recente. Abandon — la prochaine passera." >&2
    echo "[sauvegarde] (Si aucune repetition ne tourne, ce fichier est un" >&2
    echo "             residu : rm $MARQUEUR_DE_REPETITION)" >&2
    exit 0
fi

# Les SECONDES comptent dans le nom : borg refuse deux archives
# homonymes, et un horodatage a la minute fait echouer deux `make backup`
# lances a la suite sur un « Archive ... already exists ». Une sauvegarde
# manuelle juste apres une autre est un geste normal — en particulier au
# debut de `make backup-check`, qui en prend une avant de tout eteindre.
# / Seconds matter: borg refuses homonymous archives.
HORODATAGE=$(date +%Y-%m-%d-%H-%M-%S)

# Force l'usage de CETTE cle, et d'elle seule : sans -oIdentitiesOnly=yes,
# l'agent SSH proposerait d'abord une autre cle et le serveur refuserait
# la connexion. Le chemin est entre quotes SIMPLES a l'interieur de la
# variable : borg decoupe BORG_RSH comme un shell, donc un projet installe
# sous un chemin a espaces casserait ssh.
# / Forces this key only; borg splits BORG_RSH shell-style.
if [ -f "$CLE_SSH" ]; then
    chmod 600 "$CLE_SSH" 2>/dev/null || true
    export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i '$CLE_SSH'"
else
    echo "[sauvegarde] [INFO] aucune cle a $CLE_SSH — SSH utilisera la config systeme." >&2
fi


#### DUMP MYSQL ####
# Nettoyage garanti du dossier de travail, meme en cas d'erreur.
trap 'rm -rf "$REPERTOIRE_DU_DUMP"' EXIT
rm -rf "$REPERTOIRE_DU_DUMP"
mkdir -p "$REPERTOIRE_DU_DUMP"
FICHIER_DU_DUMP="$REPERTOIRE_DU_DUMP/alexandrie.sql"
FICHIER_DU_TAR="$REPERTOIRE_DU_DUMP/rustfs.tar"

echo "$HORODATAGE dump de la base MySQL"
# --single-transaction : dump coherent sans verrouiller les tables, le
#   site continue de servir pendant la sauvegarde (InnoDB).
# --no-tablespaces : sans lui, MySQL 8 exige le privilege PROCESS, que
#   l'utilisateur applicatif n'a pas — le dump echouerait sur « Access
#   denied; you need PROCESS privilege ».
# --routines --triggers : la logique stockee part avec les donnees.
#
# MYSQL_PWD plutot que `-p<mot de passe>` : sous cette forme, le mot de
# passe est une variable d'environnement du process, invisible a un `ps`
# lance au meme instant. Avec `-p`, il apparait dans la ligne de commande.
# Les identifiants viennent de l'environnement DU CONTENEUR : ils ne
# transitent ni par ce script, ni par le crontab, ni par les journaux.
# / MYSQL_PWD keeps the password out of the process's argv; the
# credentials come from the container's own environment.
docker compose -f "$FICHIER_COMPOSE" exec -T mysql \
    sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" \
        exec mysqldump --single-transaction --quick --no-tablespaces \
            --routines --triggers \
            -u"$MYSQL_USER" "$MYSQL_DATABASE"' \
    > "$FICHIER_DU_DUMP"

# Garde-fou : un dump vide s'archive proprement et ne restaure rien.
# / An empty dump archives cleanly and restores nothing.
if [ ! -s "$FICHIER_DU_DUMP" ]; then
    echo "[sauvegarde] dump vide ($FICHIER_DU_DUMP) — abandon" >&2
    exit 1
fi
echo "$HORODATAGE dump : $(du -h "$FICHIER_DU_DUMP" | cut -f1)"


#### CONTENU DU STOCKAGE S3 ####
# Les fichiers televerses sont la RAISON D'ETRE de cette sauvegarde : la
# base se reconstruit a partir d'un export, les PDF et les images non.
#
# Ils vivent dans un VOLUME DOCKER, pas dans un dossier de l'hote, et
# rustfs tourne en uid 10001 avec /data en 0750 : meme monte, l'utilisateur
# qui lance borg ne pourrait pas les lire. On sort donc le contenu par un
# conteneur jetable — la lecture s'y fait en root — dont la sortie standard
# est redirigee COTE HOTE : le fichier produit appartient a l'utilisateur.
# / The files live in a Docker volume owned by uid 10001, mode 0750: even
# mounted, the user running borg could not read them. A throwaway
# container reads them as root and writes to a host-side redirection.
#
# Le volume est verifie AVANT : `docker run -v <nom>:/data` CREE le volume
# s'il n'existe pas, et tar rendrait alors une archive vide sans une seule
# erreur. Des semaines de sauvegardes « fraiches » sans un seul fichier, et
# on ne l'apprendrait qu'en restaurant.
# / Checked first: docker would CREATE the volume if absent, and tar would
# produce an empty archive without a single error.
if ! docker volume inspect "$VOLUME_S3" >/dev/null 2>&1; then
    echo "[sauvegarde] volume introuvable : $VOLUME_S3" >&2
    echo "[sauvegarde] La stack n'a jamais demarre ? Le volume a-t-il ete" >&2
    echo "             renomme ? On n'archive PAS une sauvegarde amputee de" >&2
    echo "             ce qu'elle sert a proteger." >&2
    exit 1
fi

echo "$HORODATAGE extraction du stockage S3 ($VOLUME_S3)"
docker run --rm -v "$VOLUME_S3":/data:ro alpine:3.20 \
    tar -cf - -C /data . > "$FICHIER_DU_TAR"

# Le tar est-il exploitable ? `tar -tf` le deroule entierement : une
# coupure — disque plein, conteneur tue — est demasquee ici, pas six mois
# plus tard. / A full unroll catches a truncation now, not six months on.
if ! tar -tf "$FICHIER_DU_TAR" >/dev/null 2>&1; then
    echo "[sauvegarde] rustfs.tar illisible ou tronque — abandon" >&2
    exit 1
fi
NOMBRE_D_OBJETS="$(tar -tf "$FICHIER_DU_TAR" | wc -l)"

# LE TAR PORTE-T-IL LES FICHIERS QUE LA BASE DIT EXISTER ?
#
# Un tar DEROULABLE peut etre quasiment VIDE : `tar -c` sur un /data neuf
# produit une archive parfaitement valide, et la verification annoncerait
# « stockage S3 deroule entierement » — au vert. Le scenario n'a rien de
# theorique : un `docker volume rm` suivi d'un `make install` donne
# exactement cela, les nuits suivantes archivent du vide, et la rotation
# finit par purger les bonnes archives.
#
# Une premiere version comparait le tar au VOLUME VIVANT. C'etait inutile
# et nuisible : inutile parce que dans ce scenario le volume vivant est
# vide lui aussi, donc les deux comptes concordent et le controle passe ;
# nuisible parce que le comptage vivant incluait `.rustfs.sys`, dont la
# corbeille se purge toute seule — un fichier disparu entre le `tar` et le
# `find` faisait AVORTER la sauvegarde de cron sur une stack saine.
#
# La bonne reference n'est pas le volume, c'est LA BASE : elle sait
# combien de fichiers ont ete televerses (`nodes` de role 4). Si elle en
# annonce et que le tar n'en porte aucun, le volume a ete perdu. La
# comparaison est volontairement ASYMETRIQUE — on ne refuse que le cas
# « la base dit oui, le stockage dit rien » — pour qu'un televersement en
# cours ne puisse jamais faire echouer une sauvegarde saine.
# / Comparing the tar to the LIVE volume was both useless (in the
# scenario, the live volume is empty too) and harmful (rustfs's
# self-emptying trash aborted healthy cron backups). The database knows
# how many files were uploaded; the check is deliberately asymmetric.
OBJETS_DANS_LE_TAR="$(tar -tf "$FICHIER_DU_TAR" | grep -c "^\./${MINIO_BUCKET:-alexandrie}/.*/" || true)"
FICHIERS_EN_BASE="$(docker compose -f "$FICHIER_COMPOSE" exec -T mysql \
    sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -B -u"$MYSQL_USER" \
        -e "$1" "$MYSQL_DATABASE"' _ 'select count(*) from nodes where role = 4' \
    2>/dev/null | tr -d '[:space:]' || true)"

case "$FICHIERS_EN_BASE" in
    ''|*[!0-9]*)
        # La base n'a pas repondu : on ne peut rien conclure, et surtout
        # pas refuser. Le dump, lui, a deja reussi juste au-dessus.
        echo "[sauvegarde] [INFO] nombre de fichiers en base illisible — controle croise saute." >&2
        ;;
    0) : ;;
    *)
        if [ "$OBJETS_DANS_LE_TAR" -eq 0 ]; then
            echo "[sauvegarde] ABANDON : la base annonce $FICHIERS_EN_BASE fichier(s)" >&2
            echo "             televerse(s), et le stockage archive n'en porte AUCUN." >&2
            echo "             Le volume $VOLUME_S3 a-t-il ete recree ?" >&2
            echo "             On n'archive PAS une sauvegarde amputee de ce" >&2
            echo "             qu'elle sert a proteger." >&2
            exit 1
        fi
        ;;
esac
echo "$HORODATAGE stockage S3 : $(du -h "$FICHIER_DU_TAR" | cut -f1), $NOMBRE_D_OBJETS entrees, $OBJETS_DANS_LE_TAR objets"


#### CREATION DE L'ARCHIVE ####
# Codes de sortie borg : 0 succes, 1 avertissement (un fichier a bouge
# pendant la lecture), 2 et plus vraie erreur. Avec `set -e`, un simple
# avertissement tuerait le script. On tolere 1, on echoue des 2.
# / borg exit code 1 is a warning.
borg_tolerant() {
    local code=0
    "$@" || code=$?
    if [ "$code" -ge 2 ]; then
        echo "[sauvegarde] ERREUR : borg a echoue (code $code)" >&2
        exit "$code"
    fi
    [ "$code" -eq 1 ] && echo "[sauvegarde] (avertissement borg ignore, code 1)" >&2
    return 0
}

echo "$HORODATAGE creation de l'archive : dump + stockage S3 + .env"
borg_tolerant borg create -vs --compression lz4 \
    "$BORG_REPO::$PREFIXE-$HORODATAGE" \
    "$REPERTOIRE_DU_DUMP" \
    "$FICHIER_ENV"

echo "$HORODATAGE rotation des anciennes archives :"
# --glob-archives : la rotation ne touche QUE les archives de cette stack.
# Si deux sauvegardes partagent un depot, sans ce filtre elles se rognent
# mutuellement leur retention, en silence.
# / The prune only touches this stack's archives.
# LA RETENTION EST BORNEE, ET IL LE FAUT. Elle etait ecrite
# `--keep-monthly=-1 --keep-yearly=-1`, ce qui ne veut pas dire « pas de
# mensuel » mais « garder TOUS les mensuels et TOUS les annuels, pour
# toujours ». La retention n'existait donc que sur le papier : face au
# quota de 20 Go propose par defaut a la configuration, le depot se
# remplit jusqu'a ce que `borg create` echoue — des mois plus tard, pour
# une raison qui n'aura plus rien a voir avec ce jour-la.
#
# 7 jours glissants, 30 quotidiennes, 12 hebdomadaires, 12 mensuelles,
# 3 annuelles : trois ans d'historique, et une taille qui se stabilise.
# / -1 does not mean "none", it means "keep them all, forever": the
# retention existed on paper only.
borg_tolerant borg prune -v --list \
    --glob-archives "$PREFIXE-*" \
    --keep-within=7d --keep-daily=30 --keep-weekly=12 \
    --keep-monthly=12 --keep-yearly=3 \
    "$BORG_REPO"

# `prune` DELIE les archives, il ne rend pas la place : depuis borg 1.2,
# c'est `compact` qui la libere, et lui seul. Sans cette ligne, la
# retention n'existe que sur le papier : le quota du depot se remplit
# jusqu'a ce que `borg create` echoue, des mois plus tard, pour une raison
# qui n'aura plus rien a voir avec ce jour-la.
# / prune unlinks archives; since borg 1.2 only compact frees the space.
echo "$HORODATAGE liberation de la place :"
borg_tolerant borg compact "$BORG_REPO"

echo "$HORODATAGE termine. Verifier qu'elle est restaurable : make verif-archive"
