# Research on better matching from the existing racket recordings

## Finding

The recordings contain useful placement information. This research pass did not establish a dependable replacement for the current ridge distance method. The broader evaluation is less optimistic than the earlier 76% result: the fixed ridge method scored **67.2% across all 274 clips**, with **1.83 cm mean absolute radial-distance error**, when entire chronological blocks were held out.

The earlier 76% figure was correct for one reused 54-clip test split. It should not be presented as independently established on-court accuracy. The grouped result is another estimate from the same two development sessions, not a new field test.

## What was researched and tested

I examined primary racket-acoustics and vibration studies plus the official documentation for signal representations, robust regression, dimensional reduction and evaluation. The main experimental pass tested **130 model/feature/target configurations across three nested grouped experiments**: 46 on the common 32 ms windows, 46 on complete post-clipping tails, and 38 in onset/tail fusion. This required 1,950 inner-fold fits, plus the outer-fold and final candidate fits.

Representations tested:

- Existing 156 frequency and envelope features.
- Short-time HTK-mel cepstral features: means, variation and temporal changes.
- Four-level Haar wavelet-packet relative energies, averaged over small shifts.
- Relative frame/string frequency-band energies and broad-band decay profiles.
- Combined cepstral, wavelet and modal features.
- Onset plus full 128 ms tail features, clipping duration and relative decay levels, on the 177 long clips only.

Regressors tested: ridge, nonlinear RBF kernel ridge, supervised partial least squares (PLS), principal-component regression (PCR), fixed-delta Huber regression and a completed epsilon-SVR configuration. Targets included radial distance, radius squared, signed coordinates and absolute coordinates. The coordinate tests in the main nested search use linear ridge; they do not reproduce a learned nonlinear multi-task CNN.

Timing/noise augmentation and removing absolute-level/clipping inputs were also tested. No source label, clip, app or firmware file was changed by this research pass. All 14 rejected detections remain preserved outside placement training.

## Evaluation method

The common data contain 97 accepted clips from the earlier session and 177 from the later session. Each chronological group covers eight consecutive trigger numbers within one session, giving 37 groups across both sessions. Five outer folds hold out whole groups. Three inner folds choose the model using training groups only. Scaling, PCA and PLS are fitted inside each training fold. Original recordings and their augmented copies never cross a training/test boundary.

Two nested selectors are reported separately: one chooses by inner-fold distance error; the other chooses by inner-fold balanced sweet/off-centre accuracy. This prevents choosing a method on its outer test score. The fixed ridge recipe is evaluated on the same outer folds for comparison.

This is still development-data research. Feature families were designed after seeing earlier results, and the data cover only two sessions. Nested validation reduces parameter-selection bias; it does not create an independent club test or prove performance on another racket. [Evaluation reference](https://scikit-learn.org/stable/auto_examples/model_selection/plot_nested_cross_validation_iris.html).

## Results on all 274 clips

| Procedure | Sweet/off-centre accuracy | Balanced accuracy | Mean radial error |
|---|---:|---:|---:|
| Fixed current ridge recipe | 67.2% | 63.3% | 1.83 cm |
| Nested selection for distance error | 67.2% | 63.3% | 1.93 cm |
| Nested selection for balanced classification | 67.5% | 63.6% | 1.95 cm |
| Timing/noise augmentation | 67.2% | 63.7% | 1.98 cm |
| Remove absolute level and clipping inputs | 65.7% | 61.5% | 1.87 cm |
| Completed epsilon-SVR, C=1, epsilon=0.5 cm | 63.9% | 56.8% | 2.11 cm |
| Training-fold median distance | 60.6% | 50.0% | 2.41 cm |

The classification-selected search gained one correct clip, while distance error worsened. That is not convincing evidence of a better replacement. PLS with a small latent dimension was selected in several inner folds, but did not produce a consistent outer-fold gain. The plain ridge recipe remains the strongest simple distance baseline from this comparison.

The local SVR solver completed all five grouped folds for the C=1/current-feature setting. Its maximum equality-constraint error was below 3e-11. The remaining planned SVR settings were not completed: automatic approval review interrupted the process after detecting an unrelated Visual Studio telemetry connection. No attempt was made to allow that connection. This limits the SVR conclusion to the completed setting.

## Does the audio actually match the placements?

An exploratory permutation check shuffled target distances within each session, retaining the same audio and chronological grouping. In 99 shuffles, fixed-ridge distance error ranged from **2.27 to 2.73 cm**, compared with **1.83 cm** for the actual audio/placement pairing. The empirical lower-error fraction, including the observed case, was 0.01.

This supports a useful association beyond session-level class proportions. It does not establish a performance ceiling or supply a fresh field-accuracy estimate. The clips are valuable; these tests do not support discarding the dataset.

The stored coordinate labels and radial labels agree to within 0.011 cm after rounding. This rules out a large arithmetic mismatch between those saved files. It does not independently verify camera scale or the exact contact frame. The earlier labels used SAM scaling; the later labels used manual calibration. That difference remains worth checking without changing any validated labels automatically.

## Does the longer tail help?

A fair window comparison must use the same long-recording subset. On the **177 accepted long clips**:

| Input/procedure | Grouped accuracy | Mean radial error |
|---|---:|---:|
| Fixed ridge, initial 32 ms only | 52.5% | 1.96 cm |
| Fixed ridge, full post-clipping 128 ms | 61.6% | 1.79 cm |
| Nested onset/tail/fusion selection for distance | 57.6% | 1.88 cm |
| Nested onset/tail/fusion selection for balanced accuracy | 58.2% | 1.83 cm |

The complete tail is more promising than the clipped onset for this session. Simple concatenation of onset and tail did not reliably improve over the tail recipe. These are different datasets from the all-274 table, so 61.6% must not be compared directly with 67.2% as though only the input window changed. The older 97 recordings cannot supply a missing 128 ms tail.

## Ranked next steps using the existing data

### 1. Use all accepted clips when making the next deployment fit

The existing deployed coefficients were fitted on 175 training clips; the other 99 were reserved for validation/testing. Now that the model recipe is frozen, a separate ridge refit on all 274 accepted clips has been saved as ridge_refit_all274.pkl. Its evaluation evidence comes from the grouped out-of-fold runs; it has no new independent test score. It was not exported into the active firmware or flashed. This uses more of the available data without pretending that training accuracy measures field accuracy.

### 2. Prioritize the clean tail and separate region decisions from precise location

The matched 177-clip result favors the tail over the clipped onset. A small learned model with a shared representation and separate region/location outputs is a reasonable next experiment, with strong regularization and the same grouped evaluation. A recent directly relevant audio paper uses multi-scale experts and joint radial classification/position regression. Its abstract also reports noise augmentation; our simple noise augmentation did not transfer into an improvement here. The publisher's full page returned HTTP 429, so its detailed dataset and architecture were not verified in this pass. [Publisher record](https://doi.org/10.3390/app16147340).

This is a research hypothesis, not an achieved improvement. Do not automatically replace the current firmware with the current tail candidate.

### 3. Test a nonlinear two-coordinate model, then compute radius

A signed-coordinate prediction can cancel opposite-side impacts when the sound is ambiguous. Absolute-coordinate or joint region/location objectives may reduce that problem. The linear versions tested here did not clearly win. SmartDampener used separate support-vector regressors for the two axes, which motivates a proper nonlinear coordinate experiment. It used different sensing hardware, so its reported errors are not a benchmark for this handle microphone or for radial error. [Authors' paper, section 5.3](https://www.cse.psu.edu/~mkg31/papers/smartdamp.pdf).

### 4. Test full wavelet scattering as a fixed front end

The tested Haar packet features did not reliably improve matching. They are not a full wavelet-scattering transform. Scattering uses fixed wavelet/modulus stages to reduce nuisance variation without learning a large front end. This is a reasonable small-data alternative before training a large network. It remains untested here, and MCU cost would need measurement. [Kymatio documentation](https://www.kymat.io/userguide.html).

### 5. Represent uncertainty near the decision boundary

Seventy clips, about 26% of the labels, are within 1 cm of the 4 cm cutoff. The fixed ridge classifier scored 50% in that band and 73% outside it. A hard cutoff therefore turns moderate distance error into a binary error.

If predictions from 3 to 5 cm are shown as uncertain, the retained subset scores **79.2%**, but it covers only **154/274 clips (56.2%)**. The other **120 clips must be reported as uncertain**, not counted as correct or silently discarded. The retained subset also contains more off-centre hits; balanced accuracy is only 67.9%. This is a coverage trade-off, not 79% overall accuracy and not a calibrated confidence percentage. No app change was made.

## Physical context

The racket's geometric centre, vibration node and centre of percussion are not identical definitions. Our target remains the user's existing operational definition: within 4 cm of the labelled string-bed centre. Changing that definition to improve a score would change the task, so the labels were left intact. Grip/hand loading can alter racket response, which supports session-held-out checks and relative spectral measurements. [Cross's measurements](https://www.physics.usyd.edu.au/~cross/sweetspots.pdf).

A separate forehand-vibration study measured modal frequencies, decay and relative low-frequency energy. It found that changing playing velocity affected vibration amplitude more strongly than frequency content. That motivated the modal/relative-energy feature tests here; their lack of a reliable gain is an experimental result, not a reason to assume that the published physics is wrong. [Study](https://pmc.ncbi.nlm.nih.gov/articles/PMC4503399/).

## Verification and saved work

Six new regression tests passed: grouped fold separation and coverage, agreement between the existing kernel-form ridge and the new direct ridge implementation, finite feature outputs, latent-model fitting and serialization, constant-input PLS, and coordinate/radius conversions. All reviewed clip hashes were checked before the main experiment. No source sessions, rejected records, active coefficients or firmware were updated.

Files:

- summary.json: common/tail grouped metrics and boundary diagnostics.
- combined_results.json, tail_results.json, window_fusion_results.json: all nested selections and inner leaderboards.
- *_oof.npz: out-of-fold predictions and grouping identifiers.
- preprocessing_results.json and permutation_diagnostic.json: robustness and shuffled-label diagnostics.
- svr_results.json: the completed SVR configuration only.
- ridge_refit_all274.pkl: separate all-data ridge candidate, not installed.
- sources.json: primary-source links, evidence and access limits.
- training_code: local research scripts and tests.

Reproduce the main nested experiments with python ml/research_methods.py --out <new-run-directory>. The window-fusion and diagnostic scripts currently target the dated research directory. The model pickle files require the matching local research_methods module and should only be loaded from this trusted run.
