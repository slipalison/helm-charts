#!/usr/bin/env bash
# Prova o conferidor das politicas do Kyverno (conferir-pods.py) nas duas
# direcoes, antes de confiar nele:
#
#   1. o render do chart com worker e Job de migracao, em producao e no
#      preview, passa limpo;
#   2. cada isca — o mesmo render com UM defeito plantado — e reprovada, e pelo
#      motivo certo (a politica aparece na mensagem), inclusive as duas do
#      Cluster do banco efemero, sobre o render do preview;
#   3. os valores que produziriam esses defeitos ja sao recusados pelo proprio
#      chart, no render, antes de chegar ao cluster.
#
# Roda da raiz do repositorio. Saida 0: tudo mordeu. Qualquer outra: o passo
# que falhou, em stderr.
set -euo pipefail
if [ -n "${RUNNER_TEMP:-}" ]; then
  T="$RUNNER_TEMP/conferir-pods"
else
  raiz="$(mktemp -d)"; trap 'rm -rf "$raiz"' EXIT
  T="$raiz/conferir-pods"
fi
rm -rf "$T"; mkdir -p "$T"
conferir=.github/scripts/conferir-pods.py

base=(--set name=exemplo --set owner=equipe
      --set image.repository=ghcr.io/slipalison/exemplo
      --set image.tag=sha-abc1234 --set versao=1.2.3
      --set database.enabled=true --set probes.port=9090
      --set 'workers.fila.args[0]=worker'
      --set migration.enabled=true --set 'migration.args[0]=migrate'
      --set migration.database.secret=exemplo-dono-db)
helm template exemplo charts/app "${base[@]}" > "$T/prod.yaml"
helm template pr-42-exemplo charts/app "${base[@]}" \
  --set preview.numero=42 --set preview.tag=pr-42-abcdef0 > "$T/preview.yaml"

# 1. O limpo passa.
python3 "$conferir" "$T/prod.yaml" "$T/preview.yaml"

# 2. Cada isca reprova, pela politica certa.
# isca <nome> <trecho esperado da mensagem> <mutacao em Python> [prod|preview]
isca() {
  local nome=$1 esperado=$2 mutacao=$3 origem=${4:-prod}
  python3 - "$T/$origem.yaml" "$T/isca-$nome.yaml" "$mutacao" <<'FIMPY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
def um(tipo):
    return next(d for d in docs if d["kind"] == tipo)
def c(tipo):
    return um(tipo)["spec"]["template"]["spec"]["containers"][0]
exec(sys.argv[3])
yaml.safe_dump_all(docs, open(sys.argv[2], "w"))
FIMPY
  local saida
  if saida=$(python3 "$conferir" "$T/isca-$nome.yaml" 2>&1); then
    echo "isca '$nome' passou pelo conferidor" >&2; exit 1
  fi
  grep -qF -- "$esperado" <<<"$saida" || { echo "isca '$nome' reprovou por outro motivo: $saida" >&2; exit 1; }
  echo "isca $nome: reprovada ($esperado)"
}
isca worker-sem-resources   "exige-requests-e-limits" 'del c("Deployment")["resources"]'
isca job-sem-limite         "falta limits.memory"     'del c("Job")["resources"]["limits"]'
isca init-sem-resources     "container init"          'um("Job")["spec"]["template"]["spec"]["initContainers"] = [{"name": "init", "image": "ghcr.io/slipalison/x:1.0.0"}]'
isca job-latest             "proibe-tag-latest"       'c("Job")["image"] = "ghcr.io/slipalison/exemplo:latest"'
isca worker-sem-tag         "sem tag"                 'c("Deployment")["image"] = "ghcr.io/slipalison/exemplo"'
isca job-root               "exige-nao-root"          'del um("Job")["spec"]["template"]["spec"]["securityContext"]["runAsNonRoot"]'
isca worker-sem-owner       "exige-rotulos"           'del um("Deployment")["metadata"]["labels"]["owner"]'
isca rollout-outro-registro "registro-permitido"      'c("Rollout")["image"] = "docker.io/library/nginx:1.27.0"'
isca sem-pod                "nao mediu nada"          'docs[:] = [d for d in docs if d["kind"] == "Namespace"]'
# O Cluster do banco efemero so existe no preview: as duas iscas dele partem dali.
isca cluster-sem-owner      "Cluster/banco: exige-rotulos: inheritedMetadata" 'del um("Cluster")["spec"]["inheritedMetadata"]["labels"]["owner"]' preview
isca cluster-sem-limite     "Cluster/banco container postgres: exige-requests-e-limits: falta limits.memory" 'del um("Cluster")["spec"]["resources"]["limits"]' preview

# Digest conta como fixo: nao pode ser isca.
python3 - "$T/prod.yaml" "$T/digest.yaml" <<'FIMPY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
next(d for d in docs if d["kind"] == "Job")["spec"]["template"]["spec"]["containers"][0]["image"] = "ghcr.io/slipalison/exemplo@sha256:" + "0" * 64
yaml.safe_dump_all(docs, open(sys.argv[2], "w"))
FIMPY
python3 "$conferir" "$T/digest.yaml" >/dev/null

# 3. Os valores que plantariam os defeitos sao recusados no render.
recusa() {
  local m=$1; shift; local e
  if e=$(helm template x charts/app "${base[@]}" "$@" 2>&1 >/dev/null); then echo "o chart aceitou: $*" >&2; exit 1; fi
  grep -qF -- "$m" <<<"$e" || { echo "o chart recusou por outro motivo: $e" >&2; exit 1; }
  echo "valores recusados: $*"
}
recusa "workers.fila.resources" --set-json 'workers.fila.resources={"requests":{"cpu":"10m"}}'
recusa "migration.resources"    --set-json 'migration.resources={"limits":{"memory":"64Mi"}}'
recusa "at '/image/tag'"          --set image.tag=latest
echo "conferir-pods: limpo passa, $(ls "$T"/isca-*.yaml | wc -l) iscas reprovadas, 3 valores recusados"
