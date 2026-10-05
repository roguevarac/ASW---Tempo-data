"""
Cuenta cuantas veces se EXPANDE cada CTE en el SELECT final, asumiendo que Redshift
inlinea las CTE (las recalcula en cada referencia). Sirve para ver cuantas veces se leen
las fuentes pesadas en una sola sentencia.

Uso: python3 reporte_cwr/tools/contar_expansiones.py <archivo.sql>
"""
import sys, re, collections, functools
import sqlglot
from sqlglot import exp

FUENTES = ["dp_song_metadata.song_v", "dp_song_metadata.identifiers_iswc_v",
           "dp_song_metadata.song_share_detail_mv", "dp_song_metadata.contract_territories",
           "dp_deal_metadata.contract_v"]

def analizar(sql):
    stmts = [s for s in sqlglot.parse(sql, read="redshift") if s is not None]
    sel = stmts[-1]
    with_ = sel.args.get("with_") or sel.args.get("with")
    ctes = {c.alias: c.this for c in with_.expressions} if with_ else {}
    def refs(node):
        out = collections.Counter()
        for t in node.find_all(exp.Table):
            name = t.name if not t.db else f"{t.db}.{t.name}"
            if not t.db and name in ctes:
                out[name] += 1
            elif t.db:
                out[name] += 1
        return out
    body = sel.copy(); body.set("with_", None); body.set("with", None)
    @functools.lru_cache(None)
    def expand(name):
        tot = collections.Counter()
        for r, n in refs(ctes[name]).items():
            if r in ctes:
                for k, v in expand(r).items(): tot[k] += v * n
            else:
                tot[r] += n
        return tot
    total = collections.Counter()
    for r, n in refs(body).items():
        if r in ctes:
            for k, v in expand(r).items(): total[k] += v * n
        else:
            total[r] += n
    return total

if __name__ == "__main__":
    t = analizar(open(sys.argv[1], encoding="utf-8").read())
    for f in FUENTES:
        print(f"{t.get(f,0):6d}  {f}")
