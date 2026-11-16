"""
Entrena un MLP chico sobre el dataset de gestos y genera GestureModel.swift.

Uso:
    python tools/train_gestures.py tools/dataset.csv MiXR/Capture/GestureModel.swift

Salida: un archivo Swift con los pesos ya normalizados, para que la app haga la
inferencia con una multiplicación de matrices (sin CoreML ni dependencias).
"""
import sys
import numpy as np

LABELS = ["reposo", "pinza", "puno", "indice", "palma"]


CURL_PAIRS = [
    ("thumbTip", "thumbCMC"),
    ("indexTip", "indexMCP"),
    ("middleTip", "middleMCP"),
    ("ringTip", "ringMCP"),
    ("littleTip", "littleMCP"),
]

JOINT_ORDER = [
    "wrist",
    "thumbCMC", "thumbMP", "thumbIP", "thumbTip",
    "indexMCP", "indexPIP", "indexDIP", "indexTip",
    "middleMCP", "middlePIP", "middleDIP", "middleTip",
    "ringMCP", "ringPIP", "ringDIP", "ringTip",
    "littleMCP", "littlePIP", "littleDIP", "littleTip",
]
JOINT_INDEX = {name: i for i, name in enumerate(JOINT_ORDER)}


def derive_features(coords):
    """Reconstruye el vector completo desde los 42 números de coordenadas.

    Así Python y Swift calculan exactamente lo mismo: la app también deriva
    curvatura y distancias a partir de los 21 puntos normalizados.
    """
    rows = []
    for row in coords:
        pts = {name: (row[i * 2], row[i * 2 + 1]) for name, i in JOINT_INDEX.items()}

        def norm(name):
            x, y = pts[name]
            return np.hypot(x, y)

        curls = [norm(tip) / max(norm(mcp), 1e-3) for tip, mcp in CURL_PAIRS]
        dists = []
        for a, b in [("thumbTip", "indexTip"), ("indexTip", "indexMCP"),
                     ("middleTip", "middleMCP"), ("ringTip", "ringMCP"),
                     ("littleTip", "littleMCP"), ("thumbTip", "littleMCP")]:
            ax, ay = pts[a]
            bx, by = pts[b]
            dists.append(np.hypot(ax - bx, ay - by))

        rows.append(list(row) + curls + dists)
    return np.array(rows, dtype=np.float64)


def load(path):
    rows = open(path, encoding="utf-8").read().strip().split("\n")
    X, y = [], []
    for r in rows[1:]:
        r = r.strip()
        if not r:
            continue
        parts = r.split(",")
        y.append(int(parts[0]))
        # sólo los 42 números de coordenadas: el resto se recalcula
        X.append([float(v) for v in parts[1:43]])
    coords = np.array(X, dtype=np.float64)
    return derive_features(coords), np.array(y, dtype=np.int64)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "tools/dataset.csv"
    dst = sys.argv[2] if len(sys.argv) > 2 else "MiXR/Capture/GestureModel.swift"

    X, y = load(src)
    n, f = X.shape
    k = len(LABELS)
    print(f"dataset: {n} filas, {f} features, {k} clases")

    # --- normalización ---
    mean = X.mean(axis=0)
    std = X.std(axis=0)
    std[std < 1e-6] = 1e-6
    Xn = (X - mean) / std

    # --- split honesto ---
    # Un split al azar mezcla frames consecutivos de la misma grabación entre train y
    # validación, y da una precisión falsamente alta. Acá se toma el 20% FINAL de la
    # grabación de cada gesto como validación: es el escenario real de uso.
    rng = np.random.default_rng(7)
    tr_idx, va_idx = [], []
    for cls in range(k):
        cls_idx = np.where(y == cls)[0]
        cut = int(len(cls_idx) * 0.8)
        tr_idx.extend(cls_idx[:cut])
        va_idx.extend(cls_idx[cut:])

    tr = np.array(tr_idx)
    va = np.array(va_idx)

    Xtr, ytr = Xn[tr], y[tr]
    Xva, yva = Xn[va], y[va]

    # --- MLP  f -> h -> k  (ReLU + softmax) ---
    h = 32
    W1 = rng.normal(0, np.sqrt(2.0 / f), size=(f, h))
    b1 = np.zeros(h)
    W2 = rng.normal(0, np.sqrt(2.0 / h), size=(h, k))
    b2 = np.zeros(k)

    params = [W1, b1, W2, b2]
    m = [np.zeros_like(p) for p in params]
    v = [np.zeros_like(p) for p in params]
    lr, beta1, beta2, eps = 0.01, 0.9, 0.999, 1e-8
    l2 = 1e-4
    epochs, batch = 600, 64
    step = 0

    Y = np.eye(k)[ytr]

    for ep in range(epochs):
        perm = rng.permutation(len(Xtr))
        for s in range(0, len(Xtr), batch):
            b = perm[s:s + batch]
            xb, yb_onehot = Xtr[b], Y[b]

            z1 = xb @ W1 + b1
            a1 = np.maximum(z1, 0)
            z2 = a1 @ W2 + b2

            z2 -= z2.max(axis=1, keepdims=True)
            p = np.exp(z2)
            p /= p.sum(axis=1, keepdims=True)
            dz2 = (p - yb_onehot) / len(b)
            dW2 = a1.T @ dz2 + l2 * W2
            db2 = dz2.sum(axis=0)

            da1 = dz2 @ W2.T
            dz1 = da1 * (z1 > 0)
            dW1 = xb.T @ dz1 + l2 * W1
            db1 = dz1.sum(axis=0)

            grads = [dW1, db1, dW2, db2]
            step += 1
            for i, g in enumerate(grads):
                m[i] = beta1 * m[i] + (1 - beta1) * g
                v[i] = beta2 * v[i] + (1 - beta2) * (g * g)
                mh = m[i] / (1 - beta1 ** step)
                vh = v[i] / (1 - beta2 ** step)
                params[i] -= lr * mh / (np.sqrt(vh) + eps)

        if ep % 100 == 0 or ep == epochs - 1:
            acc = accuracy(Xva, yva, params)
            print(f"  epoch {ep:4d}  val acc {acc*100:.1f}%")

    acc = accuracy(Xva, yva, params)
    print(f"\nprecision validacion: {acc*100:.2f}%")

    # matriz de confusion
    pred = predict(Xva, params)
    cm = np.zeros((k, k), dtype=int)
    for t, pr in zip(yva, pred):
        cm[t, pr] += 1
    print("\nmatriz de confusion (fila=real, col=predicho):")
    print("            " + "".join(f"{LABELS[j][:6]:>8}" for j in range(k)))
    for i in range(k):
        print(f"{LABELS[i]:>10}  " + "".join(f"{cm[i, j]:>8d}" for j in range(k)))

    # precision por clase
    print()
    for i in range(k):
        total = cm[i].sum()
        ok = cm[i, i]
        print(f"  {LABELS[i]:8s} {ok}/{total}  {100.0*ok/max(total,1):.1f}%")

    write_swift(dst, params, mean, std, acc)
    print(f"\nescrito {dst}")


def forward(X, params):
    W1, b1, W2, b2 = params
    a1 = np.maximum(X @ W1 + b1, 0)
    z2 = a1 @ W2 + b2
    z2 -= z2.max(axis=1, keepdims=True)
    p = np.exp(z2)
    p /= p.sum(axis=1, keepdims=True)
    return p


def predict(X, params):
    return forward(X, params).argmax(axis=1)


def accuracy(X, y, params):
    return float((predict(X, params) == y).mean())


def swift_array(values, per_line=8, indent="        "):
    flat = [f"{v:.7g}" for v in np.ravel(values)]
    lines = []
    for i in range(0, len(flat), per_line):
        lines.append(indent + ", ".join(flat[i:i + per_line]) + ",")
    return "\n".join(lines)


def write_swift(path, params, mean, std, acc):
    W1, b1, W2, b2 = params
    f, h = W1.shape
    k = W2.shape[1]

    labels_swift = "[" + ", ".join('"%s"' % name for name in LABELS) + "]"

    parts = []
    parts.append("import Foundation\n\n")
    parts.append("/// Clasificador de gestos entrenado con `tools/train_gestures.py`.\n")
    parts.append("///\n")
    parts.append("/// MLP %d -> %d -> %d (ReLU + softmax). Los pesos ya vienen normalizados:\n" % (f, h, k))
    parts.append("/// la app resta la media y divide por el desvio antes de la multiplicacion.\n")
    parts.append("/// Precision en validacion: %.2f%%\n" % (acc * 100))
    parts.append("///\n")
    parts.append("/// GENERADO AUTOMATICAMENTE - no editar a mano.\n")
    parts.append("enum GestureModel {\n\n")
    parts.append("    static let labels: [String] = %s\n\n" % labels_swift)
    parts.append("    static let featureCount = %d\n" % f)
    parts.append("    static let hiddenCount = %d\n" % h)
    parts.append("    static let classCount = %d\n\n" % k)
    parts.append("    /// Orden canonico de las clases.\n")
    parts.append("    static let gestureNames: [GestureLabel] = [.rest, .pinch, .fist, .point, .openPalm]\n\n")
    parts.append("    static let mean: [Float] = [\n%s\n    ]\n\n" % swift_array(mean))
    parts.append("    static let std: [Float] = [\n%s\n    ]\n\n" % swift_array(std))
    parts.append("    /// (featureCount x hiddenCount), fila mayor.\n")
    parts.append("    static let w1: [Float] = [\n%s\n    ]\n\n" % swift_array(W1))
    parts.append("    static let b1: [Float] = [\n%s\n    ]\n\n" % swift_array(b1))
    parts.append("    /// (hiddenCount x classCount), fila mayor.\n")
    parts.append("    static let w2: [Float] = [\n%s\n    ]\n\n" % swift_array(W2))
    parts.append("    static let b2: [Float] = [\n%s\n    ]\n}\n" % swift_array(b2))

    open(path, "w", encoding="utf-8", newline="\n").write("".join(parts))


if __name__ == "__main__":
    main()
