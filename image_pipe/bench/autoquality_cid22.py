"""Summarize the official held-out human annotations without fitting to them.

Input: CID22_validation_set_annotations.zip from https://cloudinary.com/labs/cid22
MCOS is not SSIMULACRA2. Historical AVIF setting numbers are not ImagePipe Q.
"""
import csv
import hashlib
import io
import json
import statistics
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    payload = archive.read("CID22_validation_set.csv")
rows = list(csv.DictReader(io.StringIO(payload.decode("utf-8"))))
assert len(rows) == 4341
assert len({r["reference_img"] for r in rows}) == 49


def distribution(values):
    values = sorted(values)
    return {"n": len(values), "min": min(values), "p10": values[int(0.1 * (len(values) - 1))],
            "median": statistics.median(values), "p90": values[int(0.9 * (len(values) - 1))], "max": max(values)}


settings = {}
for encoder, setting in [("JPEG", "q75"), ("WebP", "q80"), ("AVIF_aom_s1", "q30"), ("AVIF_aom_s7", "q30")]:
    settings[encoder + ":" + setting] = distribution([float(r["MCOS"]) for r in rows if r["encoder"] == encoder and r["setting"] == setting])
lookup = {(r["reference_img"], r["encoder"], r["setting"]): float(r["MCOS"]) for r in rows}
paired = [lookup[ref, "AVIF_aom_s1", "q30"] - lookup[ref, "AVIF_aom_s7", "q30"]
          for ref in sorted({r["reference_img"] for r in rows})
          if (ref, "AVIF_aom_s1", "q30") in lookup and (ref, "AVIF_aom_s7", "q30") in lookup]
print(json.dumps({"source": "https://cloudinary.com/labs/cid22", "csv_sha256": hashlib.sha256(payload).hexdigest(),
                  "annotation_rows": len(rows), "heldout_originals": 49, "fixed_setting_mcos": settings,
                  "aom_s1_minus_s7_q30_mcos": distribution(paired),
                  "limits": ["Historical codecs/settings", "AVIF slow subset is incomplete",
                             "MCOS units differ from SSIMULACRA2", "Score differences carry observer uncertainty",
                             "No metric scores for these stimuli were recomputed; no new encodings inherit these ratings"]}, indent=2, sort_keys=True))
