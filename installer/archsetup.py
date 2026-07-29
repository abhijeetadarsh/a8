#!/usr/bin/env python3
"""
archsetup.py - an interactive, nothing-hardcoded Arch Linux installer.

This installs only the SYSTEM layer of Arch: partitions, base + kernel +
firmware + microcode, locale, users, bootloader, initramfs, GPU drivers and
networking. It does NOT install a desktop, apps or dotfiles - those are managed
declaratively with Nix / home-manager after the first boot. The installer sets
up Nix (daemon + flakes) and drops a starter ~/.config/home-manager you edit
and apply with `home-manager switch`.

Run this from the Arch ISO live environment (python ships on the ISO):

    # loadkeys us                       # only if you need another console keymap
    # iwctl                             # or let the script walk you through wifi
    # curl -LO http://<host>/archsetup.py     (or copy it off a USB stick)
    # python archsetup.py

Every decision is asked, nothing about your machine is assumed. Answers are
saved to /root/archsetup-answers.json and can be replayed with --config for a
repeat install (passwords are never written to disk and are always re-asked).

    python archsetup.py --dry-run              # walk the whole flow, touch nothing
    python archsetup.py --config answers.json  # replay previous answers

Nothing is formatted before you have seen a full summary and typed INSTALL.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from datetime import datetime
from getpass import getpass

MNT = "/mnt"
LOGFILE = "/tmp/archsetup.log"
ANSWERS_PATH = "/root/archsetup-answers.json"

DRY_RUN = False
PRESET: dict = {}
CFG: dict = {}
SECRETS: dict = {}


# ----------------------------------------------------------------------------
# output / logging
# ----------------------------------------------------------------------------

class C:
    if sys.stdout.isatty():
        R = "\033[0m"; B = "\033[1m"; DIM = "\033[2m"
        RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"
        BLU = "\033[34m"; MAG = "\033[35m"; CYA = "\033[36m"
    else:
        R = B = DIM = RED = GRN = YEL = BLU = MAG = CYA = ""


def log(msg: str) -> None:
    try:
        with open(LOGFILE, "a") as fh:
            fh.write(f"{datetime.now().strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def say(msg: str = "") -> None:
    print(msg)
    log(f"| {msg}")


def info(msg: str) -> None:
    say(f"{C.CYA}::{C.R} {msg}")


def ok(msg: str) -> None:
    say(f"{C.GRN}==>{C.R} {msg}")


def warn(msg: str) -> None:
    say(f"{C.YEL}!!{C.R} {msg}")


def err(msg: str) -> None:
    say(f"{C.RED}xx{C.R} {msg}")


def header(msg: str) -> None:
    say()
    say(f"{C.B}{C.BLU}{'-' * 72}{C.R}")
    say(f"{C.B}{C.BLU}  {msg}{C.R}")
    say(f"{C.B}{C.BLU}{'-' * 72}{C.R}")


def die(msg: str, code: int = 1):
    if code == 0:
        info(msg)
    else:
        err(msg)
        say(f"{C.DIM}full log: {LOGFILE}{C.R}")
    sys.exit(code)


# ----------------------------------------------------------------------------
# command execution
# ----------------------------------------------------------------------------

def run(cmd, *, check: bool = True, capture: bool = False, stdin_text: str | None = None,
        dry_ok: bool = False, quiet: bool = False) -> subprocess.CompletedProcess:
    """Run a command. dry_ok=True marks a read-only command that is safe to
    execute even during --dry-run."""
    if isinstance(cmd, str):
        args = ["bash", "-o", "pipefail", "-c", cmd]
        shown = cmd
    else:
        args = [str(a) for a in cmd]
        shown = " ".join(shlex.quote(a) for a in args)

    log(f"$ {shown}")
    if DRY_RUN and not dry_ok:
        if not quiet:
            say(f"{C.DIM}   [dry-run] {shown}{C.R}")
        return subprocess.CompletedProcess(args, 0, "", "")

    if not quiet and not capture:
        say(f"{C.DIM}   $ {shown}{C.R}")

    proc = subprocess.run(
        args,
        input=stdin_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if capture:
        log(f"  out: {(proc.stdout or '').strip()[:2000]}")
        if proc.stderr:
            log(f"  err: {proc.stderr.strip()[:2000]}")
    if check and proc.returncode != 0:
        if capture and proc.stderr:
            err(proc.stderr.strip())
        die(f"command failed (exit {proc.returncode}): {shown}")
    return proc


def out(cmd, default: str = "") -> str:
    """Read-only command; returns stripped stdout, or `default` on failure."""
    p = run(cmd, check=False, capture=True, dry_ok=True, quiet=True)
    return (p.stdout or default).strip() if p.returncode == 0 else default


def chroot_run(cmd: str, *, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
    return run(["arch-chroot", MNT, "bash", "-o", "pipefail", "-c", cmd], check=check, quiet=quiet)


def chroot_user(user: str, cmd: str, *, check: bool = True) -> subprocess.CompletedProcess:
    return run(["arch-chroot", MNT, "sudo", "-u", user, "bash", "-o", "pipefail", "-c", cmd],
               check=check)


def write_target(relpath: str, content: str, *, mode: int | None = None,
                 append: bool = False) -> None:
    """Write a file inside the installed system (relpath is relative to /)."""
    path = os.path.join(MNT, relpath.lstrip("/"))
    log(f"WRITE {path}\n{content}")
    if DRY_RUN:
        say(f"{C.DIM}   [dry-run] write {path} ({len(content)} bytes){C.R}")
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a" if append else "w") as fh:
        fh.write(content)
    if mode is not None:
        os.chmod(path, mode)
    say(f"{C.DIM}   wrote {path}{C.R}")


def read_target(relpath: str) -> str:
    try:
        with open(os.path.join(MNT, relpath.lstrip("/"))) as fh:
            return fh.read()
    except OSError:
        return ""


def sub_in_target(relpath: str, pattern: str, repl: str, *, count: int = 0) -> None:
    text = read_target(relpath)
    if not text:
        if DRY_RUN:
            say(f"{C.DIM}   [dry-run] patch {relpath}: {pattern} -> {repl}{C.R}")
        else:
            warn(f"cannot patch {relpath}: file missing or empty")
        return
    new = re.sub(pattern, repl, text, count=count, flags=re.MULTILINE)
    if new != text:
        write_target(relpath, new)
    else:
        log(f"no change in {relpath} for pattern {pattern}")


# ----------------------------------------------------------------------------
# prompts
# ----------------------------------------------------------------------------

def _input(prompt: str) -> str:
    try:
        return input(prompt)
    except EOFError:
        die("stdin closed - this installer needs an interactive terminal")
    except KeyboardInterrupt:
        say()
        die("aborted by user", 130)
    return ""


def ask_text(question: str, default: str | None = None, *, allow_empty: bool = False,
             validate=None, hint: str | None = None) -> str:
    if hint:
        say(f"{C.DIM}   {hint}{C.R}")
    suffix = f" [{C.B}{default}{C.R}]" if default else ""
    while True:
        val = _input(f"{C.MAG}?{C.R} {question}{suffix}: ").strip()
        if not val and default is not None:
            val = default
        if not val and not allow_empty:
            warn("a value is required")
            continue
        if validate and val:
            problem = validate(val)
            if problem:
                warn(problem)
                continue
        return val


def ask_bool(question: str, default: bool = True) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    while True:
        val = _input(f"{C.MAG}?{C.R} {question} {suffix}: ").strip().lower()
        if not val:
            return default
        if val in ("y", "yes"):
            return True
        if val in ("n", "no"):
            return False
        warn("answer y or n")


def ask_choice(question: str, options: list[tuple[str, str]], default: str | None = None) -> str:
    """options: list of (value, label). Returns the chosen value."""
    say()
    say(f"{C.MAG}?{C.R} {C.B}{question}{C.R}")
    for i, (value, label) in enumerate(options, 1):
        mark = f"{C.GRN}*{C.R}" if value == default else " "
        say(f"  {mark} {C.B}{i:2d}{C.R}) {label}")
    default_idx = next((i for i, (v, _) in enumerate(options, 1) if v == default), None)
    suffix = f" [{default_idx}]" if default_idx else ""
    while True:
        raw = _input(f"  choice{suffix}: ").strip()
        if not raw and default_idx:
            return options[default_idx - 1][0]
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return options[int(raw) - 1][0]
        warn(f"enter a number between 1 and {len(options)}")


def ask_multi(question: str, options: list[tuple[str, str, bool]]) -> list[str]:
    """options: list of (value, label, default_on). Returns the chosen values."""
    selected = {v for v, _, on in options if on}
    say()
    say(f"{C.MAG}?{C.R} {C.B}{question}{C.R}")
    say(f"{C.DIM}   toggle with numbers ('1 3 5' or '2-4'), 'all', 'none';"
        f" empty line accepts the selection{C.R}")
    while True:
        for i, (value, label, _) in enumerate(options, 1):
            box = f"{C.GRN}[x]{C.R}" if value in selected else "[ ]"
            say(f"  {box} {C.B}{i:2d}{C.R}) {label}")
        raw = _input("  toggle: ").strip().lower()
        if not raw:
            return [v for v, _, _ in options if v in selected]
        if raw == "all":
            selected = {v for v, _, _ in options}
            say()
            continue
        if raw == "none":
            selected = set()
            say()
            continue
        bad = False
        for token in raw.replace(",", " ").split():
            if "-" in token and all(p.isdigit() for p in token.split("-", 1)):
                a, b = (int(p) for p in token.split("-", 1))
                idxs = list(range(a, b + 1))
            elif token.isdigit():
                idxs = [int(token)]
            else:
                bad = True
                break
            for i in idxs:
                if not 1 <= i <= len(options):
                    bad = True
                    break
                selected.symmetric_difference_update({options[i - 1][0]})
        if bad:
            warn("could not parse that selection")
        say()


def ask_password(label: str) -> str:
    while True:
        a = getpass(f"{C.MAG}?{C.R} {label} password: ")
        if not a:
            warn("empty passwords are not allowed here")
            continue
        b = getpass(f"{C.MAG}?{C.R} repeat {label} password: ")
        if a != b:
            warn("passwords do not match, try again")
            continue
        return a


def answer(key: str, ask_fn, describe=None):
    """Ask a question, unless a --config preset already answers it."""
    if key in PRESET:
        val = PRESET[key]
        say(f"{C.DIM}   [preset] {key} = {describe(val) if describe else val}{C.R}")
    else:
        val = ask_fn()
    CFG[key] = val
    return val


def save_answers() -> None:
    try:
        with open(ANSWERS_PATH, "w") as fh:
            json.dump(CFG, fh, indent=2, sort_keys=True)
        log(f"answers saved to {ANSWERS_PATH}")
    except OSError as exc:
        log(f"could not save answers: {exc}")


# ----------------------------------------------------------------------------
# system detection
# ----------------------------------------------------------------------------

def is_uefi() -> bool:
    return os.path.isdir("/sys/firmware/efi/efivars")


def cpu_vendor() -> str:
    try:
        with open("/proc/cpuinfo") as fh:
            txt = fh.read()
    except OSError:
        return "unknown"
    if "GenuineIntel" in txt:
        return "intel"
    if "AuthenticAMD" in txt:
        return "amd"
    return "unknown"


def detect_virt() -> str:
    return out("systemd-detect-virt", "none") or "none"


def is_laptop() -> bool:
    psu = "/sys/class/power_supply"
    if os.path.isdir(psu) and any(n.startswith("BAT") for n in os.listdir(psu)):
        return True
    return out("hostnamectl chassis") in ("laptop", "handset", "tablet", "convertible")


def detect_gpus() -> list[str]:
    text = out("lspci -nn | grep -Ei 'vga|3d controller|display controller'").lower()
    found = []
    if "nvidia" in text:
        found.append("nvidia")
    if any(k in text for k in ("amd", "advanced micro devices", "radeon", "ati ")):
        found.append("amd")
    if "intel" in text:
        found.append("intel")
    return found


def lsblk_tree() -> dict:
    raw = out("lsblk -J -b -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,"
              "MOUNTPOINTS,MODEL,RM,RO,PKNAME")
    try:
        return json.loads(raw) if raw else {"blockdevices": []}
    except json.JSONDecodeError:
        return {"blockdevices": []}


def human(size) -> str:
    try:
        size = float(size)
    except (TypeError, ValueError):
        return "?"
    for unit in ("B", "K", "M", "G", "T", "P"):
        if size < 1024 or unit == "P":
            return f"{size:.1f}{unit}"
        size /= 1024
    return "?"


def flatten_devices(nodes=None, acc=None, parent=None) -> list[dict]:
    if acc is None:
        acc = []
    if nodes is None:
        nodes = lsblk_tree().get("blockdevices", [])
    for node in nodes:
        node["_parent"] = parent
        acc.append(node)
        flatten_devices(node.get("children") or [], acc, node)
    return acc


def all_disks() -> list[dict]:
    return [d for d in flatten_devices() if d.get("type") == "disk"]


def all_partitions() -> list[dict]:
    return [d for d in flatten_devices()
            if d.get("type") in ("part", "lvm", "crypt", "md", "raid1")]


def mountpoints_of(dev: dict) -> list[str]:
    return [m for m in (dev.get("mountpoints") or []) if m]


def describe_dev(dev: dict) -> str:
    bits = [f"{C.B}{(dev.get('path') or '?'):<16}{C.R}", f"{human(dev.get('size')):>9}",
            f"{(dev.get('fstype') or '-'):<8}"]
    label = dev.get("label") or dev.get("partlabel") or ""
    if label:
        bits.append(f"label={label}")
    mounts = mountpoints_of(dev)
    if mounts:
        bits.append(f"{C.YEL}mounted:{','.join(mounts)}{C.R}")
    if dev.get("model"):
        bits.append(str(dev["model"]))
    return "  ".join(bits)


def fstype_of(path: str) -> str:
    """Filesystem type of a device. Uses lsblk, which - unlike blkid - also
    answers when the script is exercised without root (--dry-run)."""
    lines = out(f"lsblk -no FSTYPE {shlex.quote(path)}").splitlines()
    return lines[0].strip() if lines else ""


def blk_uuid(path: str, tag: str = "UUID") -> str:
    val = out(f"blkid -s {tag} -o value {shlex.quote(path)}")
    if not val:
        if not DRY_RUN:
            warn(f"could not read {tag} of {path} - the bootloader entry may be wrong")
        return f"<{tag}-of-{os.path.basename(path)}>"
    return val


def parent_disk_of(part_path: str) -> str:
    name = out(f"lsblk -no PKNAME {shlex.quote(part_path)}").splitlines()
    return f"/dev/{name[0].strip()}" if name and name[0].strip() else part_path


def looks_like_windows_esp(path: str) -> bool:
    if fstype_of(path) not in ("vfat", "fat32", "fat16"):
        return False
    probe = "/tmp/archsetup-esp-probe"
    try:
        os.makedirs(probe, exist_ok=True)
    except OSError:
        return False
    if subprocess.run(["mount", "-o", "ro", path, probe], capture_output=True).returncode != 0:
        return False
    try:
        return os.path.isdir(os.path.join(probe, "EFI", "Microsoft"))
    finally:
        subprocess.run(["umount", probe], capture_output=True)


# ----------------------------------------------------------------------------
# catalog
# ----------------------------------------------------------------------------

KERNELS = [
    ("linux", "linux - mainline stock kernel (recommended)"),
    ("linux-lts", "linux-lts - long term support, most conservative"),
    ("linux-zen", "linux-zen - desktop responsiveness tuning"),
    ("linux-hardened", "linux-hardened - security focused"),
]

FILESYSTEMS = [
    ("btrfs", "btrfs - snapshots, compression, subvolumes (recommended)"),
    ("ext4", "ext4 - boring and bulletproof"),
    ("xfs", "xfs - good with large files"),
    ("f2fs", "f2fs - flash friendly"),
]

FS_TOOLS = {"btrfs": ["btrfs-progs"], "ext4": ["e2fsprogs"],
            "xfs": ["xfsprogs"], "f2fs": ["f2fs-tools"]}

BTRFS_SUBVOLS = [
    ("@", "/"),
    ("@home", "/home"),
    ("@log", "/var/log"),
    ("@pkg", "/var/cache/pacman/pkg"),
    ("@snapshots", "/.snapshots"),
]

GPU_PACKAGES = {
    "intel": ["mesa", "vulkan-intel", "intel-media-driver", "libva-utils"],
    "amd": ["mesa", "vulkan-radeon", "libva-utils"],
    "nvidia-open": ["nvidia-open-dkms", "nvidia-utils", "nvidia-settings", "egl-wayland"],
    "nvidia-proprietary": ["nvidia-dkms", "nvidia-utils", "nvidia-settings", "egl-wayland"],
    "nouveau": ["mesa", "xf86-video-nouveau"],
    "vm": ["mesa", "xf86-video-vmware"],
    "none": ["mesa"],
}


# ----------------------------------------------------------------------------
# step 1 - preflight, network, mirrors
# ----------------------------------------------------------------------------

def step_preflight() -> None:
    header("preflight checks")

    if os.geteuid() != 0 and not DRY_RUN:
        die("this installer must run as root, from the Arch installation ISO")
    if not shutil.which("pacstrap") and not DRY_RUN:
        die("pacstrap not found - are you running from the Arch installation ISO?")

    gpus = detect_gpus()
    info(f"firmware       : {'UEFI' if is_uefi() else 'BIOS (legacy / CSM)'}")
    info(f"cpu vendor     : {cpu_vendor()}")
    info(f"virtualisation : {detect_virt()}")
    info(f"chassis        : {'laptop' if is_laptop() else 'desktop / unknown'}")
    info(f"gpu(s)         : {', '.join(gpus) if gpus else 'none detected'}")
    info(f"log file       : {LOGFILE}")

    CFG["_detected"] = {"uefi": is_uefi(), "cpu": cpu_vendor(), "virt": detect_virt(),
                        "gpus": gpus, "laptop": is_laptop()}
    if DRY_RUN:
        warn("DRY RUN: no disk will be touched and no package will be installed")


def step_network() -> None:
    header("network")

    def online() -> bool:
        return run("ping -c1 -W3 archlinux.org", check=False, capture=True,
                   dry_ok=True, quiet=True).returncode == 0

    if online():
        ok("already online")
    else:
        warn("cannot reach archlinux.org yet")
        say()
        say("  wired    : usually automatic - check the cable, or run `dhcpcd`")
        say("  wifi     : run `iwctl`, then:")
        say("               device list")
        say("               station wlan0 scan")
        say("               station wlan0 get-networks")
        say("               station wlan0 connect <SSID>")
        say("               exit")
        say("  phone    : plug it in and turn on USB tethering")
        while not online():
            choice = ask_choice("network is down - what now?", [
                ("iwctl", "open iwctl now (wifi)"),
                ("shell", "drop me to a shell, I will sort it out"),
                ("retry", "retry the connectivity check"),
                ("skip", "continue anyway (the install will very likely fail)"),
            ], default="iwctl")
            if choice == "iwctl":
                run("iwctl", check=False, dry_ok=True)
            elif choice == "shell":
                say("type `exit` to return to the installer")
                run("bash", check=False, dry_ok=True)
            elif choice == "skip":
                warn("continuing without verified connectivity")
                return
        ok("online")

    run("timedatectl set-ntp true", check=False)


def step_mirrors() -> None:
    header("package mirrors")

    if not answer("mirrors_rank", lambda: ask_bool(
            "rank mirrors with reflector before installing? (recommended)", True)):
        return
    if not shutil.which("reflector") and not DRY_RUN:
        warn("reflector is not on this ISO - keeping the shipped mirrorlist")
        return

    country = answer("mirrors_country", lambda: ask_text(
        "mirror country (blank = worldwide, comma separated for several)",
        default="", allow_empty=True,
        hint="examples: India | Germany | 'United States' | India,Singapore"))

    cmd = ["reflector", "--protocol", "https", "--latest", "20", "--sort", "rate",
           "--save", "/etc/pacman.d/mirrorlist"]
    for c in [c.strip() for c in country.split(",") if c.strip()]:
        cmd += ["--country", c]

    info("ranking mirrors, this can take a minute...")
    if run(cmd, check=False).returncode != 0:
        warn("reflector failed - keeping the ISO mirrorlist")
    else:
        ok("mirrorlist updated")

    run("sed -i 's/^#\\?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf", check=False)
    run("pacman -Sy --noconfirm archlinux-keyring", check=False)


# ----------------------------------------------------------------------------
# step 2 - disks
# ----------------------------------------------------------------------------

def show_block_devices() -> None:
    say()
    say(out("lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS"))
    say()


def pick_partition(question: str, *, allow_none: bool = False, none_label: str = "none",
                   exclude: list[str] | None = None,
                   prefer_fstype: str | None = None) -> str | None:
    exclude = [e for e in (exclude or []) if e]
    parts = [p for p in all_partitions() if p.get("path") not in exclude]
    if not parts:
        die("no partitions found - create them first (cfdisk / gdisk) and run this again")

    options: list[tuple[str, str]] = []
    default = None
    for p in parts:
        options.append((p["path"], describe_dev(p)))
        if prefer_fstype and default is None and p.get("fstype") == prefer_fstype:
            default = p["path"]
    if allow_none:
        options.append(("__none__", none_label))
        if default is None:
            default = "__none__"

    choice = ask_choice(question, options, default=default)
    return None if choice == "__none__" else choice


def auto_partition_disk() -> None:
    """Guided wipe-and-repartition of a whole disk. Only on explicit confirmation."""
    disks = all_disks()
    if not disks:
        die("no disks detected")
    target = ask_choice("which disk should be wiped and repartitioned?",
                        [(d["path"], describe_dev(d)) for d in disks])

    say()
    warn(f"EVERYTHING on {target} will be destroyed, including any other OS on it.")
    say(out(f"lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS {shlex.quote(target)}"))
    if _input(f"{C.RED}type the disk path exactly to confirm:{C.R} ").strip() != target:
        info("cancelled, nothing was written")
        return

    esp_size = ask_text("EFI system partition size", default="1G") if is_uefi() else None
    swap_size = ask_text("swap partition size (0 or blank = no swap partition)",
                         default="0", allow_empty=True)
    root_size = ask_text("root partition size (blank = rest of the disk)",
                         default="", allow_empty=True)

    run(["wipefs", "-a", target])
    run(["sgdisk", "--zap-all", target])
    idx = 1
    if is_uefi():
        run(["sgdisk", "-n", f"{idx}:0:+{esp_size}", "-t", f"{idx}:ef00", "-c", f"{idx}:EFI", target])
    else:
        run(["sgdisk", "-n", f"{idx}:0:+1M", "-t", f"{idx}:ef02", "-c", f"{idx}:BIOSBOOT", target])
    idx += 1
    if swap_size.strip() and swap_size.strip() not in ("0", "0G", "0M"):
        run(["sgdisk", "-n", f"{idx}:0:+{swap_size}", "-t", f"{idx}:8200", "-c", f"{idx}:swap", target])
        idx += 1
    end = f"+{root_size}" if root_size.strip() else "0"
    run(["sgdisk", "-n", f"{idx}:0:{end}", "-t", f"{idx}:8300", "-c", f"{idx}:root", target])
    run(["partprobe", target], check=False)
    run("udevadm settle", check=False)
    ok(f"{target} repartitioned")
    show_block_devices()


def step_disks() -> None:
    header("disks and partitions")
    show_block_devices()

    while True:
        action = ask_choice("how do you want to prepare the disk?", [
            ("use", "use partitions that already exist (right choice for dual boot)"),
            ("edit", "open a partition editor first (cfdisk / gdisk / fdisk / parted)"),
            ("auto", "wipe a whole disk and let the installer partition it"),
            ("show", "show me lsblk again"),
        ], default="use")

        if action == "use":
            break
        if action == "show":
            show_block_devices()
            continue
        if action == "auto":
            auto_partition_disk()
            continue

        disks = all_disks()
        disk = ask_choice("which disk do you want to edit?",
                          [(d["path"], describe_dev(d)) for d in disks])
        tool = ask_choice("which editor?", [
            ("cfdisk", "cfdisk - simple curses UI (recommended)"),
            ("gdisk", "gdisk - GPT expert tool"),
            ("fdisk", "fdisk"),
            ("parted", "parted"),
        ], default="cfdisk")
        run([tool, disk], check=False, dry_ok=True)
        run(["partprobe", disk], check=False)
        run("udevadm settle", check=False)
        show_block_devices()

    # --- root ---------------------------------------------------------------
    root = answer("part_root", lambda: pick_partition("which partition becomes ROOT (/)?"))
    if not root:
        die("a root partition is required")

    # --- efi ----------------------------------------------------------------
    esp = None
    if is_uefi():
        esp = answer("part_esp", lambda: pick_partition(
            "which partition is the EFI System Partition?",
            prefer_fstype="vfat", exclude=[root]))
        if not esp:
            die("UEFI boot needs an EFI system partition")
    else:
        info("legacy BIOS boot: GRUB goes into a disk's MBR, no ESP needed")
    CFG["part_root"] = root
    CFG["part_esp"] = esp

    # --- swap ---------------------------------------------------------------
    swap_kind = answer("swap_kind", lambda: ask_choice("swap?", [
        ("partition", "use an existing swap partition"),
        ("zram", "zram - compressed swap in RAM (great default, uses no disk)"),
        ("file", "swap file on the root filesystem"),
        ("none", "no swap"),
    ], default="partition"))

    swap_part = None
    if swap_kind == "partition":
        swap_part = answer("part_swap", lambda: pick_partition(
            "which partition is swap?", prefer_fstype="swap",
            allow_none=True, none_label="actually, no swap partition",
            exclude=[root, esp]))
        if not swap_part:
            CFG["swap_kind"] = swap_kind = "none"
    CFG["part_swap"] = swap_part

    if swap_kind == "file":
        answer("swap_size", lambda: ask_text(
            "swap file size", default="8G",
            hint="rule of thumb: at least as much as your RAM if you want hibernation"))
    if swap_kind == "zram":
        answer("zram_size", lambda: ask_text(
            "zram size expression", default="min(ram / 2, 8192)",
            hint="this goes verbatim into /etc/systemd/zram-generator.conf"))

    # --- separate /home -----------------------------------------------------
    home_part = None
    if answer("home_separate", lambda: ask_bool("use a separate partition for /home?", False)):
        home_part = answer("part_home", lambda: pick_partition(
            "which partition becomes /home?", exclude=[root, esp, swap_part]))
    CFG["part_home"] = home_part

    # --- extra data mounts (shared NTFS drive, second SSD, ...) -------------
    if answer("extra_mounts_enable", lambda: ask_bool(
            "auto-mount any other partitions at boot (data drive, Windows drive)?", False)):
        if "extra_mounts" in PRESET:
            CFG["extra_mounts"] = PRESET["extra_mounts"]
            for m in CFG["extra_mounts"]:
                say(f"{C.DIM}   [preset] {m['path']} -> {m['mountpoint']}{C.R}")
        else:
            extras: list[dict] = []
            used = [root, esp, swap_part, home_part]
            while True:
                part = pick_partition("which partition should be mounted at boot?",
                                      allow_none=True,
                                      none_label="done, no more partitions",
                                      exclude=used)
                if not part:
                    break
                fstype = fstype_of(part) or "auto"
                label = out(f"lsblk -no LABEL {shlex.quote(part)}").splitlines()
                name = (label[0].strip().lower().replace(" ", "-")
                        if label and label[0].strip() else os.path.basename(part))
                mp = ask_text(f"mountpoint for {part} ({fstype})", default=f"/mnt/{name}")
                extras.append({"path": part, "fstype": fstype, "mountpoint": mp})
                used.append(part)
            CFG["extra_mounts"] = extras
    else:
        CFG["extra_mounts"] = []

    # --- filesystem ---------------------------------------------------------
    fs = answer("root_fs", lambda: ask_choice(
        "filesystem for the root partition", FILESYSTEMS, default="btrfs"))

    if fs == "btrfs":
        answer("btrfs_subvolumes", lambda: ask_bool(
            "create the standard subvolume layout (@, @home, @log, @pkg, @snapshots)?", True))
        answer("btrfs_compress", lambda: ask_choice("btrfs compression", [
            ("zstd:3", "zstd level 3 (recommended)"),
            ("zstd:1", "zstd level 1 (fastest)"),
            ("lzo", "lzo"),
            ("none", "no compression"),
        ], default="zstd:3"))
    else:
        CFG["btrfs_subvolumes"] = False
        CFG["btrfs_compress"] = "none"

    # --- encryption ---------------------------------------------------------
    if answer("luks_enable", lambda: ask_bool(
            "encrypt the root partition with LUKS2? (passphrase needed at every boot)", False)):
        answer("luks_name", lambda: ask_text(
            "name for the unlocked device (/dev/mapper/<name>)", default="cryptroot"))
        SECRETS["luks"] = ask_password("LUKS")

    # --- formatting decisions ----------------------------------------------
    header("formatting decisions")
    warn("formatting destroys data. Anything you answer 'no' to is left untouched.")

    answer("format_root", lambda: ask_bool(f"format {root} as {fs}?", True))
    if not CFG["format_root"] and not CFG["luks_enable"]:
        warn("reusing the existing root filesystem - make sure it is empty")

    if esp:
        is_win = looks_like_windows_esp(esp)
        already_fat = fstype_of(esp) in ("vfat", "fat32", "fat16")
        if is_win:
            warn(f"{esp} contains /EFI/Microsoft - this ESP is shared with Windows.")
            warn("Formatting it wipes the Windows boot entry. Answer NO unless you mean it.")
        elif already_fat:
            info(f"{esp} already holds a FAT filesystem - it can be reused as it is")
        # never default to destroying an ESP that already carries a filesystem
        answer("format_esp", lambda: ask_bool(
            f"format {esp} as FAT32?", default=not is_win and not already_fat))
        if is_win and CFG["format_esp"]:
            if _input(f"{C.RED}really erase the Windows ESP? type ERASE-ESP to confirm:{C.R} "
                      ).strip() != "ERASE-ESP":
                CFG["format_esp"] = False
                info("keeping the existing ESP")
        answer("esp_mountpoint", lambda: ask_choice(
            "where should the ESP be mounted inside the new system?", [
                ("/boot", "/boot - kernels live on the ESP (required by systemd-boot)"),
                ("/efi", "/efi - kernels stay on root, ESP stays small (GRUB only)"),
            ], default="/boot"))

    if swap_part:
        answer("format_swap", lambda: ask_bool(f"run mkswap on {swap_part}?", True))
    if home_part:
        answer("format_home", lambda: ask_bool(f"format {home_part}?", False))
        if CFG["format_home"]:
            answer("home_fs", lambda: ask_choice("filesystem for /home", FILESYSTEMS, default=fs))

    if swap_kind == "partition" and swap_part:
        answer("hibernate", lambda: ask_bool(
            "set up hibernation to that swap partition (adds the resume hook + resume=)?", False))
    else:
        CFG["hibernate"] = False


# ----------------------------------------------------------------------------
# step 3 - identity, locale, users, pacman
# ----------------------------------------------------------------------------

def valid_timezone(tz: str) -> str | None:
    if os.path.exists(os.path.join("/usr/share/zoneinfo", tz)):
        return None
    return f"unknown timezone '{tz}' - look under /usr/share/zoneinfo (e.g. Asia/Kolkata)"


def valid_locale(loc: str) -> str | None:
    base = loc.split()[0]
    if out(f"grep -c '^#\\?{re.escape(base)} ' /etc/locale.gen", "0") != "0":
        return None
    return f"'{base}' does not appear in /etc/locale.gen"


def valid_keymap(km: str) -> str | None:
    keymaps = out("localectl list-keymaps").splitlines()
    if not keymaps or km in keymaps:
        return None
    return f"unknown keymap '{km}' - see `localectl list-keymaps`"


def valid_hostname(name: str) -> str | None:
    if re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", name):
        return None
    return "lowercase letters, digits and dashes only"


def valid_username(name: str) -> str | None:
    if re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", name):
        return None
    return "lowercase, starts with a letter or underscore, max 32 characters"


def step_system() -> None:
    header("system identity and locale")

    answer("timezone", lambda: ask_text(
        "timezone", default=out("timedatectl show -p Timezone --value") or "UTC",
        validate=valid_timezone,
        hint="Region/City, e.g. Asia/Kolkata, Europe/Berlin, America/New_York"))

    answer("locale", lambda: ask_text(
        "primary locale", default="en_US.UTF-8", validate=valid_locale,
        hint="this becomes LANG= in /etc/locale.conf"))

    answer("extra_locales", lambda: ask_text(
        "extra locales to generate (space separated, blank for none)",
        default="", allow_empty=True,
        hint="e.g. 'en_IN.UTF-8 hi_IN.UTF-8' for local date and currency formats"))

    detected_km = out("localectl status | awk -F: '/VC Keymap/{print $2}'").strip()
    if valid_keymap(detected_km) is not None:      # unset, or not a real keymap
        detected_km = "us"
    answer("keymap", lambda: ask_text("console keymap", default=detected_km,
                                      validate=valid_keymap))

    answer("x11_layout", lambda: ask_text(
        "X11 / Wayland keyboard layout", default=CFG["keymap"] if CFG["keymap"].isalpha() else "us",
        hint="e.g. us, de, in, fr - used by the graphical session"))

    answer("hostname", lambda: ask_text("hostname", default="archlinux", validate=valid_hostname))

    header("kernel and firmware")
    answer("kernel", lambda: ask_choice("which kernel?", KERNELS, default="linux"))
    answer("kernel_fallback", lambda: (
        ask_bool("also install linux-lts as a fallback kernel? (good safety net)", True)
        if CFG["kernel"] != "linux-lts" else False))
    answer("firmware", lambda: ask_bool(
        "install linux-firmware? (yes on real hardware)", detect_virt() == "none"))

    cpu = cpu_vendor()
    answer("microcode", lambda: ask_choice("cpu microcode updates", [
        ("intel-ucode", "intel-ucode"),
        ("amd-ucode", "amd-ucode"),
        ("none", "none"),
    ], default={"intel": "intel-ucode", "amd": "amd-ucode"}.get(cpu, "none")))

    header("users")
    answer("root_locked", lambda: ask_bool(
        "lock the root account and use sudo only? (recommended)", True))
    SECRETS["root"] = "" if CFG["root_locked"] else ask_password("root")

    answer("username", lambda: ask_text("your username", validate=valid_username))
    SECRETS["user"] = ask_password(f"user {CFG['username']}")
    answer("user_fullname", lambda: ask_text(
        "full name (blank to skip)", default="", allow_empty=True))
    answer("user_groups", lambda: ask_text(
        "extra groups for this user",
        default="wheel,audio,video,storage,input,optical,network,lp",
        hint="'wheel' is what grants sudo access"))
    answer("sudo_nopasswd", lambda: ask_bool(
        "let wheel use sudo without a password? (convenient, less safe)", False))

    header("pacman")
    answer("multilib", lambda: ask_bool(
        "enable the multilib repo? (needed for steam, wine, 32-bit apps)", True))
    answer("parallel_downloads", lambda: ask_text(
        "pacman parallel downloads", default="10",
        validate=lambda v: None if v.isdigit() and 1 <= int(v) <= 20 else "enter a number 1-20"))
    answer("pacman_candy", lambda: ask_bool("enable the pac-man progress bar?", False))


# ----------------------------------------------------------------------------
# step 4 - bootloader
# ----------------------------------------------------------------------------

def step_bootloader() -> None:
    header("bootloader")

    if is_uefi():
        options = [
            ("grub", "GRUB - most flexible, finds Windows via os-prober (best for dual boot)"),
            ("systemd-boot", "systemd-boot - minimal and fast, needs the ESP at /boot"),
            ("refind", "rEFInd - graphical menu, auto-detects other operating systems"),
        ]
        if CFG.get("esp_mountpoint") == "/efi":
            options = [o for o in options if o[0] != "systemd-boot"]
            info("ESP is at /efi, so systemd-boot is not offered (it needs kernels on the ESP)")
    else:
        options = [("grub", "GRUB - the only sensible choice on legacy BIOS")]

    bl = answer("bootloader", lambda: ask_choice("which bootloader?", options, default="grub"))

    if bl == "grub":
        if not is_uefi():
            answer("grub_bios_disk", lambda: ask_choice(
                "which disk gets the GRUB MBR boot code?",
                [(d["path"], describe_dev(d)) for d in all_disks()],
                default=parent_disk_of(CFG["part_root"])))
        answer("grub_id", lambda: (ask_text("EFI bootloader id / menu entry name", default="Arch")
                                   if is_uefi() else "Arch"))
        answer("os_prober", lambda: ask_bool(
            "enable os-prober so GRUB lists Windows and other installed systems?", True))
        answer("grub_timeout", lambda: ask_text("GRUB menu timeout in seconds", default="5"))
    elif bl == "systemd-boot":
        answer("sdboot_timeout", lambda: ask_text("boot menu timeout in seconds", default="3"))

    answer("quiet_boot", lambda: ask_bool(
        "quiet boot? (adds 'quiet loglevel=3', hides kernel messages)", True))
    answer("extra_cmdline", lambda: ask_text(
        "extra kernel parameters (blank for none)", default="", allow_empty=True,
        hint="e.g. 'acpi_backlight=native' or 'nvidia_drm.fbdev=1'"))


# ----------------------------------------------------------------------------
# step 5 - desktop, drivers, packages
# ----------------------------------------------------------------------------

def step_graphics() -> None:
    # This installer only lays down the system layer. The desktop, apps and
    # dotfiles are managed declaratively with home-manager (Nix) after reboot,
    # so nothing graphical is chosen here except the kernel-level GPU driver -
    # the one thing Nix on Arch cannot install for you.
    CFG.update({"desktop": "none", "display_manager": "none", "terminal": "none",
                "file_manager": "none", "browser": "none", "wm_starter_config": False,
                "editor": "nano", "shell": "bash", "utility_groups": [],
                "enable_sshd": False, "aur_helper": "none", "aur_packages": "",
                "snapshots": False, "timeshift": False, "extra_packages": "",
                "pkg_cache_hook": True})

    header("graphics driver")
    gpus = detect_gpus()
    if gpus:
        info("detected: " + ", ".join(gpus)
             + ("   (hybrid graphics - pick the discrete card, mesa covers the iGPU)"
                if len(gpus) > 1 else ""))
    default_gpu = "none"
    if detect_virt() != "none":
        default_gpu = "vm"
    elif "nvidia" in gpus:
        default_gpu = "nvidia-open"
    elif "amd" in gpus:
        default_gpu = "amd"
    elif "intel" in gpus:
        default_gpu = "intel"

    answer("gpu_driver", lambda: ask_choice("which driver?", [
        ("intel", "intel - mesa + vulkan-intel + media driver"),
        ("amd", "amd - mesa + vulkan-radeon"),
        ("nvidia-open", "nvidia open kernel modules (Turing / RTX 20xx and newer)"),
        ("nvidia-proprietary", "nvidia proprietary dkms (older cards, or if open misbehaves)"),
        ("nouveau", "nouveau - open source nvidia, no cuda, slower"),
        ("vm", "virtual machine guest drivers"),
        ("none", "mesa only / decide later"),
    ], default=default_gpu))


def step_userenv() -> None:
    header("user environment (Nix / home-manager)")

    info("packages, dotfiles and your window manager are managed with home-manager")
    info("after reboot - this only seeds a starter ~/.config/home-manager you then edit")

    answer("nix_wm", lambda: ask_choice(
        "seed the home-manager config with which starter window manager?", [
            ("sway", "sway - Wayland tiling WM (works straight from a tty, no X server)"),
            ("hyprland", "hyprland - Wayland compositor with animations"),
            ("none", "none - just packages + dotfiles, add a WM yourself"),
        ], default="sway"))


# ----------------------------------------------------------------------------
# package list + summary
# ----------------------------------------------------------------------------

def build_package_list() -> list[str]:
    pkgs: list[str] = ["base", "sudo", "nano", "networkmanager", "mkinitcpio"]

    pkgs.append(CFG["kernel"])
    if CFG.get("kernel_fallback"):
        pkgs.append("linux-lts")
    if CFG.get("firmware"):
        pkgs += ["linux-firmware", "sof-firmware"]
    if CFG.get("microcode", "none") != "none":
        pkgs.append(CFG["microcode"])

    pkgs += FS_TOOLS.get(CFG["root_fs"], [])
    if CFG.get("format_home") and CFG.get("home_fs"):
        pkgs += FS_TOOLS.get(CFG["home_fs"], [])
    if is_uefi():
        pkgs += ["efibootmgr", "dosfstools"]
    if CFG.get("luks_enable"):
        pkgs.append("cryptsetup")
    if CFG.get("swap_kind") == "zram":
        pkgs.append("zram-generator")

    if CFG["bootloader"] == "grub":
        pkgs.append("grub")
        if CFG.get("os_prober"):
            pkgs += ["os-prober", "ntfs-3g"]
    elif CFG["bootloader"] == "refind":
        pkgs.append("refind")

    # Nix + the handful of tools needed to bootstrap home-manager on first boot.
    # Everything else (apps, WM, dotfiles) is installed later from home.nix.
    pkgs += ["nix", "git", "curl"]

    gpu = CFG.get("gpu_driver", "none")
    pkgs += GPU_PACKAGES.get(gpu, ["mesa"])
    if gpu.startswith("nvidia"):
        pkgs.append("linux-headers" if CFG["kernel"] == "linux" else f"{CFG['kernel']}-headers")
        if CFG.get("kernel_fallback"):
            pkgs.append("linux-lts-headers")
    if CFG.get("multilib"):
        pkgs += {"intel": ["lib32-mesa", "lib32-vulkan-intel"],
                 "amd": ["lib32-mesa", "lib32-vulkan-radeon"],
                 "nvidia-open": ["lib32-nvidia-utils"],
                 "nvidia-proprietary": ["lib32-nvidia-utils"],
                 "nouveau": ["lib32-mesa"]}.get(gpu, [])

    seen, result = set(), []
    for p in pkgs:
        if p and p not in seen:
            seen.add(p)
            result.append(p)
    return result


def summary_and_confirm() -> None:
    header("summary - read this carefully")

    root, esp = CFG["part_root"], CFG.get("part_esp")
    say(f"  {C.B}firmware{C.R}       : {'UEFI' if is_uefi() else 'BIOS'}")
    say(f"  {C.B}root{C.R}           : {root} -> {CFG['root_fs']}"
        f"{'  (FORMAT)' if CFG.get('format_root') else '  (keep existing filesystem)'}"
        f"{'  + LUKS2' if CFG.get('luks_enable') else ''}"
        f"{'  + subvolumes' if CFG.get('btrfs_subvolumes') else ''}")
    if esp:
        say(f"  {C.B}efi{C.R}            : {esp} -> mounted at {CFG['esp_mountpoint']}"
            f"{'  (FORMAT)' if CFG.get('format_esp') else '  (keep - safe for dual boot)'}")
    if CFG.get("part_home"):
        say(f"  {C.B}home{C.R}           : {CFG['part_home']}"
            f"{'  (FORMAT ' + CFG.get('home_fs', '') + ')' if CFG.get('format_home') else '  (keep)'}")
    swap_desc = {
        "partition": f"{CFG.get('part_swap')}"
                     f"{' (mkswap)' if CFG.get('format_swap') else ' (reuse as is)'}",
        "zram": f"zram, size = {CFG.get('zram_size')}",
        "file": f"swap file, {CFG.get('swap_size')}",
        "none": "none",
    }[CFG["swap_kind"]]
    say(f"  {C.B}swap{C.R}           : {swap_desc}"
        f"{'  + hibernation' if CFG.get('hibernate') else ''}")
    for m in CFG.get("extra_mounts", []):
        say(f"  {C.B}extra mount{C.R}    : {m['path']} ({m['fstype']}) -> {m['mountpoint']}")

    say()
    say(f"  {C.B}hostname{C.R}       : {CFG['hostname']}")
    say(f"  {C.B}timezone{C.R}       : {CFG['timezone']}")
    say(f"  {C.B}locale{C.R}         : {CFG['locale']}    keymap: {CFG['keymap']}"
        f"    x11: {CFG['x11_layout']}")
    say(f"  {C.B}user{C.R}           : {CFG['username']}  ({CFG['user_groups']})"
        f"{'   [root locked]' if CFG.get('root_locked') else '   [root has a password]'}")
    say(f"  {C.B}kernel{C.R}         : {CFG['kernel']}"
        f"{' + linux-lts' if CFG.get('kernel_fallback') else ''}"
        f"    microcode: {CFG['microcode']}")
    say(f"  {C.B}bootloader{C.R}     : {CFG['bootloader']}"
        f"{'  (os-prober enabled)' if CFG.get('os_prober') else ''}")
    say(f"  {C.B}gpu driver{C.R}     : {CFG.get('gpu_driver', 'none')}")
    say(f"  {C.B}user env{C.R}       : nix + home-manager"
        f"    starter wm: {CFG.get('nix_wm', 'none')}")

    pkgs = build_package_list()
    say()
    say(f"  {C.B}{len(pkgs)} packages{C.R} to install:")
    line = "    "
    for p in pkgs:
        if len(line) + len(p) > 76:
            say(line)
            line = "    "
        line += p + " "
    say(line)

    say()
    destructive = []
    if CFG.get("luks_enable"):
        destructive.append(f"{root} is overwritten with a LUKS2 container")
    if CFG.get("format_root"):
        destructive.append(f"{root} is erased and formatted as {CFG['root_fs']}")
    if CFG.get("format_esp"):
        destructive.append(f"{esp} is erased and formatted as FAT32")
    if CFG.get("format_home"):
        destructive.append(f"{CFG['part_home']} is erased")
    if CFG.get("format_swap"):
        destructive.append(f"{CFG['part_swap']} is reinitialised as swap")

    if destructive:
        warn("these steps destroy data:")
        for d in destructive:
            say(f"    {C.RED}-{C.R} {d}")
    else:
        info("with these answers nothing gets formatted")

    save_answers()
    say()
    say(f"{C.DIM}answers saved to {ANSWERS_PATH} (never passwords) -"
        f" replay with --config {ANSWERS_PATH}{C.R}")
    say()

    if DRY_RUN:
        ok("dry run: this is where the real installer would start writing")
        if not ask_bool("walk through the remaining steps as a preview (still changes nothing)?",
                        False):
            sys.exit(0)
        return

    if _input(f"{C.RED}{C.B}type INSTALL to begin, anything else aborts:{C.R} ").strip() != "INSTALL":
        die("aborted - nothing was changed", 0)


# ----------------------------------------------------------------------------
# step 6 - format and mount
# ----------------------------------------------------------------------------

def root_mount_opts() -> str:
    if CFG["root_fs"] != "btrfs":
        return "defaults,noatime"
    opts = "noatime,space_cache=v2,discard=async"
    comp = CFG.get("btrfs_compress", "zstd:3")
    if comp != "none":
        opts = f"compress={comp}," + opts
    return opts


def root_device() -> str:
    """The device that actually carries the root filesystem (post-LUKS)."""
    return f"/dev/mapper/{CFG['luks_name']}" if CFG.get("luks_enable") else CFG["part_root"]


def do_format() -> None:
    header("formatting")

    run("swapoff -a", check=False, quiet=True)
    run(f"umount -R {MNT}", check=False, quiet=True)

    root_part = CFG["part_root"]

    if CFG.get("luks_enable"):
        info("creating the LUKS2 container")
        run(["cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode", root_part],
            stdin_text=SECRETS["luks"])
        run(["cryptsetup", "open", root_part, CFG["luks_name"]], stdin_text=SECRETS["luks"])
        ok(f"unlocked at /dev/mapper/{CFG['luks_name']}")

    dev = root_device()
    if CFG.get("format_root"):
        run({
            "btrfs": ["mkfs.btrfs", "-f", "-L", "arch", dev],
            "ext4": ["mkfs.ext4", "-F", "-L", "arch", dev],
            "xfs": ["mkfs.xfs", "-f", "-L", "arch", dev],
            "f2fs": ["mkfs.f2fs", "-f", "-l", "arch", dev],
        }[CFG["root_fs"]])
        ok(f"{dev} formatted as {CFG['root_fs']}")

    esp = CFG.get("part_esp")
    if esp and CFG.get("format_esp"):
        run(["mkfs.fat", "-F32", "-n", "EFI", esp])
        ok(f"{esp} formatted as FAT32")

    home = CFG.get("part_home")
    if home and CFG.get("format_home"):
        hfs = CFG.get("home_fs", CFG["root_fs"])
        run({
            "btrfs": ["mkfs.btrfs", "-f", "-L", "home", home],
            "ext4": ["mkfs.ext4", "-F", "-L", "home", home],
            "xfs": ["mkfs.xfs", "-f", "-L", "home", home],
            "f2fs": ["mkfs.f2fs", "-f", "-l", "home", home],
        }[hfs])
        ok(f"{home} formatted as {hfs}")

    if CFG.get("part_swap") and CFG.get("format_swap"):
        run(["mkswap", "-L", "swap", CFG["part_swap"]])


def do_mount() -> None:
    header("mounting")

    dev = root_device()
    opts = root_mount_opts()

    if CFG["root_fs"] == "btrfs" and CFG.get("btrfs_subvolumes"):
        run(["mount", dev, MNT])
        existing = out(f"btrfs subvolume list {MNT} | awk '{{print $NF}}'").split()
        for name, _ in BTRFS_SUBVOLS:
            if name not in existing:
                run(["btrfs", "subvolume", "create", os.path.join(MNT, name)])
        run(["umount", MNT])
        run(["mount", "-o", f"{opts},subvol=@", dev, MNT])
        for name, mp in BTRFS_SUBVOLS:
            if name == "@":
                continue
            target = os.path.join(MNT, mp.lstrip("/"))
            run(["mkdir", "-p", target])
            run(["mount", "-o", f"{opts},subvol={name}", dev, target])
    else:
        run(["mount", "-o", opts, dev, MNT])

    if CFG.get("part_home"):
        run(["mount", "--mkdir", CFG["part_home"], f"{MNT}/home"])

    if CFG.get("part_esp"):
        run(["mount", "--mkdir", "-o", "fmask=0077,dmask=0077",
             CFG["part_esp"], f"{MNT}{CFG['esp_mountpoint']}"])

    if CFG.get("part_swap") and CFG["swap_kind"] == "partition":
        run(["swapon", CFG["part_swap"]], check=False)

    for m in CFG.get("extra_mounts", []):
        target = f"{MNT}{m['mountpoint']}"
        run(["mkdir", "-p", target])
        if run(["mount", m["path"], target], check=False).returncode != 0:
            warn(f"could not mount {m['path']} now - it will still be written to fstab")

    ok("current layout:")
    say(out(f"findmnt -R {MNT} -o TARGET,SOURCE,FSTYPE,OPTIONS"))


# ----------------------------------------------------------------------------
# step 7 - base system
# ----------------------------------------------------------------------------

def do_pacstrap() -> None:
    header("installing packages (the long part - go make tea)")

    pkgs = build_package_list()
    # lib32-* can only be installed once multilib exists in the target's
    # pacman.conf, so they are held back until after the chroot is configured.
    CFG["_lib32_pending"] = [p for p in pkgs if p.startswith("lib32-")]
    main = [p for p in pkgs if not p.startswith("lib32-")]

    info(f"pacstrap: {len(main)} packages")
    if run(["pacstrap", "-K", MNT] + main, check=False).returncode != 0:
        warn("pacstrap failed. Usually that is one bad package name or a flaky mirror.")
        warn("The failing package is named in the output just above and in " + LOGFILE)
        if ask_bool("retry with the same package list?", True):
            run(["pacstrap", "-K", MNT] + main)
        elif ask_bool("continue anyway with what did install? (risky)", False):
            warn("continuing with an incomplete package set")
        else:
            die("aborting after the pacstrap failure")
    ok("base system installed")


def do_fstab() -> None:
    header("fstab")
    run(f"genfstab -U {MNT} >> {MNT}/etc/fstab")

    # A missing data disk should never block boot, so give the extra mounts nofail.
    fstab = read_target("/etc/fstab")
    extra_mps = {m["mountpoint"] for m in CFG.get("extra_mounts", [])}
    if fstab and extra_mps:
        lines = []
        for line in fstab.splitlines():
            fields = line.split()
            if len(fields) >= 4 and fields[1] in extra_mps and "nofail" not in fields[3]:
                fields[3] += ",nofail"
                line = "\t".join(fields)
            lines.append(line)
        write_target("/etc/fstab", "\n".join(lines) + "\n")

    say(read_target("/etc/fstab") or "(dry run)")


# ----------------------------------------------------------------------------
# step 8 - configure the installed system
# ----------------------------------------------------------------------------

def configure_pacman_conf(path: str = "/etc/pacman.conf") -> None:
    header("pacman configuration")

    sub_in_target(path, r"^#\s*Color$", "Color")
    sub_in_target(path, r"^#?\s*ParallelDownloads\s*=.*$",
                  f"ParallelDownloads = {CFG.get('parallel_downloads', '10')}")

    if CFG.get("pacman_candy") and "ILoveCandy" not in read_target(path):
        sub_in_target(path, r"^Color$", "Color\nILoveCandy", count=1)

    if CFG.get("multilib"):
        text = read_target(path)
        if re.search(r"^\[multilib\]", text, re.MULTILINE):
            info("multilib is already enabled")
        elif re.search(r"^#\[multilib\]", text, re.MULTILINE):
            sub_in_target(path, r"^#\[multilib\]\n#(Include\s*=.*)$", r"[multilib]\n\1", count=1)
            if not re.search(r"^\[multilib\]", read_target(path), re.MULTILINE):
                write_target(path, "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n", append=True)
        else:
            write_target(path, "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n", append=True)
        ok("multilib enabled")


def configure_locale_time() -> None:
    header("locale, clock and hostname")

    chroot_run(f"ln -sf /usr/share/zoneinfo/{CFG['timezone']} /etc/localtime")
    chroot_run("hwclock --systohc")

    wanted = [CFG["locale"]] + [l for l in CFG.get("extra_locales", "").split() if l]
    text = read_target("/etc/locale.gen")
    if text:
        for loc in wanted:
            base = loc.split(".")[0]
            charset = loc.split(".")[1] if "." in loc else "UTF-8"
            text = re.sub(
                rf"^#\s*({re.escape(base)}\.{re.escape(charset)}\s+{re.escape(charset)})\s*$",
                r"\1", text, flags=re.MULTILINE)
        write_target("/etc/locale.gen", text)
    else:
        write_target("/etc/locale.gen",
                     "\n".join(f"{l} {l.split('.')[-1]}" for l in wanted) + "\n", append=True)
    chroot_run("locale-gen")

    write_target("/etc/locale.conf", f"LANG={CFG['locale']}\n")
    write_target("/etc/vconsole.conf", f"KEYMAP={CFG['keymap']}\n")

    host = CFG["hostname"]
    write_target("/etc/hostname", f"{host}\n")
    write_target("/etc/hosts",
                 "127.0.0.1\tlocalhost\n"
                 "::1\t\tlocalhost\n"
                 f"127.0.1.1\t{host}.localdomain\t{host}\n")

    # the graphical session (installed later via home-manager) still wants a layout
    write_target("/etc/X11/xorg.conf.d/00-keyboard.conf",
                 'Section "InputClass"\n'
                 '    Identifier "system-keyboard"\n'
                 '    MatchIsKeyboard "on"\n'
                 f'    Option "XkbLayout" "{CFG["x11_layout"]}"\n'
                 '    Option "XkbOptions" "terminate:ctrl_alt_bksp"\n'
                 'EndSection\n')


def configure_users() -> None:
    header("users and sudo")

    if CFG.get("root_locked"):
        chroot_run("passwd -l root")
        info("root is locked - administer the system through sudo")
    else:
        run(["arch-chroot", MNT, "chpasswd"], stdin_text=f"root:{SECRETS['root']}\n", quiet=True)
        ok("root password set")

    user = CFG["username"]
    shell = {"bash": "/bin/bash", "zsh": "/usr/bin/zsh", "fish": "/usr/bin/fish"}[CFG["shell"]]
    chroot_run(f"useradd -m -G {shlex.quote(CFG['user_groups'])} -s {shell} "
               f"-c {shlex.quote(CFG.get('user_fullname', ''))} {shlex.quote(user)}")
    run(["arch-chroot", MNT, "chpasswd"], stdin_text=f"{user}:{SECRETS['user']}\n", quiet=True)
    ok(f"user {user} created")

    rule = ("%wheel ALL=(ALL:ALL) NOPASSWD: ALL" if CFG.get("sudo_nopasswd")
            else "%wheel ALL=(ALL:ALL) ALL")
    write_target("/etc/sudoers.d/10-wheel", f"{rule}\n", mode=0o440)
    if chroot_run("visudo -c", check=False).returncode != 0:
        die("the generated sudoers file is invalid - fix "
            f"{MNT}/etc/sudoers.d/10-wheel before rebooting")


def configure_swap_extras() -> None:
    kind = CFG["swap_kind"]
    if kind == "zram":
        header("zram swap")
        write_target("/etc/systemd/zram-generator.conf",
                     "[zram0]\n"
                     f"zram-size = {CFG['zram_size']}\n"
                     "compression-algorithm = zstd\n"
                     "swap-priority = 100\n"
                     "fs-type = swap\n")
        write_target("/etc/sysctl.d/99-vm-zram-parameters.conf",
                     "vm.swappiness = 180\n"
                     "vm.watermark_boost_factor = 0\n"
                     "vm.watermark_scale_factor = 125\n"
                     "vm.page-cluster = 0\n")
    elif kind == "file":
        header("swap file")
        size = CFG["swap_size"]
        if CFG["root_fs"] == "btrfs":
            chroot_run("btrfs subvolume create /swap", check=False)
            chroot_run(f"btrfs filesystem mkswapfile --size {size} --uuid clear /swap/swapfile")
            write_target("/etc/fstab", "/swap/swapfile none swap defaults 0 0\n", append=True)
        else:
            chroot_run(f"fallocate -l {size} /swapfile && chmod 600 /swapfile && mkswap /swapfile")
            write_target("/etc/fstab", "/swapfile none swap defaults 0 0\n", append=True)


def configure_mkinitcpio() -> None:
    header("initramfs")

    hooks = ["base", "udev", "autodetect", "microcode", "modconf", "kms",
             "keyboard", "keymap", "consolefont", "block"]
    if CFG.get("luks_enable"):
        hooks.append("encrypt")
    hooks.append("filesystems")
    if CFG.get("hibernate"):
        hooks.append("resume")
    hooks.append("fsck")

    modules = []
    if CFG.get("gpu_driver", "").startswith("nvidia"):
        # the nvidia modules do their own modesetting, so the kms hook goes away
        modules += ["nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm"]
        hooks = [h for h in hooks if h != "kms"]
    if CFG["root_fs"] == "btrfs":
        modules.append("btrfs")

    sub_in_target("/etc/mkinitcpio.conf", r"^HOOKS=\(.*\)$", f"HOOKS=({' '.join(hooks)})")
    sub_in_target("/etc/mkinitcpio.conf", r"^MODULES=\(.*\)$", f"MODULES=({' '.join(modules)})")
    info(f"HOOKS=({' '.join(hooks)})")
    if modules:
        info(f"MODULES=({' '.join(modules)})")

    chroot_run("mkinitcpio -P")


def kernel_params(*, for_grub: bool = False) -> list[str]:
    """The kernel command line. GRUB works out root= and rootflags= by itself,
    so those are left out when building GRUB's config."""
    params: list[str] = []

    if CFG.get("luks_enable"):
        params.append(f"cryptdevice=UUID={blk_uuid(CFG['part_root'])}:{CFG['luks_name']}")

    if not for_grub:
        if CFG.get("luks_enable"):
            params.append(f"root=/dev/mapper/{CFG['luks_name']}")
        else:
            params.append(f"root=UUID={blk_uuid(root_device())}")
        params.append("rw")
        if CFG["root_fs"] == "btrfs" and CFG.get("btrfs_subvolumes"):
            params.append("rootflags=subvol=@")

    if CFG.get("hibernate") and CFG.get("part_swap"):
        params.append(f"resume=UUID={blk_uuid(CFG['part_swap'])}")
    if CFG.get("gpu_driver", "").startswith("nvidia"):
        params.append("nvidia_drm.modeset=1")
    if CFG.get("quiet_boot"):
        params += ["quiet", "loglevel=3"]
    params += [p for p in CFG.get("extra_cmdline", "").split() if p]
    return params


def install_bootloader() -> None:
    header(f"bootloader: {CFG['bootloader']}")

    bl = CFG["bootloader"]
    esp_mp = CFG.get("esp_mountpoint", "/boot")

    if bl == "grub":
        if is_uefi():
            chroot_run(f"grub-install --target=x86_64-efi --efi-directory={esp_mp} "
                       f"--bootloader-id={shlex.quote(CFG['grub_id'])} --recheck")
            # Also drop a removable-path copy; some firmware forgets NVRAM entries.
            chroot_run(f"grub-install --target=x86_64-efi --efi-directory={esp_mp} "
                       f"--bootloader-id={shlex.quote(CFG['grub_id'])} --removable --recheck",
                       check=False)
        else:
            chroot_run(f"grub-install --target=i386-pc --recheck {CFG['grub_bios_disk']}")

        params = kernel_params(for_grub=True)
        cmdline_default = " ".join(p for p in params if p in ("quiet", "loglevel=3"))
        cmdline_linux = " ".join(p for p in params if p not in ("quiet", "loglevel=3"))

        sub_in_target("/etc/default/grub", r"^GRUB_CMDLINE_LINUX_DEFAULT=.*$",
                      f'GRUB_CMDLINE_LINUX_DEFAULT="{cmdline_default}"')
        sub_in_target("/etc/default/grub", r"^GRUB_CMDLINE_LINUX=.*$",
                      f'GRUB_CMDLINE_LINUX="{cmdline_linux}"')
        sub_in_target("/etc/default/grub", r"^GRUB_TIMEOUT=.*$",
                      f"GRUB_TIMEOUT={CFG.get('grub_timeout', '5')}")

        if CFG.get("os_prober"):
            if "GRUB_DISABLE_OS_PROBER" in read_target("/etc/default/grub"):
                sub_in_target("/etc/default/grub", r"^#?GRUB_DISABLE_OS_PROBER=.*$",
                              "GRUB_DISABLE_OS_PROBER=false")
            else:
                write_target("/etc/default/grub", "\nGRUB_DISABLE_OS_PROBER=false\n", append=True)

        chroot_run("grub-mkconfig -o /boot/grub/grub.cfg")
        info(f"{out(f'grep -c menuentry {MNT}/boot/grub/grub.cfg', '?')} menu entries generated")
        if CFG.get("os_prober") and "Windows" not in read_target("/boot/grub/grub.cfg"):
            warn("os-prober did not report Windows. If you expected it, boot into Arch and run "
                 "`sudo grub-mkconfig -o /boot/grub/grub.cfg` again with the Windows ESP present.")

    elif bl == "systemd-boot":
        chroot_run(f"bootctl --esp-path={esp_mp} install")
        write_target(f"{esp_mp}/loader/loader.conf",
                     "default arch.conf\n"
                     f"timeout {CFG.get('sdboot_timeout', '3')}\n"
                     "console-mode keep\n"
                     "editor no\n")
        ucode = CFG.get("microcode", "none")
        ucode_line = f"initrd  /{ucode}.img\n" if ucode != "none" else ""
        params = " ".join(kernel_params())

        def entry(filename: str, kernel: str, initrd: str, title: str) -> None:
            write_target(f"{esp_mp}/loader/entries/{filename}",
                         f"title   {title}\n"
                         f"linux   /vmlinuz-{kernel}\n"
                         f"{ucode_line}"
                         f"initrd  /{initrd}\n"
                         f"options {params}\n")

        k = CFG["kernel"]
        entry("arch.conf", k, f"initramfs-{k}.img", "Arch Linux")
        entry("arch-fallback.conf", k, f"initramfs-{k}-fallback.img",
              "Arch Linux (fallback initramfs)")
        if CFG.get("kernel_fallback"):
            entry("arch-lts.conf", "linux-lts", "initramfs-linux-lts.img", "Arch Linux (LTS)")
        info("systemd-boot entries written - Windows is picked up automatically "
             "if it shares this ESP")

    elif bl == "refind":
        chroot_run("refind-install")
        params = kernel_params()
        rootspec = next(p for p in params if p.startswith("root="))
        rest = " ".join(p for p in params if not p.startswith("root="))
        write_target("/boot/refind_linux.conf",
                     f'"Boot with standard options"  "{rootspec} {rest}"\n'
                     f'"Boot to single-user mode"    "{rootspec} {rest} single"\n'
                     f'"Boot with minimal options"   "{rootspec} rw"\n')
        info("rEFInd installed - it scans for other operating systems on its own")


def configure_services() -> None:
    header("services")

    services = ["NetworkManager.service", "systemd-timesyncd.service", "fstrim.timer",
                "nix-daemon.socket"]
    groups = CFG.get("utility_groups", [])

    if "bluetooth" in groups:
        services.append("bluetooth.service")
    if "printing" in groups:
        services += ["cups.socket", "avahi-daemon.service"]
    if CFG.get("enable_sshd"):
        services.append("sshd.service")
    if "laptop" in groups:
        services += ["tlp.service", "acpid.service"]
    if "core" in groups:
        services.append("paccache.timer")
    if "firewall" in groups:
        services.append("ufw.service")
    if CFG.get("snapshots"):
        services += ["snapper-timeline.timer", "snapper-cleanup.timer"]
        if CFG["bootloader"] == "grub":
            services.append("grub-btrfsd.service")

    for svc in services:
        if chroot_run(f"systemctl enable {svc}", check=False, quiet=True).returncode == 0:
            ok(f"enabled {svc}")
        else:
            warn(f"could not enable {svc} (its package may not be installed)")

    if "firewall" in groups:
        chroot_run("ufw default deny incoming", check=False)
        chroot_run("ufw default allow outgoing", check=False)
        if CFG.get("enable_sshd"):
            chroot_run("ufw allow ssh", check=False)

    if "printing" in groups:
        # mDNS printer discovery needs nss-mdns wired into nsswitch
        sub_in_target("/etc/nsswitch.conf", r"^hosts:.*$",
                      "hosts: mymachines mdns_minimal [NOTFOUND=return] resolve "
                      "[!UNAVAIL=return] files myhostname dns")


def configure_extras() -> None:
    if CFG.get("pkg_cache_hook"):
        write_target("/etc/pacman.d/hooks/60-paccache.hook",
                     "[Trigger]\n"
                     "Operation = Upgrade\n"
                     "Operation = Install\n"
                     "Operation = Remove\n"
                     "Type = Package\n"
                     "Target = *\n\n"
                     "[Action]\n"
                     "Description = Trimming the package cache to the 3 newest versions...\n"
                     "When = PostTransaction\n"
                     "Exec = /usr/bin/paccache -rk3\n")

    if CFG.get("snapshots"):
        header("btrfs snapshots")
        # snapper insists on creating /.snapshots itself, so hand it a clean slate
        chroot_run("umount /.snapshots", check=False, quiet=True)
        chroot_run("mountpoint -q /.snapshots || rm -rf /.snapshots", check=False)
        chroot_run("snapper --no-dbus -c root create-config /", check=False)
        chroot_run("btrfs subvolume delete /.snapshots", check=False, quiet=True)
        chroot_run("mkdir -p /.snapshots && mount -a", check=False)
        for key, value in (("TIMELINE_LIMIT_HOURLY", "5"), ("TIMELINE_LIMIT_DAILY", "7"),
                           ("ALLOW_USERS", CFG["username"])):
            sub_in_target("/etc/snapper/configs/root", rf'^{key}=.*$', f'{key}="{value}"')

    if CFG.get("_lib32_pending"):
        header("32-bit libraries")
        chroot_run("pacman -Sy --noconfirm", check=False)
        chroot_run("pacman -S --noconfirm --needed " + " ".join(CFG["_lib32_pending"]), check=False)

    if "flatpak" in CFG.get("utility_groups", []):
        chroot_run("flatpak remote-add --if-not-exists flathub "
                   "https://dl.flathub.org/repo/flathub.flatpakrepo", check=False)


# ----------------------------------------------------------------------------
# step 9 - nix / home-manager
# ----------------------------------------------------------------------------

def configure_nix() -> None:
    header("nix package manager")

    write_target("/etc/nix/nix.conf",
                 "# managed by archsetup - Nix drives your user environment\n"
                 "experimental-features = nix-command flakes\n"
                 "trusted-users = root @wheel\n"
                 "auto-optimise-store = true\n")

    # make sure the nixbld build users and the nix-users group exist, then let
    # our user talk to the daemon without sudo
    chroot_run("systemd-sysusers", check=False, quiet=True)
    chroot_run(f"gpasswd -a {shlex.quote(CFG['username'])} nix-users",
               check=False, quiet=True)
    ok("nix configured (daemon socket enabled, flakes on, user in nix-users)")


FLAKE_NIX = """{
  description = "@USER@ home-manager configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      homeConfigurations."@USER@" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home.nix ];
      };
    };
}
"""

HOME_NIX = """{ config, pkgs, ... }:

{
  # This file is yours now - edit it, then apply with:
  #   home-manager switch --flake ~/.config/home-manager#@USER@   (aliased to `hm`)
  home.username = "@USER@";
  home.homeDirectory = "/home/@USER@";

  # Keep this matching your home-manager release; do not bump it casually.
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;

  # ---- packages installed into your user profile ---------------------------
  home.packages = with pkgs; [
@PKGS@  ];

  fonts.fontconfig.enable = true;

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -lah";
      update = "sudo pacman -Syu";  # system packages still come from pacman
      hm = "home-manager switch --flake ~/.config/home-manager#@USER@";
    };
  };

@WMBLOCK@}
"""

_BASE_PKGS = ["git", "curl", "wget", "ripgrep", "fd", "fzf", "jq", "tree",
              "htop", "btop", "unzip", "firefox", "noto-fonts", "noto-fonts-emoji"]

_WM_PKGS = {
    "sway": ["foot", "wofi", "waybar", "mako", "grim", "slurp", "wl-clipboard",
             "pamixer", "brightnessctl", "playerctl"],
    "hyprland": ["foot", "wofi", "waybar", "mako", "grim", "slurp", "wl-clipboard",
                 "hyprpaper", "pamixer", "brightnessctl", "playerctl"],
    "none": [],
}

_WM_BLOCK = {
    "sway": (
        "  # window manager: sway (Wayland) - launch from a tty with `sway`\n"
        "  wayland.windowManager.sway = {\n"
        "    enable = true;\n"
        "    config = rec {\n"
        '      modifier = "Mod4";\n'
        '      terminal = "foot";\n'
        '      menu = "wofi --show drun";\n'
        "    };\n"
        "  };\n"
    ),
    "hyprland": (
        "  # window manager: hyprland (Wayland) - launch from a tty with `Hyprland`\n"
        "  wayland.windowManager.hyprland.enable = true;\n"
    ),
    "none": "",
}


def render_home_nix(user: str, wm: str) -> str:
    pkgs = _BASE_PKGS + _WM_PKGS.get(wm, [])
    # emit the package list four wide so the file stays readable
    lines, row = [], []
    for p in pkgs:
        row.append(p)
        if len(row) == 4:
            lines.append("    " + " ".join(row))
            row = []
    if row:
        lines.append("    " + " ".join(row))
    pkg_text = "\n".join(lines) + "\n"

    return (HOME_NIX
            .replace("@PKGS@", pkg_text)
            .replace("@WMBLOCK@", _WM_BLOCK.get(wm, ""))
            .replace("@USER@", user))


def write_nix_config() -> None:
    header("home-manager starter config")

    user = CFG["username"]
    wm = CFG.get("nix_wm", "sway")
    cfgdir = f"/home/{user}/.config/home-manager"

    write_target(f"{cfgdir}/flake.nix", FLAKE_NIX.replace("@USER@", user))
    write_target(f"{cfgdir}/home.nix", render_home_nix(user, wm))
    chroot_run(f"chown -R {user}:{user} /home/{user}/.config", check=False)

    ok(f"wrote {cfgdir}/{{flake.nix,home.nix}} (starter wm: {wm})")


# ----------------------------------------------------------------------------
# finish
# ----------------------------------------------------------------------------

def finish() -> None:
    header("done")

    if not DRY_RUN:
        try:
            os.makedirs(f"{MNT}/root", exist_ok=True)
            shutil.copy(ANSWERS_PATH, f"{MNT}/root/archsetup-answers.json")
            shutil.copy(LOGFILE, f"{MNT}/root/archsetup.log")
        except OSError as exc:
            log(f"could not copy answers/log into the target: {exc}")

    ok(f"Arch Linux is installed on {CFG['part_root']}")
    say()
    user = CFG["username"]
    wm = CFG.get("nix_wm", "sway")
    say(f"  user       : {user}")
    say(f"  hostname   : {CFG['hostname']}")
    say(f"  bootloader : {CFG['bootloader']}")
    say(f"  user env   : nix + home-manager   (starter wm: {wm})")
    say()
    say(f"{C.B}after the reboot:{C.R}")
    say(f"  - log in as {user} on a tty, then get online:  nmtui")
    say("  - build your user environment (first run downloads a lot - be patient):")
    say(f"      nix run home-manager/master -- switch --flake ~/.config/home-manager#{user}")
    say("  - from then on just:  hm      (alias for `home-manager switch --flake ...`)")
    if wm == "sway":
        say("  - start the desktop:  sway")
        if CFG.get("gpu_driver", "").startswith("nvidia"):
            say("      (nvidia: if sway won't start, try `sway --unsupported-gpu`;")
            say("       the intel iGPU normally drives the built-in display fine)")
    elif wm == "hyprland":
        say("  - start the desktop:  Hyprland")
    say("  - add/remove apps and tweak your WM in ~/.config/home-manager/home.nix")
    say("  - system packages (kernel, drivers) still come from pacman:  sudo pacman -Syu")
    if CFG.get("os_prober"):
        say("  - Windows missing from the menu? `sudo grub-mkconfig -o /boot/grub/grub.cfg`")
    say("  - this run is recorded in /root/archsetup.log inside the new system")
    say()

    if ask_bool("unmount everything now?", True):
        run("swapoff -a", check=False)
        run(f"umount -R {MNT}", check=False)
        if CFG.get("luks_enable"):
            run(["cryptsetup", "close", CFG["luks_name"]], check=False)
        ok("unmounted")
        if ask_bool("reboot now?", False):
            run("systemctl reboot", check=False)
    else:
        info(f"the new system is still mounted at {MNT} - "
             f"`arch-chroot {MNT}` if you want to poke around")


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

def main() -> None:
    global DRY_RUN, PRESET

    parser = argparse.ArgumentParser(
        description="Interactive Arch Linux installer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="ask everything, print every command, change nothing")
    parser.add_argument("--config", metavar="FILE",
                        help="replay answers from a previous run (passwords are still asked)")
    args = parser.parse_args()

    DRY_RUN = args.dry_run
    if args.config:
        try:
            with open(args.config) as fh:
                PRESET = json.load(fh)
            info(f"loaded {len(PRESET)} preset answers from {args.config}")
        except (OSError, json.JSONDecodeError) as exc:
            die(f"could not read {args.config}: {exc}")

    log(f"=== archsetup started {datetime.now()} dry_run={DRY_RUN} ===")

    say()
    say(f"{C.B}{C.CYA}  archsetup{C.R} - interactive Arch Linux installer")
    say(f"{C.DIM}  nothing is written to disk until you confirm the summary{C.R}")

    step_preflight()
    step_network()
    step_mirrors()
    step_disks()
    step_system()
    step_bootloader()
    step_graphics()
    step_userenv()

    summary_and_confirm()

    do_format()
    do_mount()
    do_pacstrap()
    do_fstab()

    configure_pacman_conf()
    configure_locale_time()
    configure_users()
    configure_swap_extras()
    configure_mkinitcpio()
    install_bootloader()
    configure_services()
    configure_extras()
    configure_nix()
    write_nix_config()

    finish()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        say()
        die("interrupted", 130)
