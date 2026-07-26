================================================================
 Windows 11 25H2 lab VM  -  AtlasOS staging
================================================================

You are inside a disposable QEMU/KVM virtual machine running on a
GitHub Actions runner. It disappears when the job ends.

WHAT IS ALREADY DONE
  - Clean Windows 11 25H2 x64 install from YOUR ISO url
  - Local administrator account, autologon, OOBE completed
  - virtio drivers installed (disk / network / balloon)
  - UCPD disabled (Atlas requirement, applied on next reboot)
  - Sleep + screen blanking disabled
  - AME Wizard and the latest Atlas Playbook downloaded to
        C:\Atlas\payload
  - Host-side qcow2 snapshot "pre-atlas" taken as your backup
  - Readiness checklist written to
        C:\Atlas\logs\checklist.json

WHAT YOU DO
  1. Open Windows Security -> Virus & threat protection ->
     Manage settings, and turn OFF:
        Real-time protection
        Tamper protection
     (AME Wizard hard-blocks while these are on. This is why the
      step is manual - Microsoft deliberately makes it non
      scriptable via Tamper Protection.)
  2. Double-click "Launch-Atlas.cmd" on the desktop.
  3. Drag the .apbx playbook onto the AME Wizard window.
  4. Follow the wizard. The machine will reboot itself.

TIME BUDGET
  The job is capped at 6 hours total, and the VM is held open for
  the number of minutes you chose at launch. When the timer runs
  out the VM is shut down gracefully and logs + screenshots are
  uploaded as workflow artifacts.

NOTES
  - No Microsoft account is used or needed.
  - The generic KMS client key only selects the edition; Windows
    is NOT activated. Atlas does not require activation.
  - Nothing here is persisted unless you enabled export_disk.
================================================================
