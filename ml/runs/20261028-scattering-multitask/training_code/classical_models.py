"""Small local tree/kernel models using NumPy only; no downloads or network calls."""
import copy
import numpy as np


def clone(model):
    return copy.deepcopy(model)


def accuracy_score(y, pred):
    return np.mean(np.asarray(y) == np.asarray(pred))


def balanced_accuracy_score(y, pred):
    y, pred = np.asarray(y), np.asarray(pred)
    return np.mean([np.mean(pred[y == c] == c) for c in np.unique(y)])


def confusion_matrix(y, pred, labels=(0, 1)):
    y, pred = np.asarray(y), np.asarray(pred)
    return np.array([[np.sum((y == a) & (pred == b)) for b in labels] for a in labels])


def mean_absolute_error(y, pred):
    return np.mean(np.abs(np.asarray(y) - np.asarray(pred)))


class Standardized:
    def __init__(self, model):
        self.model = model

    def fit(self, x, y):
        self.mean = x.mean(0)
        self.std = x.std(0) + 1e-6
        self.model.fit((x - self.mean) / self.std, y)
        return self

    def predict(self, x):
        return self.model.predict((x - self.mean) / self.std)


class KernelRidge:
    def __init__(self, alpha=1, gamma=1, classifier=False, linear=False):
        self.alpha, self.gamma, self.classifier, self.linear = alpha, gamma, classifier, linear

    def kernel(self, x, z):
        if self.linear:
            return x @ z.T / x.shape[1]
        dist = np.maximum(np.sum(x*x, axis=1)[:, None] + np.sum(z*z, axis=1)[None, :] - 2*x@z.T, 0)
        return np.exp(-self.gamma * dist / x.shape[1])

    def fit(self, x, y):
        self.x = np.asarray(x, dtype=float).copy()
        target = 2 * np.asarray(y, dtype=float) - 1 if self.classifier else np.asarray(y, dtype=float)
        self.bias = 0.0 if self.classifier else float(target.mean())
        self.weights = np.linalg.solve(self.kernel(self.x, self.x) + self.alpha*np.eye(len(x)), target-self.bias)
        return self

    def predict(self, x):
        value = self.kernel(x, self.x) @ self.weights + self.bias
        return (value > 0).astype(int) if self.classifier else value


class Neighbors:
    def __init__(self, k=5, classifier=False):
        self.k, self.classifier = k, classifier

    def fit(self, x, y):
        self.x, self.y = np.asarray(x).copy(), np.asarray(y).copy()
        return self

    def predict(self, x):
        d = np.maximum(np.sum(x*x, axis=1)[:, None]+np.sum(self.x*self.x, axis=1)[None, :]-2*x@self.x.T, 0)
        ids = np.argsort(d, axis=1)[:, :min(self.k, len(self.x))]
        weights = 1 / np.maximum(np.sqrt(np.take_along_axis(d, ids, axis=1)), 1e-8)
        value = (weights*self.y[ids]).sum(1) / weights.sum(1)
        return (value > .5).astype(int) if self.classifier else value


class RegressionTree:
    def __init__(self, max_depth=5, min_leaf=4, max_features=None, random_threshold=False, seed=1):
        self.max_depth, self.min_leaf, self.max_features = max_depth, min_leaf, max_features
        self.random_threshold, self.seed = random_threshold, seed

    def fit(self, x, y):
        self.rng = np.random.default_rng(self.seed)
        self.nodes = []
        self._build(np.asarray(x), np.asarray(y, dtype=float), 0)
        return self

    def _build(self, x, y, depth):
        node_id = len(self.nodes)
        self.nodes.append([-1, 0., -1, -1, float(y.mean())])
        if depth >= self.max_depth or len(y) < 2*self.min_leaf or np.var(y) < 1e-12:
            return node_id
        count = self.max_features or max(1, int(np.sqrt(x.shape[1])))
        features = self.rng.choice(x.shape[1], min(count, x.shape[1]), replace=False)
        best, choice = np.inf, None
        for f in features:
            order = np.argsort(x[:, f])
            values, target = x[order, f], y[order]
            cuts = np.arange(self.min_leaf, len(y)-self.min_leaf+1)
            cuts = cuts[values[cuts-1] < values[cuts]]
            if not len(cuts):
                continue
            if self.random_threshold:
                cuts = self.rng.choice(cuts, min(3, len(cuts)), replace=False)
            sums = np.cumsum(target)
            scores = -(sums[cuts-1]**2/cuts + (sums[-1]-sums[cuts-1])**2/(len(y)-cuts))
            k = int(np.argmin(scores))
            if scores[k] < best:
                best = scores[k]
                cut = cuts[k]
                threshold = float((float(values[cut-1])+float(values[cut]))/2)
                choice = (int(f), threshold)
        if choice is None:
            return node_id
        f, threshold = choice
        mask = x[:, f] <= threshold
        left = self._build(x[mask], y[mask], depth+1)
        right = self._build(x[~mask], y[~mask], depth+1)
        self.nodes[node_id][:4] = [f, threshold, left, right]
        return node_id

    def predict(self, x):
        result = []
        for row in x:
            index = 0
            while self.nodes[index][0] >= 0:
                f, threshold, left, right, _ = self.nodes[index]
                index = left if row[f] <= threshold else right
            result.append(self.nodes[index][4])
        return np.array(result)


class Forest:
    def __init__(self, trees=48, depth=6, leaf=4, classifier=False, extra=False, seed=20261028):
        self.trees, self.depth, self.leaf = trees, depth, leaf
        self.classifier, self.extra, self.seed = classifier, extra, seed

    def fit(self, x, y):
        rng = np.random.default_rng(self.seed)
        self.models = []
        for k in range(self.trees):
            if self.classifier:
                classes = [np.flatnonzero(y == c) for c in (0, 1)]
                ids = np.concatenate([rng.choice(c, max(1, len(y)//2), replace=True) for c in classes])
            else:
                ids = rng.integers(len(y), size=len(y))
            tree = RegressionTree(self.depth, self.leaf, random_threshold=self.extra, seed=self.seed+k)
            self.models.append(tree.fit(x[ids], y[ids]))
        return self

    def predict(self, x):
        value = np.mean([tree.predict(x) for tree in self.models], axis=0)
        return (value > .5).astype(int) if self.classifier else value


class BoostedTrees:
    def __init__(self, trees=60, rate=.05, classifier=False, seed=20261028):
        self.trees, self.rate, self.classifier, self.seed = trees, rate, classifier, seed

    def fit(self, x, y):
        target = 2 * np.asarray(y, dtype=float)-1 if self.classifier else np.asarray(y, dtype=float)
        self.bias = float(target.mean())
        values = np.full(len(y), self.bias)
        self.models = []
        for k in range(self.trees):
            tree = RegressionTree(max_depth=2, min_leaf=10, max_features=min(24, x.shape[1]), seed=self.seed+k)
            tree.fit(x, target-values)
            values += self.rate*tree.predict(x)
            self.models.append(tree)
        return self

    def predict(self, x):
        values = self.bias+sum(self.rate*tree.predict(x) for tree in self.models)
        return (values > 0).astype(int) if self.classifier else values
