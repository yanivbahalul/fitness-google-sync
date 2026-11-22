"""Builds a small Food-101 subset for training: N train and M test images per class,
copied into train/<class>/ and test/<class>/ folders (Create ML's labeled-directory layout).
Usage: python3 subset.py <food-101 dir> <out dir> <train per class> <test per class>"""
import os, shutil, sys

src, out, n_train, n_test = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
for split, n in (("train", n_train), ("test", n_test)):
    per_class = {}
    for line in open(os.path.join(src, "meta", f"{split}.txt")):
        cls, _ = line.strip().split("/")
        per_class.setdefault(cls, []).append(line.strip())
    for cls, items in per_class.items():
        os.makedirs(os.path.join(out, split, cls), exist_ok=True)
        for item in items[:n]:
            shutil.copy(os.path.join(src, "images", item + ".jpg"), os.path.join(out, split, cls, os.path.basename(item) + ".jpg"))
    print(split, len(per_class), "classes")
