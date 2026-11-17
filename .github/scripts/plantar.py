"""Planta um trecho num template de uma COPIA do chart, para as iscas do CI.

O values nao deixa montar um Secret por volume nem declarar initContainer, entao
as iscas desses caminhos editam uma copia do chart. Uso:

    python3 plantar.py <template> volume <trecho>        # depois dos volumes do pod
    python3 plantar.py <template> initContainer <trecho> # antes de `containers:`

O trecho usa `|` no lugar da quebra de linha. Falha se a ancora nao aparecer
exatamente uma vez: uma isca que nao planta nada passaria por engano.
"""
import sys

ANCORAS = {
    "volume": ("      volumes:\n        - name: tmp\n          emptyDir: {}\n", "depois"),
    "initContainer": ("      containers:\n", "antes"),
}

caminho, tipo, trecho = sys.argv[1], sys.argv[2], sys.argv[3].replace("|", "\n") + "\n"
ancora, lado = ANCORAS[tipo]
texto = open(caminho).read()
if texto.count(ancora) != 1:
    raise SystemExit(f"FALHA: a isca nao achou a ancora '{tipo}' em {caminho}")
novo = ancora + trecho if lado == "depois" else trecho + ancora
open(caminho, "w").write(texto.replace(ancora, novo))
