# Classical regression and tree model comparison

## Result

The primary combined-data candidate is a ridge distance regressor on 156 frequency and envelope features from the initial 32 ms of audio. It predicts distance in cm. The sweet-spot decision uses the existing physical limit: predicted distance <= 4 cm.

| Model | Test examples | Test accuracy | Mean distance error |
|---|---:|---:|---:|
| Synthetic MLP, on these same real clips | 54 | 61.1% | Not used |
| Previous real-data MLP | 54 | 57.4% | Not used |
| Combined ridge distance model, 4 cm threshold | 54 | 75.9% (41/54) | 1.91 cm |
| Post-clipping boosted-tree classifier | 35 | 74.3% (26/35) | Separate regression model |
| Post-clipping random-forest regressor | 35 | 68.6% at 4 cm | 1.52 cm |

These figures are diagnostics, not independently confirmed field accuracy. The same test sets were already inspected in previous experiments. The combined distance model's validation classification accuracy was 57.8% on 45 clips, although its validation distance error was the best among the tested regressors at 2.11 cm. The difference between validation and test results matters; a new session is needed to establish performance.

The decay boosted classifier scored 69.0% on 29 validation clips and 74.3% on 35 test clips. Its test sweet-spot recall was 88.9%, and off-centre recall was 58.8%. It uses only today's 177 accepted long recordings because the older clips lack the required tail. The decay regressor is a separate model; its 1.52 cm error must not be attributed to the boosted classifier.

## Data and model selection

The combined dataset contains 274 reviewed accepted recordings: 97 from the earlier session and 177 from the later session. All 14 rejected detections remain excluded and recorded in rejected_detections.csv. Their audio is retained in the earlier audited run's excluded_clips directory. One scaling failure is recorded separately in that run. No recording or label was changed.

The existing split was retained: 175 training, 45 validation and 54 fixed test clips. Today-only tail experiments use 113 training, 29 validation and 35 test clips. Scaling and model fitting use only training rows. Models were selected on validation metrics; test results were then reported. Classifier cross-validation is restricted to the training rows and is stratified by session and class.

Classifiers tested: RBF kernel ridge, linear ridge, distance-weighted nearest neighbours, random forests, randomized trees and boosted trees. Regressors tested: linear and RBF kernel ridge, nearest neighbours, random forests, randomized trees and boosted trees. The comparison uses the legacy 12 inputs, 122 spectral/statistical inputs and 156 spectral/envelope inputs. No camera, label position, filename, session identifier or timestamp is an audio-model input. No network service or extra package is required for inference.

The direct combined classifier selected on validation was RBF kernel ridge on the legacy features. It scored 53.7% on the test set. It remains saved for comparison, but is not the recommended output. The primary output is distance regression, selected for validation distance error, followed by the predetermined 4 cm limit. This distinction prevents attributing the regression result to the weaker direct classifier.

The original synthetic model was tested on exactly the same 54 clips. It predicted off-centre for every clip, giving 61.1% accuracy and 50% balanced accuracy. The new distance regressor scored 73.4% balanced accuracy, with 13/21 sweet hits and 28/33 off-centre hits correctly identified.

## Saved files

- combined_model.pkl: both fitted combined models. Use the regression output as primary.
- decay_model.pkl: separate fitted boosted-tree classifier and random-forest distance regressor for complete tails.
- distance_model.json: direct coefficients and exact feature definition for the combined ridge regressor.
- distance_model.h: C++ coefficients. The 156-feature extractor must also be ported before this can run on the racket.
- results.json: every validation result, test result, cross-session check and verification error.
- features.npz: extracted inputs, target distances and exact split indices.
- predictions.csv: predictions for each fixed combined test clip.
- training_code: snapshot of the code used for the comparison.

These files are model artifacts, not flashed firmware. The active racket firmware and generated legacy model are unchanged.

## Verification

Six local regression tests passed: tree boundaries, constant inputs, known-signal classification, checkpoint serialization, finite audio features, linear coefficient export and rejection of a short clip for a decay model. Saved-model inference reproduced all 54 combined test predictions. The direct float32 coefficients reproduced predictions within 0.000004 cm. This does not replace firmware compilation or C++ feature parity testing.

## Use on a saved recording

From the repository root:

```powershell
python ml/predict_audio.py data/sessions/20261028-155849-long-run2/clips/clip-0001.i16
```

To use the complete post-clipping tail regressor:

```powershell
python ml/predict_audio.py data/sessions/20261028-155849-long-run2/clips/clip-0001.i16 --model ml/runs/20261028-classical-ml/decay_model.pkl
```

For the separate boosted-tree sweet-spot decision, use the saved checkpoint's classifier with classifier_features. The command above deliberately reports the regressor's distance and the 4 cm threshold, not that separate classifier's decision.
