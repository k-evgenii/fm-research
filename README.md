# fm-research

Exploratory analysis of a Football Manager dataset (~160k players, 84 features).
The goal is to find structure, anomalies, and patterns in player attributes using
unsupervised ML — no labels, no target variable. Pure exploration.

---

## Project structure

```
fm-research/
├── data/
│   └── intermediate/
│       ├── preliminary_analysis.csv     ← cleaned input (gitignored, large)
│       ├── fm_pca_coords.npy            ← (159541, 50) PCA memmap (gitignored)
│       ├── fm_cluster_labels.npy        ← (159541,) KMeans labels (gitignored)
│       ├── fm_anomaly_scores.npy        ← (159541,) IsoForest scores (gitignored)
│       ├── fm_dbscan_sample_labels.npy  ← DBSCAN labels on 20k subsample (gitignored)
│       ├── fm_dbscan_sample_idx.npy     ← row indices for DBSCAN subsample (gitignored)
│       ├── fm_explained_variance.npy    ← true ratios from ipca (committed, ~400 B)
│       └── fm_results.csv              ← Name + cluster + anomaly_score + PC1/PC2
├── fm_positional_analysis.py            ← step 1: positional consistency checks
├── fm_pipeline_v2.py                    ← step 2: main ML pipeline
├── fm_visualise.py                      ← step 3: plots from pipeline outputs
├── .gitignore
└── README.md
```

---

## Data

**Source:** Football Manager database export.  
**Shape:** 159,541 players × 84 numeric features (after cleaning).  
**Key columns:**

| Group | Columns |
|---|---|
| Goalkeeper attributes | AerialAbility, CommandOfArea, Handling, Reflexes, … |
| Outfield technical | Dribbling, Finishing, Passing, Tackling, Technique, … |
| Mental | Anticipation, Composure, Decisions, Vision, … |
| Physical | Acceleration, Pace, Stamina, Strength, … |
| Hidden | Consistency, Dirtiness, ImportantMatches, … |
| Positional ratings | Goalkeeper, Striker, DefenderCentral, AttackingMidRight, … |

**Excluded from model:**
- `Name` — identifier only, carried through to results for labelling
- `NationID` — categorical; integer codes would imply a false numerical distance between nations

---

## Pipeline (`fm_pipeline_v2.py`)

Runs in ~5s on a laptop. Streams the CSV in batches so the full feature
table is never in RAM. All large outputs are written to disk as numpy memmaps.

### Memory strategy

sklearn upcasts `float32` → `float64` internally, so peak RAM per batch is
roughly 4× the raw `float64` chunk size. With `target_ram_mb=48` and 84
features that works out to ~19,000 rows per batch (9 batches total).

```
target_ram_mb = 48   →   peak ≈ 192 MB
```

### Phases

**Phase 1a — StandardScaler** (CSV pass 1)  
`StandardScaler.partial_fit` over all batches. Learns global mean and
variance without loading the full dataset.

**Phase 1b — IncrementalPCA** (CSV pass 2)  
`IncrementalPCA.partial_fit` on scaled batches.  
`sklearn.pipeline.Pipeline` does not expose `partial_fit`, so scaler and
PCA are fitted in two separate passes — this is intentional, not a bug.  
Saves `fm_explained_variance.npy` with true `ipca.explained_variance_ratio_`.

**Phase 2 — Transform** (CSV pass 3)  
Assembles a fitted `Pipeline([scaler, pca])` for `.transform` only (this
works fine on already-fitted steps). Writes PCA coords straight to a
`(159541, 50)` memmap on disk.

**Phase 3 — MiniBatchKMeans sweep**  
Sweeps `k=2..7`, evaluates silhouette on a 2,000-row subsample.  
Writes winning cluster labels to disk memmap.

**Phase 3b — DBSCAN** (subsample)  
Runs on a 20,000-row subsample of PCA space.  
`eps` needs tuning — in 50D euclidean space distances are much larger than
in 25D; `eps=2.0` is too small (see Known issues).

**Phase 4 — IsolationForest**  
Fits on 20,000 sampled rows, scores the full 159k in batches.  
`contamination=0.01` flags ~1% (~1,553 players) as anomalous.

**Phase 5 — Results**  
Combines Name + cluster + anomaly_score + PC1/PC2 into `fm_results.csv`.

### Key config knobs

```python
n_components  = 50      # 90% variance at PC47; 91.2% total at PC50
k_range       = range(2, 8)
contamination = 0.01    # 0.05 was flagging elite players, not data errors
dbscan_eps    = 2.0     # needs raising to ~6.0 for 50D space
target_ram_mb = 48      # raise to 96–128 for faster throughput
n_cpu         = 2       # BLAS + sklearn thread cap
```

---

## Findings so far

### Explained variance
The curve has no clean elbow after PC3 — many attributes are correlated but
none dominates after the first "overall quality" axis (PC1 = 20%).  
90% variance requires 47 components; 25 was insufficient (74.5%).

### PCA shape
The data projects as a **crescent/banana shape** in PC1×PC2 space. This means
the data lives on a non-linear manifold — KMeans (which assumes convex
spherical clusters) is not the right tool here.

### Clusters
KMeans consistently finds **k=2** as the best silhouette score. This split
is not particularly meaningful — it roughly separates lower-quality from
higher-quality players along PC1. The real structure is likely positional.

The upper-left arm of the crescent (negative PC1, high PC2) is almost
certainly goalkeepers — their attribute profile is so different from
outfield players that they project far off the main manifold.

### Anomalies
With `contamination=0.01`, the top anomalies are still elite players
(Drogba, Zlatan, Ronaldo, Rooney). They are statistical outliers on the
quality axis — extreme but not erroneous. IsolationForest is detecting
the edge of the quality distribution rather than genuine data problems.

Two spatially distinct outlier groups are visible in the anomaly scatter:
- **Upper-left arm** (PC1 < −4, PC2 > 14) — likely goalkeepers with unusual
  attribute profiles, not elite players
- **Right side** (PC1 > 8) — elite outfield players at the quality extreme

---

## Known issues / next steps

- **DBSCAN `eps` too small** — `eps=2.0` produces 100% noise in 50D PCA space.
  Start at `eps=6.0` for the next run.
- **KMeans is wrong for crescent data** — consider HDBSCAN (handles non-convex
  shapes, doesn't require choosing k) once DBSCAN is tuned.
- **Anomaly detection finds quality, not errors** — to find genuine data oddities,
  consider residual-based detection (distance from cluster centroid in PCA space)
  or running IsolationForest on the residuals after removing the PC1 quality axis.
- **Positional labels not used yet** — the `Goalkeeper`, `Striker`, `DefenderCentral`
  etc. columns could be used to label a subset of clearly-positional players and
  validate the PCA structure (the GK arm hypothesis in particular).

---

## Reproducing results

```bash


# 1. Place the cleaned CSV at:
#    data/intermediate/preliminary_analysis.csv

# 2. Run the pipeline (first cell in a fresh kernel)
jupyter nbconvert --to notebook --execute fm_pipeline_v2.py

# 3. Run the visualisation
jupyter nbconvert --to notebook --execute fm_visualise.py
```

Or open the scripts as notebook cells directly — each script ends with a
bare `run()` / `results = run()` call that executes in Jupyter.