# Windows 11 25H2 + AtlasOS — 6-hour QEMU lab on GitHub Actions

Spin up a real, UEFI + SecureBoot + TPM 2.0 Windows 11 25H2 virtual machine
inside a GitHub-hosted runner, from **an ISO URL you supply at launch**, and
reach its desktop from your browser over a **tokenless** Cloudflare quick
tunnel. AtlasOS (AME Wizard + the latest Atlas Playbook) is staged and ready.

No Microsoft account. No product key you have to own. No repo secrets.
No self-hosted runner. Nothing hardcoded.

---

## Quick start

1. Copy this repo (or just `.github/workflows/` + `scripts/`) into a GitHub repo.
2. **Actions → "Win11 25H2 + AtlasOS (QEMU, 6h, tokenless)" → Run workflow.**
3. Paste your **direct** Windows 11 25H2 x64 ISO URL into `iso_url`.
4. Wait for the **Session banner** step, open the `*.trycloudflare.com` link
   printed in the job summary, and you are on the Windows desktop.

Getting an ISO URL: [uupdump.net](https://uupdump.net) (pick *Windows 11 25H2,
amd64*, "Download and convert"), the Microsoft download page (right-click the
download button → *Copy link address* — the tokened CDN link works), or your
own S3/R2 presigned link.

> The URL must be a **direct file link**, not an HTML landing page. Preflight
> checks this for you in ~10 seconds before any 6-hour runner is committed.

---

## Inputs

| Input | Default | Notes |
|---|---|---|
| `iso_url` | *(required)* | Direct URL to a Windows 11 25H2 **x64** ISO |
| `iso_sha256` | *(empty)* | Optional integrity check |
| `windows_edition` | `Windows 11 Pro` | Must exist inside your ISO |
| `atlas_mode` | `stage` | `stage` / `verify` / `none` |
| `session_minutes` | `330` | VM uptime; job hard-caps at 360 |
| `ram_mb` / `vcpus` / `disk_gb` | `8192` / `4` / `64` | Guest sizing |
| `vnc_password` | *(random)* | Printed in the job summary |
| `export_disk` | `false` | Upload the qcow2 as an artifact |

---

## Requirement checklist

Every box below is **verified and reported by the guest itself** into the job
summary (source of truth: `C:\Atlas\logs\checklist.json`).

| | Requirement | How it is satisfied |
|:-:|---|---|
| ☑ | Windows 11 25H2 from your ISO URL | `verify-iso.sh` reads the WIM and asserts build **26200** before installing |
| ☑ | 64-bit (x64) | WIM architecture asserted `x86_64`; ARM/x86 media rejected |
| ☑ | Administrator privileges | Unattend creates a local admin in `Administrators` + autologon |
| ☑ | Clean Windows installation | `WillWipeDisk` + fresh GPT (EFI/MSR/Windows); no `Windows.old` |
| ☑ | Internet connection | Verified in-guest via Microsoft NCSI, TCP fallback |
| ☑ | Sufficient free disk space | Thin 64 GiB qcow2; ≥25 GB free asserted on `C:` |
| ☑ | Windows setup (OOBE) completed | `SkipMachineOOBE` + `BypassNRO`; `ImageState=IMAGE_STATE_COMPLETE` asserted |
| ☑ | Backup completed | qcow2 internal snapshot **`pre-atlas`** + in-guest restore point |

AME Wizard's own gates (Defender off, no third-party AV, UCPD disabled, no
pending-update reboot, AC power) are checked and reported too.

---

## "Make sure Windows boots successfully"

Boot success is **proven by the guest phoning home**, not guessed from a
screenshot. The guest posts milestones to a host beacon on `10.0.2.2`:

```
winpe  →  specialize  →  firstlogon  →  desktop  →  checklist
```

`wait-milestones.py` blocks on each with its own timeout, and fails the job —
attaching the last framebuffer capture — if QEMU dies, the guest stalls, or a
milestone never lands. Screenshots are taken every 5 minutes throughout and
uploaded as artifacts.

---

## Applying the Atlas Playbook

Steps 1–2 are manual **by design**: Microsoft's Tamper Protection cannot be
disabled from a script, and AME Wizard hard-blocks while Defender is active.

1. Windows Security → Virus & threat protection → Manage settings →
   turn off **Real-time protection** and **Tamper protection**.
2. Double-click **`Launch-Atlas.cmd`** on the desktop.
3. Drag the `.apbx` onto AME Wizard and follow it.

Assets are pre-downloaded on the host (fast runner NIC) and mounted as an
`ATLAS` CD-ROM, so a flaky in-guest download never blocks your session.

---

## How it works

```
preflight  HEAD/Range probe: status, content-type, size sanity, resumability
   ↓
vm         free disk → enable /dev/kvm → install QEMU/OVMF/swtpm/noVNC
           → aria2 the ISO (8 conns, resumable) → verify build/arch/edition
           → build Autounattend PROVISION.iso → OVMF+SecureBoot+swtpm TPM 2.0
           → boot → cloudflared quick tunnel → milestone gate → checklist
           → qcow2 snapshot → hold session → graceful shutdown → artifacts
```

### Non-obvious details that make it actually work

- **`bootindex`, not `-boot order=`.** Once any device declares a `bootindex`,
  QEMU ignores `-boot order` entirely. Install CD is `1`, system disk is `2`;
  getting this backwards makes OVMF try the empty disk and never start Setup.
- **AHCI for the system disk.** Stock WinPE has no virtio-blk driver, so a
  virtio system disk yields "no drives were found". virtio-net is still used,
  with drivers injected during `specialize`.
- **Autounattend on a second CD-ROM.** Setup scans the root of every removable
  volume, so no repacking or re-signing of your ISO is needed.
- **`-machine hpet=off`,** not the `-no-hpet` flag, which QEMU 9+ removed.
- **Pure-bash `/dev/tcp` port probes** instead of depending on `netcat`.

---

## Security

The tunnel hostname is public but random and unlisted; the VNC session is
password-gated (`VNC Authentication`, verified as enforced). Treat the URL +
password as a shared secret for the session's lifetime. The VM and its tunnel
are destroyed when the job ends.

## Limitations

- 6 hours is GitHub's hard per-job cap; `session_minutes` maxes at 340.
- Windows is **not activated** (a generic KMS *client* key only selects the
  edition). Atlas does not require activation.
- Nested virtualisation on hosted runners is KVM-accelerated but slower than
  bare metal; the Windows install typically takes 20–40 minutes.
- Respect Microsoft's licensing terms for any ISO you supply.
