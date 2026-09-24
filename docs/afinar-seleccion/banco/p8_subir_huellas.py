"""
Paso 8 · Sube a Storage las huellas del banco, recortadas a 256
dimensiones (medido en el banco: 89,8 % frente a 90,1 % con 512). Solo
si el almacén está vacío: no duplica nada. Sin coste de OpenAI.
"""
import json
import sys

import numpy as np

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[3]))
import huellas  # noqa: E402

from comun import DATOS, log  # noqa: E402

if huellas.leer_manifiesto()["partes"]:
    sys.exit("El almacén ya tiene huellas: no se sube nada.")
ts = json.load(open(DATOS / "titulos.json"))
emb = np.load(DATOS / "emb.npy", mmap_mode="r")
assert np.load(DATOS / "emb_hecho.npy").all()
v = np.asarray(emb[:, :huellas.DIM], np.float32)
v /= np.linalg.norm(v, axis=1, keepdims=True)
assert all(t == huellas.normal(t) for t in ts[:1000])
log(f"subiendo {len(ts)} huellas de {v.shape[1]} dimensiones")
huellas.anadir(ts, v.astype(np.float16))
man = huellas.leer_manifiesto()
log(f"hecho: {len(man['partes'])} partes, {sum(p['n'] for p in man['partes'])} huellas")
