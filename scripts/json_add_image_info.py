#!/usr/bin/env python3

from os import getenv, path
from pathlib import Path
from sys import argv
import hashlib
import json

if len(argv) != 2:
    print("ERROR: JSON info script requires output arg")
    exit(1)

json_path = Path(argv[1])
file_path = Path(getenv("FILE_DIR")) / getenv("FILE_NAME")

if not file_path.is_file():
    print("Skip JSON creation for non existing file", file_path)
    exit(0)


def get_titles():
    titles = []
    for prefix in ["", "ALT0_", "ALT1_", "ALT2_", "ALT3_", "ALT4_", "ALT5_"]:
        title = {}
        for var in ["vendor", "model", "variant"]:
            if getenv("DEVICE_{}{}".format(prefix, var.upper())):
                title[var] = getenv("DEVICE_{}{}".format(prefix, var.upper()))

        if title:
            titles.append(title)

    if not titles:
        titles.append({"title": getenv("DEVICE_TITLE")})

    return titles


def get_numerical_size(image_size):
    if image_size.endswith("g"):
        return int(image_size[:-1]) * 1024 * 1024 * 1024
    elif image_size.endswith("m"):
        return int(image_size[:-1]) * 1024 * 1024
    elif image_size.endswith("k"):
        return int(image_size[:-1]) * 1024
    else:
        return int(image_size)


device_id = getenv("DEVICE_ID")

sha256_hash = hashlib.sha256()
with open(str(file_path),"rb") as f:
    # Read and update hash string value in blocks of 4K
    for byte_block in iter(lambda: f.read(4096),b""):
        sha256_hash.update(byte_block)

hash_file = sha256_hash.hexdigest()

if file_path.with_suffix(file_path.suffix + ".sha256sum").exists():
    hash_unsigned = (
        file_path.with_suffix(file_path.suffix + ".sha256sum").read_text().strip()
    )
else:
    hash_unsigned = hash_file

file_size = path.getsize(file_path)

file_info = {
    "metadata_version": 1,
    "target": "{}/{}".format(getenv("TARGET"), getenv("SUBTARGET")),
    "version_code": getenv("VERSION_CODE"),
    "version_number": getenv("VERSION_NUMBER"),
    "source_date_epoch": int(getenv("SOURCE_DATE_EPOCH")),
    "profiles": {
        device_id: {
            "image_prefix": getenv("DEVICE_IMG_PREFIX"),
            "images": [
                {
                    "type": getenv("FILE_TYPE"),
                    "name": getenv("FILE_NAME"),
                    "sha256": hash_file,
                    "sha256_unsigned": hash_unsigned,
                    "size": file_size,
                }
            ],
            "device_packages": getenv("DEVICE_PACKAGES").split(),
            "supported_devices": getenv("SUPPORTED_DEVICES").split(),
            "titles": get_titles(),
        }
    },
}

if getenv("IMAGE_SIZE") or getenv("KERNEL_SIZE"):
    file_info["profiles"][device_id]["file_size_limits"] = {}
    if getenv("IMAGE_SIZE"):
        file_info["profiles"][device_id]["file_size_limits"]["image"] = get_numerical_size(
            getenv("IMAGE_SIZE")
        )
    if getenv("KERNEL_SIZE"):
        file_info["profiles"][device_id]["file_size_limits"]["kernel"] = get_numerical_size(
            getenv("KERNEL_SIZE")
        )

if getenv("FILE_FILESYSTEM"):
    file_info["profiles"][device_id]["images"][0]["filesystem"] = getenv(
        "FILE_FILESYSTEM"
    )

json_path.write_text(json.dumps(file_info, separators=(",", ":")))
