#!/usr/bin/env python3
"""Reference scoring with the PyTorch model, to validate the Swift/Core ML path.
Run inside the build venv:  python scripts/verify_clip.py /tmp/clipandnote-base.png
"""
import sys
import torch
from PIL import Image
import mobileclip
from export_mobileclip import LABELS  # same vocabulary

ckpt = "Resources/mobileclip_s0.pt"
model, _, preprocess = mobileclip.create_model_and_transforms("mobileclip_s0", pretrained=ckpt)
model.eval()
tokenizer = mobileclip.get_tokenizer("mobileclip_s0")

img = preprocess(Image.open(sys.argv[1]).convert("RGB")).unsqueeze(0)
with torch.no_grad():
    image_features = model.encode_image(img)
    image_features = image_features / image_features.norm(dim=-1, keepdim=True)
    text = tokenizer([p for _, p in LABELS])
    text_features = model.encode_text(text)
    text_features = text_features / text_features.norm(dim=-1, keepdim=True)
    logit_scale = model.logit_scale.exp()
    probs = (logit_scale * image_features @ text_features.T).softmax(dim=-1)[0]

ranked = sorted(zip([l for l, _ in LABELS], probs.tolist()), key=lambda x: -x[1])
print("PyTorch reference (top 5):")
for label, p in ranked[:5]:
    print(f"  {label:14s} {p:.3f}")
