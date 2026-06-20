#!/usr/bin/env python3
"""
Export the MobileCLIP image encoder to Core ML and precompute label embeddings
for clipandnote's on-device snapshot naming.

Produces two files the app loads from its bundle (Contents/Resources):
  - MobileCLIPImage.mlmodelc   (compiled image encoder; normalization baked in)
  - clip_labels.json           (input/output names, input size, labels, and the
                                precomputed L2-normalized text embeddings)

The app runs only the image encoder at capture time, then does a cosine-similarity
dot product against these embeddings — no text encoder, tokenizer, or network at
runtime. Fully on-device.

Setup (one time):
    python3 -m venv .venv && source .venv/bin/activate
    pip install mobileclip coremltools torch

    # download a checkpoint (see https://github.com/apple/ml-mobileclip)
    #   e.g. mobileclip_s0.pt  (smallest; ~ tens of MB)

    python scripts/export_mobileclip.py --checkpoint mobileclip_s0.pt --model mobileclip_s0

Then copy the two outputs into the built app's Contents/Resources (the bundle
script in README does this), or into Sources resources if you wire SPM resources.

NOTE: this is a starting point — verify the normalization (mean/std) against your
model's `preprocess`, and the embedding dimension, before shipping.
"""
import argparse, json
import torch
import coremltools as ct
import mobileclip

# Curated screenshot vocabulary. The label is what shows up in the filename; the
# prompt is what we embed (CLIP reads a natural phrase better than a bare word).
LABELS = [
    ("Login screen",   "a screenshot of a login or sign-in screen"),
    ("Error dialog",   "a screenshot of an error message or alert dialog"),
    ("Settings",       "a screenshot of a settings or preferences screen"),
    ("Code",           "a screenshot of source code in a code editor"),
    ("Terminal",       "a screenshot of a command-line terminal"),
    ("Spreadsheet",    "a screenshot of a spreadsheet or table of data"),
    ("Chart",          "a screenshot of a chart or graph"),
    ("Diagram",        "a screenshot of a diagram or flowchart"),
    ("Chat",           "a screenshot of a chat or messaging conversation"),
    ("Email",          "a screenshot of an email inbox or message"),
    ("Web page",       "a screenshot of a web page in a browser"),
    ("Document",       "a screenshot of a text document"),
    ("Form",           "a screenshot of a form with input fields"),
    ("Calendar",       "a screenshot of a calendar"),
    ("Map",            "a screenshot of a map"),
    ("Photo",          "a photograph"),
    ("Design mockup",  "a screenshot of a design tool or UI mockup"),
    ("Dashboard",      "a screenshot of an analytics dashboard"),
    ("Video",          "a screenshot of a video player"),
    ("Music",          "a screenshot of a music player"),
]

# OpenAI CLIP normalization — verify against your model's preprocess transforms.
MEAN = (0.48145466, 0.4578275, 0.40821073)
STD  = (0.26862954, 0.26130258, 0.27577711)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--model", default="mobileclip_s0")
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--out", default="Resources")
    args = ap.parse_args()

    model, _, _ = mobileclip.create_model_and_transforms(args.model, pretrained=args.checkpoint)
    model.eval()
    tokenizer = mobileclip.get_tokenizer(args.model)

    # --- Image encoder → Core ML ---
    # Per-channel CLIP normalization is baked INTO the module (ImageType's scale
    # is a single scalar, so it can't do per-channel std). ImageType then only
    # divides the 0–255 input by 255 to reach [0,1].
    class ImageEncoder(torch.nn.Module):
        def __init__(self, m, mean, std):
            super().__init__()
            self.m = m
            self.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1))
        def forward(self, x):                       # x in [0,1]
            return self.m.encode_image((x - self.mean) / self.std)

    enc = ImageEncoder(model, MEAN, STD).eval()
    example = torch.rand(1, 3, args.size, args.size)
    traced = torch.jit.trace(enc, example)

    image_input = ct.ImageType(name="image", shape=(1, 3, args.size, args.size),
                               scale=1.0 / 255.0, bias=[0.0, 0.0, 0.0],
                               color_layout=ct.colorlayout.RGB)
    mlmodel = ct.convert(traced, inputs=[image_input],
                         outputs=[ct.TensorType(name="embedding")],
                         minimum_deployment_target=ct.target.macOS14)
    mlmodel.save(f"{args.out}/MobileCLIPImage.mlpackage")

    # --- Precompute L2-normalized text embeddings for each label ---
    with torch.no_grad():
        tokens = tokenizer([prompt for _, prompt in LABELS])
        feats = model.encode_text(tokens)
        feats = feats / feats.norm(dim=-1, keepdim=True)
    embeddings = feats.tolist()

    pack = {
        "inputName": "image",
        "outputName": "embedding",
        "inputSize": args.size,
        "labels": [label for label, _ in LABELS],
        "embeddings": embeddings,
    }
    with open(f"{args.out}/clip_labels.json", "w") as f:
        json.dump(pack, f)

    print("Wrote MobileCLIPImage.mlpackage and clip_labels.json to", args.out)
    print("Compile the model:  xcrun coremlcompiler compile "
          f"{args.out}/MobileCLIPImage.mlpackage {args.out}")
    print("Then place MobileCLIPImage.mlmodelc + clip_labels.json in the app's "
          "Contents/Resources.")


if __name__ == "__main__":
    main()
