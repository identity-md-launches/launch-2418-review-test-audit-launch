#!/usr/bin/env python3
"""Run unchanged admission floors from IMD's pinned public launch example, without RPC or signing."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PIN = "b810098c73b7de0cf08257aa01a08b279e965c7f"
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path,
                        help="Local clone of identity-md-launches/launch-2255-launch-curb-curb-uniswap.")
    parser.add_argument("--forge", default="forge")
    parser.add_argument("--cast", default="cast")
    parser.add_argument("--solc", default="0.8.26")
    args = parser.parse_args()
    reference = args.reference.resolve()
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=reference, text=True).strip()
    if actual != PIN:
        raise SystemExit(f"Reference must be pinned at {PIN}; got {actual}.")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=reference, text=True).strip():
        raise SystemExit("Reference checkout has changes; admission floors must stay unchanged.")
    build = ["--use", args.solc, "--offline"]
    def command(*values):
        return subprocess.check_output(values, cwd=ROOT, text=True).strip()
    hook = command(args.forge, "inspect", "IMDPhysicalHook", "bytecode", *build)
    token = command(args.forge, "inspect", "IMDirectorToken", "bytecode", *build)
    constructor = command(args.cast, "abi-encode", "constructor(address,address)",
                          "0x000000000000000000000000000000000000D35C",
                          "0x000000000000000000000000000000000000FaC7")
    env = os.environ.copy()
    env.update(FOUNDRY_FFI="false", IMD_HOOK_CREATION_CODE=hook + constructor[2:],
               IMD_TOKEN_CREATION_CODE=token, IMD_HOOK_FLAGS="0x2040", IMD_HOOK_NAME="IMDPhysicalHook",
               IMD_PROJECT_CHAIN_ID="4663", IMD_PAIRED_CURRENCY="0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127",
               IMD_POOL_MANAGER="0x8366a39cc670b4001a1121b8f6a443a643e40951",
               IMD_FACTORY_PROBE="0x000000000000000000000000000000000000FaC7",
               IMD_POOL_FEE="12500", IMD_TICK_SPACING="60", IMD_EXPECTED_SUPPLY=str(10**27),
               IMD_TOKEN_DECIMALS="18")
    with tempfile.TemporaryDirectory(prefix="imdirector-admission-") as name:
        floor = Path(name)
        (floor / "src").mkdir()
        shutil.copy2(reference / "src/HookFlags.sol", floor / "src/HookFlags.sol")
        shutil.copytree(reference / "test/protected", floor / "test/protected")
        (floor / "lib").symlink_to(reference / "lib", target_is_directory=True)
        remappings = (reference / "remappings.txt").read_text().splitlines()
        (floor / "foundry.toml").write_text(
            '[profile.default]\nsrc="src"\ntest="test/protected"\nlibs=["lib"]\n'
            'solc="0.8.26"\nevm_version="cancun"\noptimizer=true\noptimizer_runs=200\n'
            'via_ir=true\nbytecode_hash="none"\nffi=false\nauto_detect_remappings=false\n'
            + "remappings=" + json.dumps(remappings) + "\n")
        for order, probe, price in [
            ("below", "0x00000000000000000000000000000000000070CE", "125270724187523965593206900"),
            ("above", "0xffffffffffffffffffffffffffffffffffffffff", "50108289675009586237282760313921")
        ]:
            env.update(IMD_TOKEN_PROBE=probe, IMD_SQRT_PRICE=price)
            result = subprocess.run([args.forge, "test", "--root", str(floor), *build, "-vv"],
                                    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            print(f"Published admission floor, token {order} IMD:\n{result.stdout}", flush=True)
            if result.returncode or "13 tests passed, 0 failed, 0 skipped" not in result.stdout:
                raise SystemExit("Admission floor did not pass all 13 checks without skips.")


if __name__ == "__main__":
    main()
