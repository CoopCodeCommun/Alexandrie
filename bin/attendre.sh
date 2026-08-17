#!/bin/bash
# =============================================================================
# bin/attendre.sh — Attend que la stack soit vraiment prete
# / bin/attendre.sh — Waits until the stack is actually ready
#
# S'EXECUTE DEPUIS L'HOTE. Appele par `make install`, par bin/update.sh et
# par bin/check_backup.sh : les trois enchainent sur des controles qui
# n'ont aucun sens tant que la base ou le backend ne repondent pas.
#
# POURQUOI IL EXISTE PLUTOT QU'UN `sleep 30`
#
# `docker compose up -d` rend la main des que les conteneurs sont CREES,
# pas quand ils servent. Un `sleep` genereux marche jusqu'au jour ou la
# machine est chargee, ou l'image vient d'etre retiree, ou MySQL rejoue un
# journal — et la verification qui suit echoue sur une stack parfaitement
# saine, simplement pas encore prete. On attend donc un ETAT, pas une
# duree. / compose returns as soon as the containers are created, not when
# they serve. We wait for a state, not for a duration.
#
# CE QU'IL ATTEND, ET DANS QUEL ORDRE
#
#   1. mysql et rustfs `healthy`   (ils ont un healthcheck)
#   2. backend et frontend `running` (ils n'en ont pas : les images de
#      l'amont n'en declarent aucun)
#   3. le backend repond sur son port
#
# Le point 3 est le seul qui prouve quelque chose d'utile : un backend
# `running` peut etre en train de boucler sur une migration echouee. Tant
# qu'il n'a pas repondu une fois, la stack n'est pas prete.
# / A `running` backend may be looping on a failed migration.
#
# USAGE
#   bash bin/attendre.sh [duree_max_en_secondes]     (defaut : 180)
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"
FICHIER_COMPOSE="$REPERTOIRE_DU_PROJET/docker-compose.yml"

DUREE_MAX="${1:-180}"

etat_de() {  # etat_de <conteneur> -> "healthy" | "running" | "absent" | ...
    # `.State.Health` n'existe que si l'image declare un healthcheck : sur
    # backend et frontend, on retombe donc sur `.State.Status`.
    # / .State.Health only exists when the image declares a healthcheck.
    docker inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$1" 2>/dev/null || echo "absent"
}

echo "[attente] demarrage des services (au plus ${DUREE_MAX} s)..."

DEBUT=$(date +%s)
while :; do
    ETAT_MYSQL="$(etat_de alexandrie_mysql)"
    ETAT_RUSTFS="$(etat_de alexandrie_rustfs)"
    ETAT_BACKEND="$(etat_de alexandrie_backend)"
    ETAT_FRONTEND="$(etat_de alexandrie_frontend)"

    if [ "$ETAT_MYSQL" = "healthy" ] && [ "$ETAT_RUSTFS" = "healthy" ] \
       && [ "$ETAT_BACKEND" = "running" ] && [ "$ETAT_FRONTEND" = "running" ]; then
        # Le backend repond-il pour de vrai ? On interroge son port DEPUIS
        # le reseau interne, sans passer par le proxy : ce controle doit
        # dire si l'APPLICATION est prete, pas si Traefik est bien regle.
        # / Asked from inside the network, so this says whether the
        # application is ready, not whether the proxy is configured.
        if docker run --rm --network container:alexandrie_backend alpine:3.20 \
                nc -z localhost 8201 >/dev/null 2>&1; then
            echo "[attente] la stack repond."
            exit 0
        fi
    fi

    ECOULE=$(( $(date +%s) - DEBUT ))
    if [ "$ECOULE" -ge "$DUREE_MAX" ]; then
        echo >&2
        echo "[attente] ABANDON apres ${ECOULE} s. Etat des services :" >&2
        echo "            mysql    : $ETAT_MYSQL" >&2
        echo "            rustfs   : $ETAT_RUSTFS" >&2
        echo "            backend  : $ETAT_BACKEND" >&2
        echo "            frontend : $ETAT_FRONTEND" >&2
        echo >&2
        echo "[attente] Les journaux diront pourquoi :" >&2
        echo "            docker compose -f $FICHIER_COMPOSE logs --tail 50" >&2
        exit 1
    fi
    sleep 3
done
