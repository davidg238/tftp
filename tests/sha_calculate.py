# Copyright 2024 Ekorau LLC

import os
import hashlib
import json

def compute_sha256(file_path):
    hasher = hashlib.sha256()
    with open(file_path, 'rb') as f:
        while chunk := f.read(8192):
            hasher.update(chunk)
    return hasher.hexdigest()

def generate_file_hashes(directory):
    file_hashes = {}
    for filename in os.listdir(directory):
        file_path = os.path.join(directory, filename)
        if os.path.isfile(file_path):
            file_hashes[filename] = compute_sha256(file_path)
    return file_hashes

def write_to_json(file_hashes, output_file):
    with open(output_file, 'w') as f:
        json.dump(file_hashes, f, indent=4)

directory = '../assets'  # replace with your directory
output_file = 'assets.json'  # replace with your output file

file_hashes = generate_file_hashes(directory)
write_to_json(file_hashes, output_file)