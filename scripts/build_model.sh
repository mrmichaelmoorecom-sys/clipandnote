#!/bin/bash
# Best-effort: build the MobileCLIP CoreML model + label embeddings into Resources/.
set -e
cd /Users/macbook-17/clipandnote
echo "[1/6] venv"; python3 -m venv .venv-mc
source .venv-mc/bin/activate
echo "[2/6] pip core"; pip install --quiet --upgrade pip wheel
echo "[3/6] pip torch+coremltools"; pip install --quiet torch coremltools pillow
echo "[4/6] pip mobileclip"; pip install --quiet git+https://github.com/apple/ml-mobileclip.git
mkdir -p Resources
echo "[5/6] checkpoint"; curl -fL --retry 2 -o Resources/mobileclip_s0.pt \
  https://docs-assets.developer.apple.com/ml-research/datasets/mobileclip/mobileclip_s0.pt
echo "[6/6] export+compile"
python scripts/export_mobileclip.py --checkpoint Resources/mobileclip_s0.pt --model mobileclip_s0 --out Resources
xcrun coremlcompiler compile Resources/MobileCLIPImage.mlpackage Resources
echo "MODEL_BUILD_DONE"
