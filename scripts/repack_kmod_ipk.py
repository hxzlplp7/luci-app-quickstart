#!/usr/bin/env python3

import argparse
import copy
import io
import pathlib
import re
import tarfile
import tempfile


def read_archive_members(archive_path: pathlib.Path):
    members = []
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            payload = None
            if member.isfile():
                extracted = archive.extractfile(member)
                payload = extracted.read() if extracted else b""
            members.append((copy.copy(member), payload))
    return members


def write_archive_members(archive_path: pathlib.Path, members):
    with tarfile.open(archive_path, "w:gz", format=tarfile.GNU_FORMAT) as archive:
        for member, payload in members:
            entry = copy.copy(member)
            if entry.isfile():
                entry.size = len(payload or b"")
                archive.addfile(entry, io.BytesIO(payload or b""))
            else:
                archive.addfile(entry)


def patch_control_payload(control_bytes: bytes, kernel_dependency: str) -> bytes:
    text = control_bytes.decode("utf-8")
    patched = re.sub(
        r"^Depends:\s*kernel\s*\(=.*?\)$",
        f"Depends: kernel (={kernel_dependency})",
        text,
        flags=re.MULTILINE,
    )
    if patched == text:
        raise RuntimeError("Could not find kernel dependency in control file")
    return patched.replace("\r\n", "\n").encode("utf-8")


def main():
    parser = argparse.ArgumentParser(description="Repack a kmod ipk with a rewritten kernel dependency.")
    parser.add_argument("--input-ipk", required=True)
    parser.add_argument("--kernel-dependency", required=True)
    parser.add_argument("--output-ipk", required=True)
    args = parser.parse_args()

    input_ipk = pathlib.Path(args.input_ipk).resolve()
    output_ipk = pathlib.Path(args.output_ipk).resolve()
    output_ipk.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="dashboard-kmod-repack-") as tmp_dir:
        temp_root = pathlib.Path(tmp_dir)

        with tarfile.open(input_ipk, "r:gz") as outer:
            outer.extractall(temp_root)

        control_path = temp_root / "control.tar.gz"
        control_members = read_archive_members(control_path)

        patched_members = []
        for member, payload in control_members:
            if member.isfile() and pathlib.PurePosixPath(member.name).name == "control":
                payload = patch_control_payload(payload or b"", args.kernel_dependency)
            patched_members.append((member, payload))

        write_archive_members(control_path, patched_members)

        if output_ipk.exists():
            output_ipk.unlink()

        with tarfile.open(output_ipk, "w:gz", format=tarfile.GNU_FORMAT) as outer:
            for name in ("debian-binary", "control.tar.gz", "data.tar.gz"):
                outer.add(temp_root / name, arcname=name, recursive=False)

    print(f"Wrote {output_ipk}")


if __name__ == "__main__":
    main()
