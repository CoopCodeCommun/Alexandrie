#!/bin/bash
# =============================================================================
# bin/check_backup.sh — La repetition generale du sinistre
# / bin/check_backup.sh — The full disaster-recovery drill
#
# S'EXECUTE DEPUIS L'HOTE.   Lance par :  make backup-check
#
# ELLE ETEINT LE SITE, DETRUIT LES VOLUMES, ET LE REMONTE DEPUIS LA
# SAUVEGARDE. C'est le seul controle qui prouve vraiment quelque chose :
# une archive qu'on a lue n'est pas une archive qu'on a rechargee.
# / It takes the site down, destroys the volumes, and rebuilds it from the
# backup. An archive you have read is not an archive you have reloaded.
#
# ELLE NE PERD RIEN, ET CE N'EST PAS UN VOEU
#
# L'archive rechargee est celle que ce script vient de prendre, a l'etape
# 2. Le systeme revient donc EXACTEMENT ou il etait ; la seule depense est
# l'interruption de service. / The archive reloaded is the one this script
# has just taken: the system returns exactly where it was.
#
# L'ORDRE DES ETAPES EST TOUT
#
#   1. relever l'etat courant (lignes en base, fichiers televerses)
#   2. prendre une sauvegarde fraiche
#   3. LA VERIFIER — et s'arreter la si elle cloche
#   4. detruire conteneurs et volumes
#   5. remonter a vide, restaurer, comparer a l'etape 1
#
# L'etape 3 est la raison d'etre de cet ordre. Sans elle, une repetition
# generale lancee un jour ou la sauvegarde etait cassee DETRUIRAIT les
# donnees qu'elle est censee proteger — et c'est justement le jour ou elle
# a le plus de chances d'etre lancee. Tant que l'archive n'est pas jugee
# restaurable, rien n'est touche.
# / Without step 3, a drill run on a day when the backup was broken would
# destroy the very data it exists to protect — and that is exactly the day
# it is most likely to be run.
#
# A NE PAS METTRE DANS UN CRON. Le controle qui va dans un cron, c'est
# `make verif-archive` : il ne touche a rien et sort en code non nul quand
# quelque chose cloche. Celui-ci se lance a la main, quand on accepte
# quelques minutes de coupure — une fois par trimestre, ou apres tout
# changement de la chaine de sauvegarde.
# / Not for a cron: that is `make verif-archive`.
#
# USAGE
#   make backup-check                 (demande confirmation)
#   make backup-check CONFIRME=oui    (sans question)
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"

FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"
FICHIER_COMPOSE="$REPERTOIRE_DU_PROJET/docker-compose.yml"
VOLUME_S3="alexandrie_rustfs_data"

# Les tables comparees avant et apres. `nodes` porte TOUT le contenu :
# documents, dossiers et fichiers televerses ne sont qu'un champ `role` de
# cette table.
#
# `sessions` en est ABSENTE, et il le faut : le backend supprime les
# sessions perimees a chaque demarrage — il le fait donc au milieu de
# cette repetition. La comparer ferait echouer une restauration reussie.
# / `sessions` is deliberately absent: the backend prunes stale sessions
# at every startup, hence in the middle of this drill.
TABLES_COMPAREES="users nodes permissions user_settings"

NOMBRE_D_ERREURS=0
dire()  { echo "[repetition] $*"; }
ok()    { echo "  [ok]   $*"; }
ko()    { echo "  [KO]   $*" >&2; NOMBRE_D_ERREURS=$((NOMBRE_D_ERREURS + 1)); }
fatal() { echo "[repetition] ERREUR : $*" >&2; exit 2; }

[ -f "$FICHIER_ENV" ] || fatal ".env introuvable : $FICHIER_ENV"
[ -f "$FICHIER_COMPOSE" ] || fatal "docker-compose.yml introuvable : $FICHIER_COMPOSE"
set -a
# shellcheck disable=SC1090
. <(grep -vE '^[[:space:]]*(UID|GID)=' "$FICHIER_ENV")
set +a

: "${BORG_PREFIX:?BORG_PREFIX absent du .env — sauvegarde non configuree, voir : make backup}"
: "${BORG_REPO:?BORG_REPO absent du .env — sauvegarde non configuree, voir : make backup}"
# La passphrase aussi, et pas seulement pour la forme : sans elle,
# l'etape de sauvegarde bifurquerait vers l'initialisation INTERACTIVE au
# beau milieu de la repetition, et celle-ci tenterait de regenerer une
# passphrase face a un depot deja plein. Rien ne serait detruit — tout
# cela se passe avant l'etape destructrice — mais le diagnostic serait
# illisible. / Without it, the backup step would branch into the
# interactive setup in the middle of the drill.
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env — sauvegarde non configuree, voir : make backup}"
: "${DOMAIN:?DOMAIN absent du .env}"
for outil in borg docker curl; do
    command -v "$outil" >/dev/null || fatal "$outil introuvable dans le PATH."
done

# LA CLE DU DEPOT, COMME DANS LES QUATRE AUTRES SCRIPTS. Elle manquait
# ici, et ce script interroge pourtant `borg list` en direct (plus bas,
# pour retenir le nom de l'archive de reference). Sur un depot
# borgwarehouse, la cle vit dans bin/.ssh/ et n'est JAMAIS proposee par
# la configuration ssh du systeme : le `borg list` echouait sur un
# « Permission denied (publickey) » et `set -e` tuait la repetition —
# apres la sauvegarde, avant toute destruction, donc sans perte, mais
# `make backup-check` etait inutilisable en production. Le defaut ne
# pouvait pas se voir sur un depot LOCAL, qui ne passe pas par ssh :
# c'est exactement ce qui a servi a la mise au point.
# / The key was missing here alone, and a local test repository — which
# never goes through ssh — could not reveal it.
CLE_SSH="$REPERTOIRE_DU_SCRIPT/.ssh/${BORG_PREFIX}_ed25519"
[ -f "$CLE_SSH" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i '$CLE_SSH'"
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes


#### OUTILLAGE DE MESURE ####
# La requete est passee en ARGUMENT au shell du conteneur, pas collee
# dans son texte : collee, une requete portant un guillemet refermerait le
# `-e "` a sa place, et mysql rendrait une chaine vide sur une base
# parfaitement lisible.
# / Passed as an ARGUMENT: pasted, a query holding a quote would close the
# `-e "` early and mysql would answer an empty string.
dans_mysql() {
    docker compose -f "$FICHIER_COMPOSE" exec -T mysql \
        sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -B -u"$MYSQL_USER" \
            -e "$1" "$MYSQL_DATABASE"' _ "$1" 2>/dev/null | tr -d '[:space:]'
}

compter_les_lignes() {  # compter_les_lignes -> "users=3 documents=12 ..."
    local resultat="" table nombre
    for table in $TABLES_COMPAREES; do
        # `|| true` : une table absente doit donner « ? », pas tuer le
        # script — c'est precisement ce qu'on cherche a detecter.
        # / A missing table must read "?" and not kill the script.
        nombre="$(dans_mysql "select count(*) from $table" || true)"
        case "$nombre" in ''|*[!0-9]*) nombre="?" ;; esac
        resultat="$resultat $table=$nombre"
    done
    echo "${resultat# }"
}

compter_les_fichiers() {  # nombre de fichiers TELEVERSES dans le volume S3
    # `docker run -v <nom>:/data` CREERAIT le volume s'il manquait, et
    # rendrait 0 sans erreur. On verifie donc son existence d'abord : un
    # volume absent doit se lire « ? », pas « zero fichier ».
    # / docker would CREATE the volume if absent and answer 0.
    docker volume inspect "$VOLUME_S3" >/dev/null 2>&1 || { echo "?"; return 0; }
    # ON NE COMPTE QUE LE BUCKET DES UTILISATEURS. Deux dossiers voisins
    # bougent tout seuls, et les compter fait echouer la repetition sur
    # une restauration parfaite :
    #
    #   .rustfs.sys           la comptabilite interne de rustfs, avec une
    #                         corbeille qui se purge seule — mesure du
    #                         16 aout 2026 : 64 fichiers a 15 h 19, 20 a
    #                         17 h 22, sans un seul televersement entre
    #                         les deux ;
    #   <bucket>-backups      le bucket des exports d'Alexandrie, que le
    #                         backend cree avec une regle d'expiration a
    #                         UN JOUR (app/minio.go). Une expiration qui
    #                         tombe pendant la manoeuvre suffisait a
    #                         rendre « 4 avant, 3 apres ».
    #
    # Reste `<bucket>` : ce que les utilisateurs ont depose, et la seule
    # chose dont la disparition voudrait dire quelque chose.
    # / Two neighbouring directories change on their own: rustfs's
    # bookkeeping with its self-emptying trash, and the exports bucket
    # whose lifecycle rule expires objects after one day.
    docker run --rm -v "$VOLUME_S3":/data:ro alpine:3.20 \
        sh -c "find /data/${MINIO_BUCKET:-alexandrie} -type f 2>/dev/null | wc -l" \
        2>/dev/null | tr -d '[:space:]'
}

un_objet_du_bucket() {  # le chemin S3 d'un fichier televerse, ou vide
    # rustfs range chaque objet dans un DOSSIER a son nom, qui contient
    # `xl.meta`. La cle S3 est donc le chemin de ce dossier, prive du
    # prefixe `/data/<bucket>/`.
    # / rustfs stores each object in a directory holding `xl.meta`.
    local bucket="${MINIO_BUCKET:-alexandrie}"
    docker run --rm -v "$VOLUME_S3":/data:ro alpine:3.20 \
        sh -c "find /data/$bucket -name xl.meta -print -quit 2>/dev/null" 2>/dev/null \
        | sed -e "s#^/data/$bucket/##" -e 's#/xl\.meta$##'
}

verifier_http() {  # verifier_http <libelle> <url> <motif de codes acceptes>
    bash "$REPERTOIRE_DU_SCRIPT/verifier_http.sh" "$@" \
        || NOMBRE_D_ERREURS=$((NOMBRE_D_ERREURS + 1))
}


#### 0. LA STACK DOIT TOURNER ####
# Relever l'etat d'avant demande une base qui repond. Sans ce controle, la
# comparaison finale se ferait contre « ? = ? » et la repetition
# s'annoncerait reussie sans avoir rien prouve.
# / Without this, the final comparison would run against "? = ?" and the
# drill would declare success having proved nothing.
docker compose -f "$FICHIER_COMPOSE" exec -T mysql true >/dev/null 2>&1 || {
    fatal "la stack ne tourne pas — impossible de relever l'etat d'avant.
                 La demarrer (make install), puis relancer."
}


#### 1. UN APERCU, POUR DECIDER ####
# Informatif seulement : la mesure qui SERT au verdict est prise plus
# bas, une fois le site gele. Celle-ci existe pour que la question de
# confirmation ne se pose pas dans le vide.
# / Informative only: the measurement the verdict uses is taken below,
# once the site is frozen.
echo
dire "1/7 — etat actuel (apercu)"
echo "  base     : $(compter_les_lignes)"
echo "  fichiers : $(compter_les_fichiers) dans le stockage S3"


#### CONFIRMATION ####
if [ "${CONFIRME:-}" != "oui" ]; then
    echo
    echo "================================================================"
    echo " REPETITION GENERALE DU SINISTRE"
    echo
    echo " Ce qui va se passer, dans cet ordre :"
    echo "   - le site est mis HORS SERVICE (la coupure commence ici)"
    echo "   - une sauvegarde de cet etat gele est prise, puis verifiee ;"
    echo "     si elle cloche, on s'arrete la et RIEN n'est detruit"
    echo "   - les volumes sont DETRUITS"
    echo "   - la stack est remontee a vide, rechargee depuis cette"
    echo "     sauvegarde, et comparee a l'etat gele"
    echo
    echo " LA COUPURE COMMENCE AVANT LA SAUVEGARDE, ET C'EST VOULU : c'est"
    echo " ce qui garantit qu'aucune ecriture ne se glisse entre l'archive"
    echo " et la destruction. Sans cela, une note saisie pendant la"
    echo " manoeuvre serait detruite sans que rien ne le signale."
    echo "================================================================"
    echo
    [ -t 0 ] || fatal "entree non interactive. Pour lancer sans question : make backup-check CONFIRME=oui"
    read -r -p "Taper REPETITION pour continuer : " REPONSE
    [ "$REPONSE" = "REPETITION" ] || { echo "[repetition] annule."; exit 1; }
fi


#### 2. GELER LE SITE ####
# LA COUPURE COMMENCE ICI, ET C'EST LA CORRECTION D'UN DEFAUT DE FOND.
#
# Cette repetition promettait « rien n'est perdu ». C'etait FAUX tant que
# le site restait en service pendant la sauvegarde : entre le dump et le
# `down -v`, il s'ecoule le temps d'archiver et de verifier — plusieurs
# minutes. Une note saisie dans cette fenetre n'etait PAS dans l'archive,
# etait detruite par le `down -v`... et le verdict ne la voyait pas
# passer, puisqu'il comparait a un releve fait AVANT elle. Perte
# silencieuse, sur un outil dont c'est precisement le contraire de la
# raison d'etre.
#
# On eteint donc frontend et backend AVANT de mesurer et d'archiver.
# mysql et rustfs restent debout : c'est par eux que passent le dump et
# le tar. La coupure ne s'allonge pas beaucoup — elle commence quelques
# minutes plus tot, voila tout.
# / The drill promised "nothing is lost". That was false while the site
# kept serving during the backup: a note written in that window was not
# in the archive, was destroyed, and the verdict compared against a
# reading taken before it existed. Silent loss.
echo
dire "2/7 — mise hors service (la coupure commence)"
docker compose -f "$FICHIER_COMPOSE" stop frontend backend

# Quoi qu'il arrive AVANT la destruction, le site repart. Ce trap est
# remplace plus bas, une fois le `down -v` passe : a partir de la, il n'y
# a plus rien a redemarrer, il y a une stack a reconstruire.
# / Until the destruction, whatever happens the site comes back.
# shellcheck disable=SC2064
trap "echo '[repetition] remise en service du site...'; docker compose -f '$FICHIER_COMPOSE' start backend frontend" EXIT


#### 3. L'ETAT GELE — C'EST LUI QUI FAIT FOI ####
echo
dire "3/7 — releve de l'etat gele"
LIGNES_AVANT="$(compter_les_lignes)"
FICHIERS_AVANT="$(compter_les_fichiers)"
echo "  base     : $LIGNES_AVANT"
echo "  fichiers : $FICHIERS_AVANT dans le stockage S3"

# LES DEUX MESURES DOIVENT ETRE LISIBLES ET NUMERIQUES. `?` signale un
# volume absent, mais la chaine VIDE signale un conteneur jetable qui n'a
# pas demarre — et un `case` qui ne cherchait que `?` la laissait passer :
# la destruction partait avec une mesure illisible, exactement le cas que
# ce garde-fou existe pour bloquer.
# / An empty string means the throwaway container never started, and a
# case looking only for `?` let it through.
case "$LIGNES_AVANT" in
    *'=?'*) fatal "une table est illisible : $LIGNES_AVANT
                 Rien n'a ete detruit." ;;
esac
case "$FICHIERS_AVANT" in
    ''|*[!0-9]*) fatal "le nombre de fichiers est illisible : « $FICHIERS_AVANT »
                 Le volume manque, ou le conteneur de mesure n'a pas demarre.
                 Rien n'a ete detruit." ;;
esac


#### 4. SAUVEGARDE DE CET ETAT ####
echo
dire "4/7 — sauvegarde de l'etat gele"
bash "$REPERTOIRE_DU_SCRIPT/backup.sh"


#### 5. CETTE SAUVEGARDE TIENT-ELLE LA ROUTE ? ####
# LE GARDE-FOU. Tout ce qui suit detruit ; ce qui precede ne detruit rien.
# Si l'archive ne passe pas, on sort ICI, et le trap remet le site en
# service. / Everything after this destroys, everything before does not.
echo
dire "5/7 — verification de cette sauvegarde (avant de rien detruire)"
bash "$REPERTOIRE_DU_SCRIPT/verifier_archive.sh" || {
    echo >&2
    fatal "la sauvegarde qui vient d'etre prise n'est pas fiable.
                 RIEN n'a ete detruit : le site va etre remis en service.
                 Corriger la sauvegarde avant de relancer la repetition."
}

ARCHIVE_DE_REFERENCE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
    --format '{archive}{NL}' "$BORG_REPO")"
dire "archive de reference : $ARCHIVE_DE_REFERENCE"


#### 6. LE SINISTRE ####
# A PARTIR D'ICI, LA STACK EST A TERRE. Les etapes qui suivent peuvent
# echouer sous `set -e`, et elles sortaient alors SANS UN MOT, en laissant
# une stack vide devant quelqu'un qui ne sait pas que l'archive, elle, est
# intacte. Tout ce script est construit autour de « rien n'est perdu » :
# encore faut-il le DIRE au moment ou ca compte.
# / From here the stack is down; these steps used to exit silently.
au_secours() {
    echo >&2
    echo "[repetition] ARRET EN PLEIN MILIEU : $1" >&2
    echo >&2
    echo "  La stack est peut-etre vide, mais RIEN N'EST PERDU :" >&2
    echo "  l'archive prise juste avant la destruction est intacte." >&2
    echo >&2
    echo "  Remonter, puis recharger :" >&2
    echo "      make install" >&2
    echo "      make restore ARCHIVE=$ARCHIVE_DE_REFERENCE" >&2
    exit 2
}

# LE TRAP CHANGE DE SENS ICI. Jusqu'a present il remettait le site en
# service ; passe le `down -v`, il n'y a plus de site a rallumer — le
# `docker compose start` d'un conteneur detruit echouerait, et son erreur
# masquerait le vrai message. C'est `au_secours` qui prend le relais.
# / The trap changes meaning: past the down -v there is nothing to
# restart, and `start` on a destroyed container would mask the real error.
trap - EXIT

# LE MARQUEUR DE MANOEUVRE. Entre le `down -v` et la restauration, la
# stack est SAINE ET VIDE, et le verrou de sauvegarde est libre : un cron
# qui tombe pile la archiverait une base vide — dump complet, marqueur de
# fin present, tar minuscule mais coherent — et cette archive empoisonnee
# deviendrait LA PLUS RECENTE, donc la cible par defaut d'un futur
# `make restore` sans ARCHIVE=. bin/backup.sh refuse de tourner tant que
# ce fichier existe.
# / Between the down -v and the restore, the stack is healthy AND empty
# and the backup lock is free: a cron falling there would archive an
# empty database, and that poisoned archive would become the most recent.
MARQUEUR_DE_REPETITION="$REPERTOIRE_DU_PROJET/.repetition-$BORG_PREFIX.encours"
date +%Y-%m-%dT%H:%M:%S > "$MARQUEUR_DE_REPETITION"
trap 'rm -f "$MARQUEUR_DE_REPETITION"' EXIT

echo
dire "6/7 — destruction des conteneurs ET des volumes"
docker compose -f "$FICHIER_COMPOSE" down -v || au_secours "la destruction a echoue"

docker compose -f "$FICHIER_COMPOSE" up -d || au_secours "le remontage a echoue"
bash "$REPERTOIRE_DU_SCRIPT/attendre.sh" 300 || au_secours "la stack n'est pas repartie"


#### 7. LA RESTAURATION ####
echo
dire "7/7 — rechargement depuis $ARCHIVE_DE_REFERENCE"
# La confirmation a deja ete donnee plus haut, et l'archive deja
# verifiee : redemander bloquerait la repetition en plein milieu, stack
# vide. / Asking again would block the drill mid-way, with an empty stack.
RESTAURATION_CONFIRMEE=oui bash "$REPERTOIRE_DU_SCRIPT/restore.sh" "$ARCHIVE_DE_REFERENCE" \
    || au_secours "la restauration a echoue"

# Le backend rejoue ses migrations au demarrage et rouvre ses connexions :
# on lui laisse le temps d'etre pret avant de l'interroger.
# / The backend replays its migrations at startup.
bash "$REPERTOIRE_DU_SCRIPT/attendre.sh" 300 \
    || au_secours "la stack n'est pas repartie apres la restauration"


#### 6. TOUT EST-IL REVENU ? ####
echo
echo "Verdict"
LIGNES_APRES="$(compter_les_lignes)"
FICHIERS_APRES="$(compter_les_fichiers)"

if [ "$LIGNES_APRES" = "$LIGNES_AVANT" ]; then
    ok "base identique : $LIGNES_APRES"
else
    ko "la base a change."
    ko "  avant : $LIGNES_AVANT"
    ko "  apres : $LIGNES_APRES"
fi

if [ "$FICHIERS_APRES" = "$FICHIERS_AVANT" ]; then
    ok "fichiers televerses identiques : $FICHIERS_APRES"
else
    ko "le stockage S3 a change : $FICHIERS_AVANT avant, $FICHIERS_APRES apres."
fi

# Une base juste ne suffit pas : le site doit REPONDRE. Ces trois
# controles traversent Traefik, donc ils eprouvent aussi le routage et les
# certificats — la moitie de l'installation que la base ignore.
# / A correct database is not enough: these three go through Traefik.
# CHAQUE CODE ATTENDU NE DOIT POUVOIR VENIR QUE DU SERVICE VISE.
#
# Traefik rend **404** quand aucun routeur ne correspond a l'hote — un
# conteneur debranche du reseau du proxy, un DOMAIN desynchronise, un
# service supprime. Un motif qui accepte 404 declare donc « au vert » un
# service absent. C'est l'erreur qui a d'abord ete faite sur la page
# d'accueil, puis re-faite sur l'API et le CDN avec `^[24]`.
#
# Mesures du 16 aout 2026, sur cette machine :
#   hote sans routeur                  -> 404  (Traefik, text/plain)
#   api.../api/nodes/search            -> 401  (middleware Auth de Gin)
#   cdn.../<bucket>/                   -> 403  (rustfs, XML AccessDenied)
#
# On vise donc des codes que TRAEFIK NE SAIT PAS PRODUIRE : le 401 ne
# peut sortir que du routeur Go et de son middleware d'authentification,
# le 403 que de rustfs. L'ancienne cible, `/api/users/public/x`, rendait
# un 404 APPLICATIF (utilisateur introuvable) : aucun controle ne pouvait
# le distinguer du 404 de Traefik.
# / Each expected code must be one only the target service can produce:
# Traefik answers 404 when no router matches, so accepting 404 declares a
# missing service healthy.
verifier_http "site        https://$DOMAIN"       "https://$DOMAIN/" '^[23]'
verifier_http "API         https://api.$DOMAIN"   "https://api.$DOMAIN/api/nodes/search" '^401$'
verifier_http "CDN         https://cdn.$DOMAIN"   "https://cdn.$DOMAIN/${MINIO_BUCKET:-alexandrie}/" '^403$'

# LE CONTROLE QUI PROUVE LE PLUS. Les trois precedents disent que les
# services repondent ; celui-ci va CHERCHER un fichier restaure, par son
# adresse publique. Il traverse tout d'un coup : les octets sont revenus
# dans le volume, rustfs a retrouve son index, la politique de lecture
# publique du bucket tient toujours, et Traefik route le sous-domaine.
# Un seul de ces maillons casse, et il rend 403 ou 404.
# / The check that proves the most: it fetches a restored file by its
# public address, crossing every link at once.
OBJET="$(un_objet_du_bucket || true)"
if [ -n "$OBJET" ]; then
    # 200 et rien d'autre : ici, un 403 ou un 404 voudrait dire que le
    # fichier n'est pas revenu, ou qu'il n'est plus lisible.
    # / 200 and nothing else.
    verifier_http "un fichier restaure" \
        "https://cdn.$DOMAIN/${MINIO_BUCKET:-alexandrie}/$OBJET" '^2'
elif [ "$FICHIERS_APRES" = "0" ]; then
    echo "  [--]   aucun fichier televerse a eprouver (installation neuve)"
else
    # LA DISTINCTION COMPTE. `un_objet_du_bucket` avale ses erreurs : si
    # le conteneur jetable ne demarre pas, elle rend une chaine vide,
    # exactement comme une installation neuve. Le controle « celui qui
    # prouve le plus » disparaissait alors derriere un message rassurant,
    # et la repetition concluait quand meme « VRAIMENT restaurable ».
    # Un volume qui porte des fichiers et dont on n'arrive pas a nommer
    # un objet, c'est une panne, pas une installation vide.
    # / The helper swallows its errors: a container that fails to start
    # looked exactly like a fresh install, and the strongest check
    # vanished behind a reassuring line.
    ko "impossible de nommer un fichier a eprouver alors que le volume en"
    ko "porte $FICHIERS_APRES. Le controle le plus important n'a PAS eu lieu."
fi

echo
if [ "$NOMBRE_D_ERREURS" -eq 0 ]; then
    echo "[repetition] La sauvegarde est VRAIMENT restaurable : la stack a ete"
    echo "             detruite et remontee a l'identique depuis l'archive"
    echo "             $ARCHIVE_DE_REFERENCE."
    exit 0
fi
echo "[repetition] $NOMBRE_D_ERREURS probleme(s) apres restauration." >&2
echo "             La stack tourne sur les donnees restaurees. L'archive de" >&2
echo "             reference reste dans le depot : $ARCHIVE_DE_REFERENCE" >&2
exit 1
