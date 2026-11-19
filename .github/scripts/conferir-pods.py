"""Confere, no YAML renderizado pelo chart, as cinco politicas do Kyverno que o
cluster aplica em modo Enforce a TODO pod.

Quatro delas olham o POD, e nao o Deployment ou o Job: um `kubectl apply`
sai verde e o pod e recusado ao nascer, com o motivo escondido nos eventos do
ReplicaSet. Este script le cada modelo de pod do render (Rollout, Deployment,
StatefulSet, DaemonSet, Job, CronJob) e o Cluster do CloudNativePG, e falha
com o objeto e a politica de cada achado.

O que ele NAO ve: o que o Istio injeta (o sidecar e o istio-validation, que
trazem recursos proprios) e os pods que o operador do CloudNativePG cria a
partir do Cluster, alem da imagem e dos recursos declarados nele.

uso: python3 conferir-pods.py <render.yaml> [<render.yaml> ...]
Saida 0: nenhum achado. Saida 1: achados, um por linha, em stderr.
"""
import fnmatch
import os
import sys

import yaml

# Os registros que os pods DESTE chart usam: a imagem do app e a do banco
# efemero do CloudNativePG. A lista inteira da politica `registro-permitido`
# fica no repositorio do cluster; quem quiser a mesma conferencia passa
# REGISTROS_PERMITIDOS (padroes separados por espaco). O `*` do Kyverno casa
# qualquer sequencia, como o do fnmatch.
REGISTROS = os.environ.get(
    "REGISTROS_PERMITIDOS", "ghcr.io/slipalison/* ghcr.io/cloudnative-pg/*"
).split()
COM_ROTULO = {"Deployment", "StatefulSet", "DaemonSet", "Rollout"}


def modelo_de_pod(doc):
    tipo = doc.get("kind")
    spec = doc.get("spec") or {}
    if tipo in ("Deployment", "StatefulSet", "DaemonSet", "Rollout", "Job"):
        return spec.get("template")
    if tipo == "CronJob":
        return ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template")
    return None


def tag_fixa(imagem):
    """None quando a imagem tem tag fixa ou digest; senao, o motivo."""
    if "@sha256:" in imagem:
        return None
    ultimo = imagem.rsplit("/", 1)[-1]
    if ":" not in ultimo:
        return "sem tag, que e :latest implicito"
    if ultimo.rsplit(":", 1)[1] == "latest":
        return ":latest"
    return None


def confere_container(onde, c, achados):
    nome = f"{onde} container {c.get('name')}"
    rec = c.get("resources") or {}
    req = rec.get("requests") or {}
    lim = rec.get("limits") or {}
    faltam = [k for k, v in (("requests.cpu", req.get("cpu")), ("requests.memory", req.get("memory")),
                             ("limits.memory", lim.get("memory"))) if not v]
    if faltam:
        achados.append(f"{nome}: exige-requests-e-limits: falta {', '.join(faltam)}")
    imagem = str(c.get("image") or "")
    motivo = tag_fixa(imagem)
    if motivo:
        achados.append(f"{nome}: proibe-tag-latest: '{imagem}' {motivo}")
    if not any(fnmatch.fnmatchcase(imagem, p) for p in REGISTROS):
        achados.append(f"{nome}: registro-permitido: '{imagem}' fora dos registros permitidos")


def confere(docs):
    achados = []
    vistos = 0
    for doc in docs:
        tipo = doc.get("kind")
        meta = doc.get("metadata") or {}
        onde = f"{tipo}/{meta.get('name')}"
        if tipo == "Cluster" and str(doc.get("apiVersion", "")).startswith("postgresql.cnpg.io/"):
            vistos += 1
            spec = doc.get("spec") or {}
            confere_container(onde, {"name": "postgres", "image": spec.get("imageName", ""),
                                     "resources": spec.get("resources")}, achados)
            rot = ((spec.get("inheritedMetadata") or {}).get("labels") or {})
            if not (rot.get("app.kubernetes.io/name") and rot.get("owner")):
                achados.append(f"{onde}: exige-rotulos: inheritedMetadata sem app.kubernetes.io/name e owner")
            continue
        pod = modelo_de_pod(doc)
        if pod is None:
            continue
        vistos += 1
        spec = pod.get("spec") or {}
        if tipo in COM_ROTULO:
            rot = meta.get("labels") or {}
            if not (rot.get("app.kubernetes.io/name") and rot.get("owner")):
                achados.append(f"{onde}: exige-rotulos: faltam app.kubernetes.io/name e owner")
        containers = spec.get("containers") or []
        if not containers:
            achados.append(f"{onde}: modelo de pod sem container")
        for c in containers + (spec.get("initContainers") or []):
            confere_container(onde, c, achados)
        nao_root_pod = (spec.get("securityContext") or {}).get("runAsNonRoot") is True
        nao_root_todos = bool(containers) and all(
            (c.get("securityContext") or {}).get("runAsNonRoot") is True for c in containers)
        if not (nao_root_pod or nao_root_todos):
            achados.append(f"{onde}: exige-nao-root: securityContext.runAsNonRoot: true ausente")
    return vistos, achados


def main(arquivos):
    if not arquivos:
        sys.exit("uso: conferir-pods.py <render.yaml> [...]")
    total = 0
    todos = []
    for arq in arquivos:
        with open(arq, encoding="utf-8") as f:
            docs = [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]
        vistos, achados = confere(docs)
        total += vistos
        todos += [f"{arq}: {a}" for a in achados]
    if total == 0:
        # Um render sem pod nenhum nao prova nada: e o defeito do conferidor
        # que nao mediu, e nao um render limpo.
        print("nenhum modelo de pod lido: esta conferencia nao mediu nada", file=sys.stderr)
        sys.exit(1)
    for a in todos:
        print(a, file=sys.stderr)
    if todos:
        sys.exit(1)
    print(f"politicas do Kyverno: {total} modelo(s) de pod sem achado")


if __name__ == "__main__":
    main(sys.argv[1:])
