#!/usr/bin/env python3
"""End-to-end regression test for fresh HDF5 stage restarts.

The test intentionally corrupts data that belongs to the requested stage or a
later stage. A load-everything-then-prune implementation fails while parsing
that data; the selective restart loader must ignore it, run the stage, and save
a canonical cumulative snapshot.

Requires Docker and h5py. By default the script first generates its own
complete stage-3 fixture from assets/tutorial/spot.mesh. The CPU/no-Vulkan
build image is used so the test does not require a GPU or renderer.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import h5py
import numpy as np


STAGES = (
    (0, "deformation"),
    (1, "decomposition"),
    (2, "discretization"),
    (3, "hexahedralization"),
)

EXPECTED_ROOTS = {
    0: {"target_volume_mesh", "deformed_volume_mesh"},
    1: {
        "target_volume_mesh",
        "deformed_volume_mesh",
        "polycube",
        "polycube_info",
    },
    2: {
        "target_volume_mesh",
        "deformed_volume_mesh",
        "polycube",
        "polycube_info",
        "polycube_complex",
    },
    3: {
        "target_volume_mesh",
        "deformed_volume_mesh",
        "polycube",
        "polycube_info",
        "polycube_complex",
        "target_complex",
        "result_mesh",
    },
}

STAGE_CONFIG = {
    "deformation": "      steps: 0\n",
    "decomposition": (
        "      num_cuboids: 1\n"
        "      suggest_strategy: largest\n"
        "      reopt_steps: 0\n"
        "      grid_size: 2\n"
        "      inside_only: false\n"
        "      bbox_padding: 0.0\n"
        "      surface_samples: 8\n"
        "      perturbation: 0.01\n"
    ),
    "discretization": (
        "      hex_size: 0.15\n"
        "      round_to_nearest: false\n"
        "      padding: true\n"
    ),
    "hexahedralization": (
        "      inversion_free: false\n"
        "      projection_weight: 1.0\n"
        "      hausdorff_weight: 1.0\n"
        "      fairness_weight: 0.0\n"
        "      smoothness_weight: 1.0\n"
        "      learning_rate: 1.0e-4\n"
        "      steps: 0\n"
    ),
}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def replace_with_empty_group(hdf5: h5py.File, name: str) -> None:
    if name in hdf5:
        del hdf5[name]
    hdf5.create_group(name)


def replace_with_invalid_float_dataset(group: h5py.Group, name: str) -> None:
    if name in group:
        del group[name]
    group.create_dataset(name, data=np.asarray([[b"stale"]], dtype="S5"))


def prepare_corrupt_input(source: Path, destination: Path, stage_index: int) -> None:
    shutil.copy2(source, destination)
    with h5py.File(destination, "r+") as hdf5:
        # Pipeline-generated anchors/SDF belong only to the deformed mesh. A
        # selective scripted load must not import unexpected target caches.
        target = hdf5["target_volume_mesh"]
        replace_with_invalid_float_dataset(target, "anchors")
        replace_with_invalid_float_dataset(target, "sdf")

        if stage_index == 0:
            # Deformation must not even parse the previous deformed mesh.
            replace_with_empty_group(hdf5, "deformed_volume_mesh")
        elif stage_index == 1:
            # anchors/sdf are nested in deformed_volume_mesh but are stage-1
            # products. A string dataset cannot be converted by the float
            # loader, proving that a successful run skipped it before parsing.
            deformed = hdf5["deformed_volume_mesh"]
            replace_with_invalid_float_dataset(deformed, "anchors")
            replace_with_invalid_float_dataset(deformed, "sdf")
            replace_with_empty_group(hdf5, "polycube")
        elif stage_index == 2:
            names = hdf5["polycube_info/names"]
            if names.ndim != 2 or names.shape[0] == 0 or names.shape[1] != 32:
                raise ValueError(
                    f"fixture has invalid polycube name shape: {names.shape}"
                )
            # A valid 32-byte name has no NUL terminator in the fixed-width
            # on-disk row. Loading must stop at the row boundary, not scan into
            # an adjacent row or beyond the allocation.
            names[0, :] = np.frombuffer(b"N" * 32, dtype=np.uint8)
            replace_with_empty_group(hdf5, "polycube_complex")
        elif stage_index == 3:
            replace_with_empty_group(hdf5, "target_complex")
            replace_with_empty_group(hdf5, "result_mesh")
        else:
            raise ValueError(f"invalid stage index: {stage_index}")


def write_stage_yaml(
    path: Path,
    container_input: Path,
    container_run_dir: Path,
    stage_name: str,
    output_entries: dict[str, str | Path] | None = None,
) -> None:
    extra_output = "".join(
        f"  {key}: {value}\n" for key, value in (output_entries or {}).items()
    )
    path.write_text(
        "input:\n"
        "  type: hdf5\n"
        f"  path: {container_input}\n\n"
        "stages:\n"
        f"  - {stage_name}:\n"
        f"{STAGE_CONFIG[stage_name]}\n"
        "output:\n"
        f"  run_dir: {container_run_dir}\n"
        f"{extra_output}\n"
        "keep_window_open: false\n",
        encoding="utf-8",
    )


def write_full_pipeline_yaml(
    path: Path,
    container_input: Path,
    container_run_dir: Path,
) -> None:
    stage_entries = "".join(
        f"  - {stage_name}:\n{STAGE_CONFIG[stage_name]}"
        for _, stage_name in STAGES
    )
    path.write_text(
        "input:\n"
        "  type: mesh\n"
        f"  path: {container_input}\n\n"
        "stages:\n"
        f"{stage_entries}\n"
        "output:\n"
        f"  run_dir: {container_run_dir}\n\n"
        "keep_window_open: false\n",
        encoding="utf-8",
    )


def docker_hex_command(
    repo_root: Path, image: str, container_yaml: Path
) -> list[str]:
    return [
        "docker",
        "run",
        "--rm",
        "--workdir",
        "/space/interactive-hex-meshing/bin/Release",
        "-v",
        f"{repo_root / 'interactive-hex-meshing'}:/space/interactive-hex-meshing:ro",
        "-v",
        f"{repo_root / 'output'}:/space/output",
        image,
        "/space/interactive-hex-meshing/bin/Release/hex",
        "--script",
        str(container_yaml),
        "--device",
        "cpu",
        "--no-vulkan",
    ]


def run_hex(
    repo_root: Path,
    image: str,
    host_log: Path,
    container_yaml: Path,
    expected_success: bool = True,
) -> str:
    result = subprocess.run(
        docker_hex_command(repo_root, image, container_yaml),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
        timeout=300,
    )
    host_log.write_text(result.stdout, encoding="utf-8")
    if expected_success and result.returncode != 0:
        raise RuntimeError(
            f"hex failed with exit {result.returncode}; see {host_log}\n"
            + "\n".join(result.stdout.splitlines()[-40:])
        )
    if not expected_success and result.returncode == 0:
        raise RuntimeError(f"hex unexpectedly succeeded; see {host_log}")
    return result.stdout


def assert_snapshot(
    output: Path,
    source_input: Path,
    stage_index: int,
    expected_scale: np.ndarray,
    expected_center: np.ndarray,
) -> None:
    with h5py.File(output, "r") as hdf5, h5py.File(source_input, "r") as source:
        actual_roots = set(hdf5.keys())
        if actual_roots != EXPECTED_ROOTS[stage_index]:
            raise AssertionError(
                f"stage {stage_index} roots: {sorted(actual_roots)}; "
                f"expected {sorted(EXPECTED_ROOTS[stage_index])}"
            )
        if set(hdf5.attrs.keys()) != {"input_scale", "input_center"}:
            raise AssertionError(
                f"stage {stage_index} attributes: {sorted(hdf5.attrs.keys())}; "
                "expected ['input_center', 'input_scale']"
            )
        np.testing.assert_allclose(hdf5.attrs["input_scale"], expected_scale)
        np.testing.assert_allclose(hdf5.attrs["input_center"], expected_center)

        target_fields = set(hdf5["target_volume_mesh"].keys())
        if target_fields != {"vertices", "tets"}:
            raise AssertionError(
                f"stage {stage_index} target fields: {sorted(target_fields)}; "
                "expected ['tets', 'vertices']"
            )

        deformed_fields = set(hdf5["deformed_volume_mesh"].keys())
        expected_deformed = {"vertices", "tets"}
        if stage_index >= 1:
            expected_deformed.update({"anchors", "sdf"})
        if deformed_fields != expected_deformed:
            raise AssertionError(
                f"stage {stage_index} deformed fields: "
                f"{sorted(deformed_fields)}; expected {sorted(expected_deformed)}"
            )

        expected_group_fields = {
            "polycube": {"params"},
            "polycube_info": {"ordering", "locked", "names"},
            "polycube_complex": {"vertices", "quads", "patches", "hexes"},
            "target_complex": {"vertices", "quads", "patches", "hexes"},
            "result_mesh": {"vertices", "hexes"},
        }
        for group_name, expected_fields in expected_group_fields.items():
            if group_name not in hdf5:
                continue
            actual_fields = set(hdf5[group_name].keys())
            if actual_fields != expected_fields:
                raise AssertionError(
                    f"stage {stage_index} {group_name} fields: "
                    f"{sorted(actual_fields)}; expected {sorted(expected_fields)}"
                )

        # The cut is selective, not a lossy rebuild: every retained upstream
        # payload must remain byte-for-byte equivalent at the dataset level.
        retained_datasets = [
            "target_volume_mesh/vertices",
            "target_volume_mesh/tets",
        ]
        if stage_index >= 1:
            retained_datasets.extend(
                ["deformed_volume_mesh/vertices", "deformed_volume_mesh/tets"]
            )
        if stage_index >= 2:
            retained_datasets.extend(
                [
                    "polycube/params",
                    "polycube_info/ordering",
                    "polycube_info/locked",
                ]
            )
        if stage_index >= 3:
            retained_datasets.extend(
                [
                    "polycube_complex/vertices",
                    "polycube_complex/quads",
                    "polycube_complex/patches",
                    "polycube_complex/hexes",
                ]
            )
        for dataset in retained_datasets:
            np.testing.assert_array_equal(hdf5[dataset][...], source[dataset][...])

        if stage_index >= 2:
            # FixedLengthStr padding bytes are not semantically meaningful and
            # older files do not guarantee that bytes after the first NUL are
            # initialized. Compare the actual names, not their padding.
            def decoded_names(group: h5py.File) -> list[bytes]:
                return [
                    bytes(row).split(b"\0", 1)[0]
                    for row in group["polycube_info/names"][...]
                ]

            if decoded_names(hdf5) != decoded_names(source):
                raise AssertionError("polycube_info names changed across restart")


def write_stage_validation_yaml(path: Path, stages: str) -> None:
    path.write_text(
        "input:\n"
        "  type: hdf5\n"
        "  path: /definitely/missing/input.hdf5\n"
        f"stages: {stages}\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "fixture",
        nargs="?",
        type=Path,
        help=(
            "optional complete stage_3_hexahedralization.hdf5 fixture; "
            "generated from the tutorial mesh when omitted"
        ),
    )
    parser.add_argument("--image", default="hexmesh-novk:build")
    parser.add_argument(
        "--tutorial-mesh",
        type=Path,
        help="mesh used for self-generated fixture (default: tutorial Spot)",
    )
    parser.add_argument(
        "--keep-temp", action="store_true", help="keep generated test artifacts"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    output_root = repo_root / "output"
    output_root.mkdir(exist_ok=True)
    test_dir = Path(tempfile.mkdtemp(prefix="stage_restart_test_", dir=output_root))
    container_test_dir = Path("/space/output") / test_dir.relative_to(output_root)
    success = False

    try:
        if args.fixture is not None:
            fixture = args.fixture.resolve()
        else:
            tutorial_mesh = (
                args.tutorial_mesh.resolve()
                if args.tutorial_mesh is not None
                else repo_root
                / "interactive-hex-meshing"
                / "assets"
                / "tutorial"
                / "spot.mesh"
            )
            if not tutorial_mesh.is_file():
                raise FileNotFoundError(tutorial_mesh)

            fixture_source = test_dir / f"fixture_source{tutorial_mesh.suffix}"
            shutil.copy2(tutorial_mesh, fixture_source)
            generation_dir = test_dir / "generated_fixture"
            generation_dir.mkdir()
            generation_yaml = test_dir / "generate_fixture.yaml"
            write_full_pipeline_yaml(
                generation_yaml,
                container_test_dir / fixture_source.name,
                container_test_dir / generation_dir.name,
            )
            print(f"Generating fixture from {tutorial_mesh} ...", flush=True)
            run_hex(
                repo_root,
                args.image,
                test_dir / "generate_fixture.log",
                container_test_dir / generation_yaml.name,
            )
            fixture = generation_dir / "stage_3_hexahedralization.hdf5"
            print("PASS: self-generated complete stage-3 fixture")

        if not fixture.is_file():
            raise FileNotFoundError(fixture)
        required_roots = EXPECTED_ROOTS[3]
        with h5py.File(fixture, "r") as hdf5:
            missing = required_roots.difference(hdf5.keys())
            if missing:
                raise ValueError(
                    f"fixture is not complete; missing {sorted(missing)}"
                )
            expected_scale = np.asarray(hdf5.attrs["input_scale"])
            expected_center = np.asarray(hdf5.attrs["input_center"])
        fixture_hash = file_sha256(fixture)

        # These must fail during stage validation, before trying the missing
        # input path. That proves the boundary is known before project loading.
        for name, stages, expected_message in (
            ("empty_stages", "[]", "missing, empty, or invalid 'stages' list"),
            (
                "backward_stages",
                "\n  - decomposition: {}\n  - deformation: {}",
                "strictly increasing pipeline order",
            ),
            (
                "skipped_stage",
                "\n  - deformation: {}\n  - discretization: {}",
                "multiple stages must be contiguous",
            ),
        ):
            yaml_path = test_dir / f"{name}.yaml"
            write_stage_validation_yaml(yaml_path, stages)
            output = run_hex(
                repo_root,
                args.image,
                test_dir / f"{name}.log",
                container_test_dir / yaml_path.name,
                expected_success=False,
            )
            if expected_message not in output or "failed to load input" in output:
                raise AssertionError(f"wrong validation order for {name}:\n{output}")

        # SaveState truncates an existing destination. Verify that a direct
        # YAML invocation cannot name its source file as the stage output.
        collision_dir = test_dir / "source_collision"
        collision_dir.mkdir()
        collision_input = collision_dir / "stage_1_decomposition.hdf5"
        shutil.copy2(fixture, collision_input)
        collision_hash = file_sha256(collision_input)
        container_collision_dir = container_test_dir / collision_dir.name
        collision_yaml = collision_dir / "run_config.yaml"
        write_stage_yaml(
            collision_yaml,
            container_collision_dir / collision_input.name,
            container_collision_dir,
            "decomposition",
        )
        collision_output = run_hex(
            repo_root,
            args.image,
            collision_dir / "log.txt",
            container_collision_dir / collision_yaml.name,
            expected_success=False,
        )
        if "refusing to overwrite input file" not in collision_output:
            raise AssertionError(
                f"source/output collision was not rejected:\n{collision_output}"
            )
        if file_sha256(collision_input) != collision_hash:
            raise AssertionError("collision check modified its input file")
        print("PASS: source/output collision rejected")

        # Exporters also truncate files, and an export can alias either the
        # source, a stage snapshot, or another export. Every destination must
        # be checked as one set before hexahedralization starts.
        for collision_name in (
            "export_mesh_input",
            "export_metrics_input",
            "export_mesh_stage",
            "exports_each_other",
        ):
            export_dir = test_dir / collision_name
            export_dir.mkdir()
            export_input = export_dir / "input.hdf5"
            shutil.copy2(fixture, export_input)
            export_input_hash = file_sha256(export_input)
            container_export_dir = container_test_dir / export_dir.name
            if collision_name == "export_mesh_input":
                output_entries = {
                    "export_mesh": container_export_dir / export_input.name
                }
                expected_collision = "refusing to overwrite input file"
            elif collision_name == "export_metrics_input":
                output_entries = {
                    "export_metrics": container_export_dir / export_input.name
                }
                expected_collision = "refusing to overwrite input file"
            elif collision_name == "export_mesh_stage":
                output_entries = {
                    "export_mesh": "stage_3_hexahedralization.hdf5"
                }
                expected_collision = "output destinations collide"
            else:
                output_entries = {
                    "export_mesh": "shared.out",
                    "export_metrics": "shared.out",
                }
                expected_collision = "output destinations collide"

            export_yaml = export_dir / "run_config.yaml"
            write_stage_yaml(
                export_yaml,
                container_export_dir / export_input.name,
                container_export_dir,
                "hexahedralization",
                output_entries,
            )
            export_output = run_hex(
                repo_root,
                args.image,
                export_dir / "log.txt",
                container_export_dir / export_yaml.name,
                expected_success=False,
            )
            if expected_collision not in export_output:
                raise AssertionError(
                    f"{collision_name} was not rejected:\n{export_output}"
                )
            if "=== running stage" in export_output:
                raise AssertionError(
                    f"{collision_name} was detected after a stage started"
                )
            if file_sha256(export_input) != export_input_hash:
                raise AssertionError(f"{collision_name} modified its input")
            if (export_dir / "stage_3_hexahedralization.hdf5").exists():
                raise AssertionError(f"{collision_name} created a stage output")
        print("PASS: all stage/export destination collisions rejected upfront")

        # Polycube metadata is used for indexing after a Stage-2/3 restart.
        # Reject malformed vector lengths while loading, before a controller
        # can index through them.
        metadata_dir = test_dir / "malformed_polycube_info"
        metadata_dir.mkdir()
        metadata_input = metadata_dir / "input.hdf5"
        shutil.copy2(fixture, metadata_input)
        with h5py.File(metadata_input, "r+") as hdf5:
            del hdf5["polycube_info/locked"]
            hdf5["polycube_info"].create_dataset(
                "locked", data=np.asarray([], dtype=np.int32)
            )
        metadata_hash = file_sha256(metadata_input)
        container_metadata_dir = container_test_dir / metadata_dir.name
        metadata_yaml = metadata_dir / "run_config.yaml"
        write_stage_yaml(
            metadata_yaml,
            container_metadata_dir / metadata_input.name,
            container_metadata_dir,
            "discretization",
        )
        metadata_output = run_hex(
            repo_root,
            args.image,
            metadata_dir / "log.txt",
            container_metadata_dir / metadata_yaml.name,
            expected_success=False,
        )
        if "inconsistent polycube and polycube_info" not in metadata_output:
            raise AssertionError(
                f"malformed polycube_info was not rejected:\n{metadata_output}"
            )
        if file_sha256(metadata_input) != metadata_hash:
            raise AssertionError("metadata validation modified its input file")
        print("PASS: malformed polycube metadata rejected")

        # The names dataset has a strict [N, 32] byte layout. Reject rank and
        # width changes explicitly instead of letting the loader read through
        # an undersized stack array or accept oversized names.
        for case_name, malformed_names, expected_message in (
            (
                "rank_1",
                np.zeros((32,), dtype=np.uint8),
                "must be a rank-2",
            ),
            (
                "width_33",
                np.full((1, 33), ord("X"), dtype=np.uint8),
                "must have shape [N, 32]",
            ),
        ):
            names_dir = test_dir / f"malformed_polycube_names_{case_name}"
            names_dir.mkdir()
            names_input = names_dir / "input.hdf5"
            shutil.copy2(fixture, names_input)
            with h5py.File(names_input, "r+") as hdf5:
                del hdf5["polycube_info/names"]
                hdf5["polycube_info"].create_dataset(
                    "names", data=malformed_names
                )
            names_hash = file_sha256(names_input)
            container_names_dir = container_test_dir / names_dir.name
            names_yaml = names_dir / "run_config.yaml"
            write_stage_yaml(
                names_yaml,
                container_names_dir / names_input.name,
                container_names_dir,
                "discretization",
            )
            names_output = run_hex(
                repo_root,
                args.image,
                names_dir / "log.txt",
                container_names_dir / names_yaml.name,
                expected_success=False,
            )
            if expected_message not in names_output:
                raise AssertionError(
                    f"malformed names {case_name} was not rejected:\n"
                    f"{names_output}"
                )
            if file_sha256(names_input) != names_hash:
                raise AssertionError(
                    f"malformed names {case_name} modified its input"
                )
            if (names_dir / "stage_2_discretization.hdf5").exists():
                raise AssertionError(
                    f"malformed names {case_name} created an output"
                )
        print("PASS: malformed fixed-width polycube names rejected")

        stage_outputs: dict[int, Path] = {}
        for stage_index, stage_name in STAGES:
            case_dir = test_dir / f"stage_{stage_index}_{stage_name}"
            case_dir.mkdir()

            # Every stage after Stage 0 consumes the preceding test output.
            # This proves each freshly generated cumulative snapshot remains a
            # valid input for the rest of the pipeline.
            source = fixture if stage_index == 0 else stage_outputs[stage_index - 1]
            test_input = case_dir / "input.hdf5"
            prepare_corrupt_input(source, test_input, stage_index)
            input_hash = file_sha256(test_input)

            container_case_dir = container_test_dir / case_dir.name
            yaml_path = case_dir / "run_config.yaml"
            write_stage_yaml(
                yaml_path,
                container_case_dir / test_input.name,
                container_case_dir,
                stage_name,
            )
            run_hex(
                repo_root,
                args.image,
                case_dir / "log.txt",
                container_case_dir / yaml_path.name,
            )

            if file_sha256(test_input) != input_hash:
                raise AssertionError(f"stage {stage_index} modified its input file")
            stage_output = case_dir / f"stage_{stage_index}_{stage_name}.hdf5"
            if not stage_output.is_file():
                raise AssertionError(f"missing output: {stage_output}")
            assert_snapshot(
                stage_output,
                test_input,
                stage_index,
                expected_scale,
                expected_center,
            )
            stage_outputs[stage_index] = stage_output
            print(f"PASS: stage {stage_index} {stage_name} restart boundary")

            if stage_index == 1:
                # A decomposition snapshot has no polycube_complex. Stage 3
                # must require the missing Stage-2 discretization output rather
                # than attempting to run with incomplete state.
                missing_stage_dir = test_dir / "stage_1_to_stage_3_rejected"
                missing_stage_dir.mkdir()
                missing_stage_input = missing_stage_dir / "input.hdf5"
                shutil.copy2(stage_output, missing_stage_input)
                missing_stage_hash = file_sha256(missing_stage_input)
                container_missing_stage_dir = (
                    container_test_dir / missing_stage_dir.name
                )
                missing_stage_yaml = missing_stage_dir / "run_config.yaml"
                write_stage_yaml(
                    missing_stage_yaml,
                    container_missing_stage_dir / missing_stage_input.name,
                    container_missing_stage_dir,
                    "hexahedralization",
                )
                missing_stage_output = run_hex(
                    repo_root,
                    args.image,
                    missing_stage_dir / "log.txt",
                    container_missing_stage_dir / missing_stage_yaml.name,
                    expected_success=False,
                )
                if "hexahedralization requires" not in missing_stage_output:
                    raise AssertionError(
                        "Stage-1 input was not rejected for Stage 3:\n"
                        f"{missing_stage_output}"
                    )
                if "polycube_complex" not in missing_stage_output:
                    raise AssertionError(
                        "Stage-3 prerequisite error did not name "
                        "polycube_complex"
                    )
                if file_sha256(missing_stage_input) != missing_stage_hash:
                    raise AssertionError(
                        "failed Stage-1 to Stage-3 run modified its input"
                    )
                if (missing_stage_dir / "stage_3_hexahedralization.hdf5").exists():
                    raise AssertionError(
                        "failed Stage-1 to Stage-3 run created an output"
                    )
                print("PASS: Stage-1 input rejected for Stage 3")

        if file_sha256(fixture) != fixture_hash:
            raise AssertionError("source fixture was modified")

        success = True
        print("PASS: source HDF5 unchanged")
        print("PASS: all fresh stage restart regressions")
        return 0
    finally:
        if success and not args.keep_temp:
            shutil.rmtree(test_dir)
        else:
            print(f"test artifacts: {test_dir}", file=sys.stderr)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
