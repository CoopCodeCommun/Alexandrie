#!/bin/bash
# =============================================================================
# bin/verifier_archive.sh — La derniere sauvegarde est-elle RESTAURABLE ?
# / bin/verifier_archive.sh — Is the last backup actually restorable?
#
# S'EXECUTE DEPUIS L'HOTE.   Lance par :  make verif-archive
# Sert aussi de garde-fou d'entree a `make backup-check` et `make update`.
#
# Verifier qu'une archive EXISTE ne dit rien. Ce script repond a la seule
# question qui compte — « est-ce restaurable ? » — SANS RIEN RESTAURER,
# sans arreter le site, et sort en code non nul des que quelque chose
# cloche : il est utilisable tel quel dans un monitoring, et dans un cron.
# / Checking that an archive exists says nothing. This answers "is it
# restorable?" without restoring, without stopping the site.
#
# IL NE DEMANDE AUCUN CONTENEUR. Le dump est du SQL en clair : tout se
# verifie sur l'hote. C'est ce qui permet de l'appeler quand la stack est
# a terre — precisement le moment ou la question se pose.
# / It needs no container: the dump is plain SQL.
#
# TROIS QUESTIONS, DANS L'ORDRE
#
#   1. Fraicheur — la derniere archive date de moins de AGE_MAX_HEURES.
#      Sinon le cron est mort, et personne ne l'avait remarque.
#   2. Contenu — le dump, le stockage S3 et le .env sont bien dedans.
#   3. Exploitabilite — et c'est la que ca se joue.
#
# POURQUOI ON CHERCHE LE MARQUEUR DE FIN DU DUMP
#
# Un dump tronque — disque plein, conteneur tue en plein dump — a une
# taille credible, se trouve bien dans l'archive, et ne restaure qu'une
# partie des tables SANS LA MOINDRE ERREUR : `mysql < dump.sql` avale un
# fichier coupe et sort en 0. Rien, dans le code de retour, ne distingue
# une base entiere d'une base amputee de sa moitie.
#
# `mysqldump` n'ecrit sa derniere ligne — « -- Dump completed on ... » —
# qu'une fois toutes les tables sorties. Sa PRESENCE est donc la preuve
# que le dump est arrive au bout ; c'est le seul controle qui demasque une
# coupure, et il est fiable parce que cette ligne ne peut pas apparaitre
# ailleurs. / mysql swallows a truncated dump and exits 0. The trailer
# line is the only proof the dump ran to completion.
#
# CE QU'IL NE TESTE PAS : ta copie de coffre-fort. Il utilise le .env de
# la machine, pas la passphrase que tu as archivee ailleurs — or c'est
# celle-la, et elle seule, qui servira le jour ou la machine aura brule.
# Verifie une fois, depuis une AUTRE machine, qu'un `borg list` passe avec
# les elements du coffre.
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"

FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"

# Les tables sans lesquelles une restauration ne rendrait pas un site.
# Un dump d'une base VIDE se restaure parfaitement — il ne rend simplement
# rien : c'est ce controle, et lui seul, qui l'attrape.
#
# `nodes` porte TOUT le contenu : les documents, les dossiers ET les
# fichiers televerses ne sont qu'un champ `role` de cette table. Les
# tables `documents` et `ressources`, qu'on trouve encore dans les
# anciennes migrations de l'amont, ont ete fusionnees dedans et
# N'EXISTENT PLUS — les chercher ferait echouer la verification sur une
# sauvegarde parfaitement saine.
# / `nodes` holds everything: documents, folders and uploaded files are
# one `role` column apart. The `documents` and `ressources` tables still
# visible in upstream's older migrations no longer exist.
TABLES_ATTENDUES="users nodes permissions user_settings"

NOMBRE_D_ERREURS=0
ok()     { echo "  [ok]   $*"; }
ko()     { echo "  [KO]   $*" >&2; NOMBRE_D_ERREURS=$((NOMBRE_D_ERREURS + 1)); }
fatal()  { echo "[verification] ERREUR : $*" >&2; exit 2; }

[ -f "$FICHIER_ENV" ] || fatal ".env introuvable : $FICHIER_ENV"

# LA SURCHARGE EST CAPTUREE AVANT LE SOURCING, sinon elle n'existe pas.
# Le `.env` porte AGE_MAX_HEURES — `make backup` l'y ecrit toujours — et
# le sourcing ci-dessous ecrase donc tout ce qui vient de la ligne de
# commande. Deplacer le defaut apres le sourcing avait corrige le faux
# rouge sur variable vide, mais laissait `AGE_MAX_HEURES=48
# make verif-archive` sans effet, alors que le commentaire promettait le
# contraire. On la met de cote ici, on la reprend apres.
# / The .env always carries AGE_MAX_HEURES, so the sourcing overrode any
# command-line value: captured here, restored after.
SURCHARGE_AGE="${AGE_MAX_HEURES:-}"

# `UID` et `GID` sont en LECTURE SEULE sous bash : les ecarter evite qu'un
# `.env` qui en porterait une tue le script sur place, sous `set -e`.
# / UID and GID are read-only in bash.
set -a
# shellcheck disable=SC1090
. <(grep -vE '^[[:space:]]*(UID|GID)=' "$FICHIER_ENV")
set +a

: "${BORG_PREFIX:?BORG_PREFIX absent du .env — sauvegarde non configuree, voir : make backup}"
: "${BORG_REPO:?BORG_REPO absent du .env — sauvegarde non configuree, voir : make backup}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"
command -v borg >/dev/null || fatal "borg introuvable dans le PATH."

# Age maximum tolere pour la derniere archive. 25 h = la sauvegarde
# quotidienne d'hier, plus une heure de marge. C'est aussi le seuil de
# l'alerte posee sur borgwarehouse par `make backup` : les deux doivent
# rester coherents.
#
# La ligne de commande gagne sur le `.env`, qui gagne sur le defaut. Et
# tout ce qui n'est pas un nombre retombe sur 25 : une variable laissee
# VIDE — ce qui arrive des qu'on la commente a moitie — donnait
# `[ 3 -le "" ]`, soit « integer expression expected » suivi d'un FAUX
# ROUGE sur une archive parfaitement fraiche.
# / Command line wins over the .env, which wins over the default; and
# anything non-numeric falls back to 25.
AGE_MAX_HEURES="${SURCHARGE_AGE:-${AGE_MAX_HEURES:-25}}"
case "$AGE_MAX_HEURES" in
    ''|*[!0-9]*) AGE_MAX_HEURES=25 ;;
esac

CLE_SSH="$REPERTOIRE_DU_SCRIPT/.ssh/${BORG_PREFIX}_ed25519"
# Chemin entre quotes simples : borg decoupe BORG_RSH comme un shell.
# / Single-quoted path: borg splits BORG_RSH shell-style.
[ -f "$CLE_SSH" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i '$CLE_SSH'"

# Meme reglage que bin/backup.sh et bin/restore.sh. Sans lui, une
# verification lancee apres un demenagement du depot attendrait une
# confirmation interactive qu'un monitoring ne donnera jamais — et la
# sauvegarde, elle, serait passee : on aurait une alerte sur une
# sauvegarde saine. / Same setting as the other two.
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

echo "[verification] depot : $BORG_REPO"
echo


#### 1. UNE ARCHIVE RECENTE EXISTE-T-ELLE ? ####
echo "1. Fraicheur"

# --glob-archives : on ne regarde QUE les archives de cette stack. Sans ce
# filtre, l'archive fraiche d'une AUTRE sauvegarde partageant le depot
# suffirait a nous rassurer.
# / Without this filter, another stack's fresh archive would reassure us.
DERNIERE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
    --format '{archive}{TAB}{time:%Y-%m-%d %H:%M:%S}{NL}' "$BORG_REPO")"
[ -n "$DERNIERE" ] || fatal "aucune archive '$BORG_PREFIX-*' dans le depot. La sauvegarde n'a jamais tourne."

ARCHIVE="${DERNIERE%%	*}"
DATE_DE_L_ARCHIVE="${DERNIERE#*	}"

AGE_EN_HEURES=$(( ( $(date +%s) - $(date -d "$DATE_DE_L_ARCHIVE" +%s) ) / 3600 ))
if [ "$AGE_EN_HEURES" -le "$AGE_MAX_HEURES" ]; then
    ok "derniere archive : $ARCHIVE (il y a ${AGE_EN_HEURES} h)"
else
    # UN SEUL `ko` POUR UN SEUL PROBLEME : le compteur sert de code de
    # sortie et de bilan, et deux appels faisaient annoncer « 2 probleme(s) »
    # pour une unique archive perimee.
    # / One `ko` per problem: the counter is the exit code.
    ko "derniere archive : $ARCHIVE — ${AGE_EN_HEURES} h, soit plus de ${AGE_MAX_HEURES} h. Le cron ne tourne plus (crontab -l)."
fi


#### 2. L'ARCHIVE CONTIENT-ELLE CE QU'IL FAUT ? ####
echo
echo "2. Contenu de l'archive"

CONTENU="$(borg list --format '{path}{NL}' "$BORG_REPO::$ARCHIVE")"

CHEMIN_DU_DUMP="$(grep -E '/alexandrie\.sql$' <<< "$CONTENU" | head -n1 || true)"
if [ -n "$CHEMIN_DU_DUMP" ]; then
    ok "dump MySQL present"
else
    ko "aucun dump MySQL dans l'archive."
fi

# Les fichiers televerses sont hors git et hors base : irremplacables.
# / The uploaded files are outside git and outside the database.
CHEMIN_DU_TAR="$(grep -E '/rustfs\.tar$' <<< "$CONTENU" | head -n1 || true)"
if [ -n "$CHEMIN_DU_TAR" ]; then
    ok "stockage S3 present"
else
    ko "le stockage S3 est absent : images, PDF et pieces jointes ne seraient pas restaures."
fi

if grep -qE '/\.env$' <<< "$CONTENU"; then
    ok ".env present (la stack est remontable telle quelle)"
else
    ko ".env absent : une restauration demanderait de resaisir toutes les cles."
fi


#### 3. LE DUMP EST-IL EXPLOITABLE, ET COMPLET ? ####
echo
echo "3. Le dump est-il restaurable ?"

if [ -z "$CHEMIN_DU_DUMP" ]; then
    ko "pas de dump a verifier."
else
    # Le dump est tire UNE fois dans un fichier temporaire, puis eprouve
    # deux fois. Le retirer du depot a chaque passe doublerait le
    # transfert reseau pour rien.
    # / Pulled once, tested twice.
    DUMP_TEMPORAIRE="$(mktemp)"
    trap 'rm -f "$DUMP_TEMPORAIRE"' EXIT
    borg extract --stdout "$BORG_REPO::$ARCHIVE" "$CHEMIN_DU_DUMP" > "$DUMP_TEMPORAIRE"

    # a) le schema attendu est-il la ? Un dump d'une base VIDE se restaure
    #    parfaitement — il ne rend simplement rien.
    TABLES_MANQUANTES=""
    for table in $TABLES_ATTENDUES; do
        grep -qE "^CREATE TABLE (IF NOT EXISTS )?\`?${table}\`? " "$DUMP_TEMPORAIRE" \
            || TABLES_MANQUANTES="$TABLES_MANQUANTES $table"
    done
    if [ -z "$TABLES_MANQUANTES" ]; then
        ok "schema Alexandrie retrouve (comptes, contenus, permissions, reglages)"
    else
        ko "tables absentes du dump :$TABLES_MANQUANTES"
    fi

    # LE SCHEMA NE DIT RIEN DES DONNEES. Le controle ci-dessus cherche des
    # `CREATE TABLE` : une base migree mais VIDE les porte toutes, et
    # passait donc au vert — alors que le commentaire d'en-tete de ce
    # script promet le contraire. C'est le scenario d'une stack remontee
    # sur un volume neuf que le cron sauvegarde consciencieusement chaque
    # nuit pendant que les vraies archives sortent de la retention.
    #
    # `mysqldump` n'emet une ligne `INSERT INTO` que s'il y a au moins une
    # ligne a ecrire : sa presence est la preuve qu'il y a des comptes.
    # / The schema says nothing about the data: a migrated but EMPTY
    # database carries every CREATE TABLE and passed green.
    if grep -q '^INSERT INTO `users`' "$DUMP_TEMPORAIRE"; then
        ok "la base contient des comptes"
    else
        ko "aucun compte dans le dump : la base sauvegardee est VIDE."
        ko "stack remontee sur un volume neuf ? mauvaise base ?"
    fi

    # b) le dump va-t-il jusqu'au bout ? C'est LA question. On ne lit que
    #    la fin du fichier : le marqueur y est, ou il n'y est pas.
    #    / Only the tail is read: the trailer is there, or it is not.
    if tail -c 200 "$DUMP_TEMPORAIRE" | grep -q -- '-- Dump completed'; then
        ok "dump complet (marqueur de fin de mysqldump present)"
    else
        ko "dump TRONQUE : mysqldump n'a pas ecrit son marqueur de fin."
        ko "cette sauvegarde n'est PAS restaurable en entier, et la commande"
        ko "mysql la chargerait sans une seule erreur."
    fi
fi


#### 4. LE STOCKAGE S3 EST-IL EXPLOITABLE ? ####
echo
echo "4. Le stockage S3 est-il exploitable ?"

if [ -z "$CHEMIN_DU_TAR" ]; then
    ko "pas de stockage a verifier."
else
    # Deroule sans jamais toucher le disque : borg envoie le tar dans un
    # tuyau, tar le lit d'un bout a l'autre. Une coupure se voit ici.
    # C'est le pendant du marqueur de fin du dump.
    # / Unrolled through a pipe, never touching the disk.
    if NOMBRE_D_OBJETS="$(borg extract --stdout "$BORG_REPO::$ARCHIVE" "$CHEMIN_DU_TAR" | tar -tf - | wc -l)"; then
        ok "stockage S3 deroule entierement ($NOMBRE_D_OBJETS entrees)"
    else
        ko "stockage S3 TRONQUE : tar n'arrive pas au bout du fichier."
    fi
fi


#### VERDICT ####
echo
if [ "$NOMBRE_D_ERREURS" -eq 0 ]; then
    echo "[verification] La derniere sauvegarde est restaurable : $ARCHIVE"
    exit 0
fi
echo "[verification] $NOMBRE_D_ERREURS probleme(s). Cette sauvegarde n'est pas fiable." >&2
exit 1
