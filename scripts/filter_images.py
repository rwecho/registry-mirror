#!/usr/bin/env python3
"""Filter images.yaml based on comma-separated image names passed via IMAGES_REQUESTED env var."""
import os
import yaml
import sys

with open('images.yaml') as f:
    config = yaml.safe_load(f)

requested = os.environ.get('IMAGES_REQUESTED', '')
images_requested = [i.strip() for i in requested.split(',') if i.strip()]

if not images_requested:
    print("No filter requested — syncing all images")
    sys.exit(0)

filtered = {'registry': config['registry'], 'images': []}
for img in config['images']:
    src = img.get('source', '')
    if any(req in src for req in images_requested):
        filtered['images'].append(img)

with open('images_filtered.yaml', 'w') as f:
    yaml.dump(filtered, f)

print(f'Filtered {len(filtered["images"])} images matching: {images_requested}')
