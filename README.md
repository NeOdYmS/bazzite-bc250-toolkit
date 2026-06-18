# Bazzite BC250 Toolkit

A post-install, test-first setup toolkit for running an **AMD BC-250 / Cyan Skillfish** board on **Bazzite / Fedora Atomic**.

The goal of this project is to make a fresh Bazzite install usable as a BC-250 gaming / Steam Machine system without having to manually remember every kernel argument, service, sensor module, CPU test, GPU governor setting, or 40 CU workflow.

> [!WARNING]
> This project is unofficial and experimental. It can change kernel arguments, layer host packages with `rpm-ostree`, start/stop systemd services, configure swap/zswap, run CPU overclock tests, change GPU governor settings, and use UMR-based CU routing tools. Use it only if you understand how to rollback a Bazzite deployment.

---

## What this toolkit does

The toolkit is designed to be run **right after a fresh Bazzite installation** on a BC-250 system.

It provides:

- First boot diagnostics for BC-250-specific setup.
- A guided workflow in the recommended order.
- Bazzite / Fedora Atomic package layering helpers.
- Boot logo / kernel argument management.
- Swap + zswap setup.
- ACPI fix helper.
- NCT6687 / NCT6686 sensor helper.
- CPU overclock / undervolt testing via `bc250_smu_oc`.
- GPU governor configuration via `cyan-skillfish-governor-smu`.
- 40 CU live workflow using `bc250-cu-live-manager` + `umr`.
- Monitoring helpers for sensors, GPU sysfs, services, swap/zswap, and `amdgpu_top`.
- Revert helpers for the most important changes.

This toolkit intentionally follows a **test-first workflow**. It does **not** encourage blindly applying “magic” overclock presets.

---

## Target system

Tested / designed for:

- AMD BC-250 / Cyan Skillfish board.
- Bazzite Deck / HTPC style installation.
- Fedora Atomic / `rpm-ostree` host.
- KDE / Game Mode / Desktop Mode usage.

The script tries to detect useful paths instead of assuming one language or one home layout. It handles common paths such as:

- `~/Downloads`
- `~/Téléchargements`
- `~/Telechargements`
- `/var/home/<user>`
- `/home/<user>`

---

## Quick installation

Clone the repository:

```bash
git clone https://github.com/YOUR_USER/bazzite-bc250-toolkit.git
cd bazzite-bc250-toolkit
chmod +x bc250-toolkit.sh
sudo ./bc250-toolkit.sh
```

Or download only the script:

```bash
chmod +x bc250-toolkit.sh
sudo ./bc250-toolkit.sh
```

The script should show:

```text
Bazzite BC250 Toolkit
Version: 2.10-bazzite
```

---

## Recommended first-run workflow

After a fresh Bazzite install, start with:

```text
[F] First Boot Check
[W] Guided Workflow
```

The recommended order is:

### Phase 0 — Check before modifying anything

1. Run **First Boot Check**.
2. Confirm the system is Bazzite / Fedora Atomic.
3. Confirm the BC-250 GPU is detected.
4. Check current kernel, Mesa/RADV, BIOS information, kernel arguments, ACPI state, sensors, swap, governor, and CU state.

### Phase 1 — Base system setup

1. Run **Run All Base**.
2. Reboot when `rpm-ostree` stages a new deployment.
3. Apply **Boot Logo** settings if needed.
4. Reboot after kernel argument changes.
5. Apply / verify **ACPI Fix**.
6. Reboot after ACPI changes.
7. Install / verify **NCT6687 sensors**.
8. Disable sleep / hibernation if this machine is used as a couch gaming box.

### Phase 2 — Test CPU and GPU, do not blindly preset

1. Install CPU tools.
2. Run CPU tests with `bc250-detect`.
3. Review the generated `overclock.conf`.
4. Only install a CPU config at boot after a successful test.
5. Configure GPU governor test values.
6. Validate GPU behavior in a game or benchmark with monitoring open.

### Phase 3 — Optional 40 CU live testing

1. Install `umr` if missing.
2. Install / update `bc250-cu-live-manager`.
3. Apply 40 CU live only for the current session.
4. Verify using the manager dashboard.
5. Stress test.
6. Save boot restore only if stable.
7. Keep rollback commands ready.

---

## Main menu overview

The toolkit main menu is organized around first boot setup, testing, and recovery:

```text
Start here
  [F] First Boot Check
  [W] Guided Workflow

Performance
  [1] Performance Testing

Setup
  [2] Initial Setup
  [3] Additional Tools
  [4] Revert Menu

System
  [S] Status
  [P] Path Detection
  [R] Reboot Now
  [0] Exit
```

---

## First Boot Check

The first boot check inspects the system without applying overclocks.

It checks:

- Bazzite / Fedora Atomic detection.
- `rpm-ostree` availability.
- Current kernel.
- Kernel arguments.
- `nomodeset` presence.
- `loglevel=0` presence.
- `rhgb`, `quiet`, and `splash` boot flags.
- Mesa / RADV tools when available.
- BIOS information.
- ACPI / CPU frequency scaling.
- GPU governor service state.
- GPU governor config file.
- NCT6687 / NCT6686 sensors.
- Fan / pump / VRM readings.
- Swap and zswap state.
- Current active CU count from `dmesg`.
- Presence of `umr` and CU live manager.

---

## Boot logo / boot arguments

The toolkit can restore a cleaner graphical boot by keeping:

```text
rhgb quiet splash
```

and removing:

```text
loglevel=0
```

This is useful if the Bazzite logo / Plymouth screen disappears after aggressively hiding boot messages.

Commands used by the script are based on:

```bash
rpm-ostree kargs
rpm-ostree kargs --append-if-missing=quiet
rpm-ostree kargs --append-if-missing=splash
rpm-ostree kargs --append-if-missing=rhgb
rpm-ostree kargs --delete=loglevel=0
systemctl reboot
```

Reboot is required after changing kernel arguments.

---

## Swap and zswap

The toolkit can create a Btrfs-friendly swapfile and configure zswap.

Default recommended setup:

```text
Swapfile: /var/swap/swapfile
Swap size: 32G
vm.swappiness: 180
zswap.enabled: 1
zswap.max_pool_percent: 25
zswap.compressor: lz4
systemd.zram: 0
```

Files / settings modified:

```text
/var/swap/swapfile
/etc/fstab
/etc/sysctl.d/99-bc250-swappiness.conf
/etc/systemd/zram-generator.conf
rpm-ostree kernel arguments
```

A reboot is required for all kernel argument changes to take effect.

---

## ACPI fix

The toolkit includes an ACPI helper for BC-250 systems.

It can:

- Clone / update the ACPI fix repository.
- Build an early initrd containing ACPI tables.
- Install `/boot/SSDT_ACPI.cpio`.
- Add the GRUB early initrd reference.
- Regenerate GRUB with `ujust regenerate-grub` when available.

Files / settings modified:

```text
/boot/SSDT_ACPI.cpio
/etc/default/grub
```

Expected result after reboot:

```text
/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
```

should expose the expected CPU frequency states, typically including values such as `800000` and `3200000`.

---

## NCT6687 / NCT6686 sensors

The BC-250 documentation describes two different Nuvoton paths:

```text
nct6683 = read-only monitoring
nct6687 = PWM fan control / CoolerControl path
```

Do **not** load both at the same time for the CoolerControl/PWM workflow. Loading both exposes duplicate `nct6686` hwmon devices, for example:

```text
/sys/devices/platform/nct6683.2592
/sys/devices/platform/nct6687.2592
```

This can make CoolerControl attach to the read-only `nct6683` instance, show duplicated `nct6686` devices, or apply profiles to stale fan/PWM channels.

For PWM fan control, the toolkit now makes the `nct6687` path exclusive. Before installing/loading `nct6687`, it disables old `nct6683` forced-loading configuration such as:

```text
/etc/modules-load.d/nct6683.conf
/etc/modprobe.d/sensors.conf
/etc/sysconfig/lm_sensors
```

The toolkit can:

- Clone / update the `nct6687d` driver repository.
- Build the module for the current kernel.
- Install it under `/var/lib/bc250/modules/<kernel>/`.
- Create `/usr/local/sbin/bc250-load-nct6687`.
- Create and enable `bc250-nct6687.service`.
- Unbind/unload `nct6683` at runtime when possible.
- Verify that only one `nct6686` hwmon device remains and that it uses `platform:nct6687`.

Expected state after install/reboot:

```text
/sys/class/hwmon/hwmonX -> /sys/devices/platform/nct6687.2592 / modalias=platform:nct6687
```

State to avoid when using CoolerControl PWM mode:

```text
/sys/devices/platform/nct6683.2592
```

Useful readings include:

```text
Tctl
GPU edge
PPT
Pump Fan
CPU Fan
VRM MOS
```

Some sensor labels can vary by board, kernel, driver version, and fan header wiring.

---

## CPU testing / overclocking

CPU testing uses `bc250_smu_oc`.

The toolkit installs / uses:

```text
bc250-detect
bc250-apply
bc250-smu-oc.service
```

Important behavior:

- `bc250-detect` tests a requested frequency / voltage / temperature limit.
- Without `-k`, it restores default parameters after the test.
- With `-k`, it keeps the result active for the current session.
- Installing at boot should only be done after a successful and repeatable result.

The toolkit provides CPU options such as:

```text
Test CPU
Test + keep for this session
Apply existing overclock.conf at boot
CPU status
```

Example command:

```bash
cd /opt/bc250_smu_oc
bc250-detect -f 3650 -v 1160 -t 90
```

Example install-at-boot flow:

```bash
sudo bc250-apply --install /opt/bc250_smu_oc/overclock.conf
sudo systemctl enable --now bc250-smu-oc.service
```

### Known example points from one tested board

These are **not universal presets**. They are included as examples of how to document your own board.

```text
3650 MHz / 1160 mV / 90°C  -> good daily candidate on the tested board
3700 MHz / 1180 mV / 95°C  -> performance test candidate on the tested board
3775 MHz                   -> throttled on the tested board
3800 MHz                   -> throttled on the tested board
4000 MHz                   -> not recommended without better cooling / validation
```

Always test your own board.

---

## GPU testing / governor

GPU frequency management uses `cyan-skillfish-governor-smu`.

Default config path:

```text
/etc/cyan-skillfish-governor-smu/config.toml
```

The toolkit can:

- Install the governor package from the expected repository.
- Disable conflicting old governor services.
- Write a test config.
- Restart / enable the service.
- Open logs and monitoring helpers.

Service:

```text
cyan-skillfish-governor-smu.service
```

Typical test progression:

```text
1850 MHz -> 1900 MHz -> 1950 MHz -> 2000 MHz
```

Safer daily thermal limits are usually lower than short benchmark limits. Example starting points:

```text
Throttle: 82-85°C
Recovery: 76-78°C
```

A temporary benchmark profile can use higher limits, but it should not be treated as a daily profile without validation.

Example config values:

```toml
[frequency-range]
min = 500
max = 2000

[temperature]
throttling = 85
throttling_recovery = 78
```

---

## 40 CU live manager

The toolkit uses **bc250-cu-live-manager** as the primary 40 CU workflow.

This approach is preferred here because it avoids the older flow that needs a patched/rebuilt `amdgpu` kernel module and matching kernel source files.

The live-manager path uses:

```text
umr
bc250-cu-live-manager.sh
```

The toolkit can:

- Install `umr` through `rpm-ostree` if needed.
- Download / update `bc250-cu-live-manager.sh`.
- Run the manager TUI.
- Apply all CUs live until reboot.
- Save a boot restore table.
- Install / uninstall the boot restore service.
- Restore stock dispatch live.

Recommended order:

```text
1. Install UMR
2. Reboot if rpm-ostree asks for it
3. Install Manager
4. Status
5. 40 CU live
6. Verify in the manager dashboard
7. Stress test
8. Save boot only if stable
9. Keep Stock live / Uninstall boot ready for rollback
```

Rollback options:

```text
Stock live
Uninstall boot restore
Reboot
```

Note: `dmesg` may still show the driver’s original CU topology depending on method and timing. Use the live manager dashboard as the main indicator for runtime CU routing.

---

## Monitoring tools

The toolkit can open monitoring terminals for:

- `amdgpu_top`
- `amdgpu_top` inside Distrobox
- `sensors`
- GPU governor journal
- CPU governor journal
- swap / zswap state
- GPU sysfs counters
- service status
- `btop`, `htop`, or `top`

Useful manual commands:

```bash
watch -n 1 'sensors | grep -Ei "edge|junction|mem|temp|fan|power|Tctl|Tdie|VRM|Pump" || sensors'

journalctl -u cyan-skillfish-governor-smu.service -f
journalctl -u bc250-smu-oc.service -f

watch -n 1 'for f in /sys/class/drm/card*/device/{gpu_busy_percent,mem_busy_percent,pp_dpm_sclk,pp_dpm_mclk,pp_power_profile_mode}; do [ -r "$f" ] && echo === "$f" === && cat "$f" && echo; done'

swapon --show
cat /sys/module/zswap/parameters/enabled
cat /sys/module/zswap/parameters/max_pool_percent
cat /sys/module/zswap/parameters/compressor
```

---

## Revert / recovery

The toolkit includes a revert menu for common changes:

- Write stock GPU profile.
- Disable GPU governor.
- Disable CPU governor.
- Remove swapfile.
- Remove zswap kernel arguments.
- Remove boot tweaks such as `loglevel` or `mitigations`.
- Re-enable sleep / hibernation.

Bazzite / Fedora Atomic also supports deployment rollback. If a layered package or kernel argument change causes trouble, boot a previous deployment from the boot menu or use rpm-ostree rollback tools.

---

## Files and settings modified by the toolkit

Depending on which menu items you run, the toolkit may create or modify:

```text
/etc/cyan-skillfish-governor-smu/config.toml
/etc/bc250-bazzite-toolkit/active-profile.env
/opt/bc250_smu_oc
/opt/bc250-acpi-fix
/opt/nct6687d
/opt/bc250-cu-live-manager
/usr/local/bin/bc250-detect
/usr/local/bin/bc250-apply
/usr/local/sbin/bc250-load-nct6687
/var/lib/bc250/modules/<kernel>/nct6687.ko
/etc/systemd/system/bc250-nct6687.service
/var/swap/swapfile
/etc/fstab
/etc/sysctl.d/99-bc250-swappiness.conf
/etc/systemd/zram-generator.conf
/boot/SSDT_ACPI.cpio
/etc/default/grub
rpm-ostree kernel arguments
systemd services
```

---

## Credits and sources

This toolkit is an integration / workflow wrapper around community work. Credit belongs to the original projects and documentation authors.

### Bazzite / Fedora Atomic

- Bazzite project and documentation: https://bazzite.gg/ and https://docs.bazzite.gg/
- Bazzite is based on Fedora Atomic / rpm-ostree workflows.

### AMD BC250 documentation

- AMD BC250 Documentation by the community: https://elektricm.github.io/amd-bc250-docs/
- GitHub repository: https://github.com/elektricM/amd-bc250-docs

Used as reference for:

- BC-250 platform setup.
- Kernel / Mesa / BIOS notes.
- ACPI fix workflow.
- GPU governor notes.
- Sensors / NCT6686 information.
- CPU and GPU tuning context.

### CPU overclocking / undervolting

- `bc250_smu_oc`: https://github.com/bc250-collective/bc250_smu_oc

Used for:

- `bc250-detect`
- `bc250-apply`
- `bc250-smu-oc.service`
- CPU frequency / voltage testing through SMU messages.

### GPU governor

- `cyan-skillfish-governor-smu`
- COPR source used by BC250 community workflows: `filippor/bazzite`
- BC250 docs governor page: https://elektricm.github.io/amd-bc250-docs/system/governor/

Used for:

- GPU frequency governor service.
- `/etc/cyan-skillfish-governor-smu/config.toml`
- SMU-based GPU frequency control.

### 40 CU live manager

- `bc250-cu-live-manager` by WinnieLV: https://github.com/WinnieLV/bc250-cu-live-manager

Used for:

- UMR-based live CU/WGP routing.
- Interactive TUI.
- Optional boot restore table / service.

### UMR

- UMR is used by `bc250-cu-live-manager` for low-level AMD GPU register access.

### NCT6687 / NCT6686 sensors

- `nct6687d` driver project used for BC250 sensor support: https://github.com/Fred78290/nct6687d

Used for:

- SuperIO fan / pump / VRM sensor readings.
- Loading the sensor module from `/var/lib/bc250/modules/<kernel>/` on Bazzite.

### ACPI fix

- BC250 ACPI fix project: https://github.com/bc250-collective/bc250-acpi-fix

Used for:

- ACPI table override.
- CPU frequency / power state visibility.

### Legacy 40 CU module approach

- `bc250-40cu-unlock`: https://github.com/duggasco/bc250-40cu-unlock

This older approach is credited, but the toolkit now favors the UMR live-manager workflow because it is more practical on Bazzite systems where full matching kernel source may not be present.

---

## Disclaimer

This project is not affiliated with AMD, ASRock, Bazzite, Fedora, Valve, or any original project credited above.

Overclocking, undervolting, CU routing, kernel arguments, and module loading can cause instability, crashes, boot issues, graphical problems, data loss, or hardware damage.

Use at your own risk.

---

## Suggested repository structure

```text
bazzite-bc250-toolkit/
├── bc250-toolkit.sh
├── README.md
├── LICENSE
└── .gitignore
```


---

## License

This project is released under the MIT License.

You are free to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of this software, provided that the original copyright notice and this permission notice are included.

See the MIT License for details.

