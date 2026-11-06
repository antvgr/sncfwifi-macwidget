#!/usr/bin/env bash
# protect_main.sh — Protège `main` : un merge n'est possible que si les builds Apple Silicon et
# Intel (workflow ci.yml) sont verts. À lancer une fois, APRÈS le premier passage de ci.yml
# (GitHub ne connaît le nom d'un check qu'une fois qu'il s'est exécuté).
#
#   GITHUB_TOKEN=<PAT avec droit « Administration » sur le dépôt> ./scripts/protect_main.sh
set -euo pipefail

REPO="${REPO:-antvgr/sncfwifi-macwidget}"
: "${GITHUB_TOKEN:?Exporter GITHUB_TOKEN (PAT avec droit Administration sur le dépôt)}"

curl -fsS -X PUT \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/branches/main/protection" \
  -d '{
    "required_status_checks": {
      "strict": true,
      "contexts": ["Build (Apple Silicon)", "Build (Intel)"]
    },
    "enforce_admins": true,
    "required_pull_request_reviews": { "required_approving_review_count": 0 },
    "restrictions": null,
    "allow_force_pushes": false,
    "allow_deletions": false
  }' >/dev/null

echo "✅ main protégée sur ${REPO} : PR obligatoire, builds Apple Silicon + Intel requis."
