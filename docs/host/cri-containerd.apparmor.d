# Local override of containerd's default container AppArmor profile.
#
# Installed at /etc/apparmor.d/cri-containerd.apparmor.d on homelab-server.
# This is containerd v2.2.3's built-in template (contrib/apparmor/template.go),
# rendered exactly as containerd itself would on this host (tunables/global +
# abstractions/base present, daemon profile = unconfined, no rootlesskit),
# PLUS the two rules marked LOCAL below.
#
# Why: on this host (Ubuntu 26.04, AppArmor 5.0.2, kernels 7.0.0-42/-43)
# container processes carry STACKED labels such as
# "cri-containerd.apparmor.d//&unconfined" and
# "chromium//&cri-containerd.apparmor.d". The template's peer rules only match
# the bare "cri-containerd.apparmor.d" label, so signals and ptrace reads
# BETWEEN PROCESSES OF THE SAME CONTAINER were denied: gosu hung forever,
# pg_ctl could not stop postgres, Go lost SIGURG preemption, ps failed.
#
# containerd only generates and loads its own profile when none with this name
# is loaded yet (isLoaded() checks /sys/kernel/security/apparmor/profiles), and
# apparmor.service loads /etc/apparmor.d at boot before k3s starts, so this
# file wins. To revert: delete this file and reboot.

#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,

  # LOCAL: the peer rules above don't match stacked labels; allow signals to
  # any peer. A container still can only reach processes visible in its own
  # PID namespace, subject to the usual uid/capability checks.
  signal (send,receive),

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9],[^1-9][^0-9],[^1-9s][^0-9y][^0-9s],[^1-9][^0-9][^0-9][^0-9]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/mem rwklx,
  deny @{PROC}/kmem rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,

  # LOCAL: same stacked-label problem for ptrace; only the non-invasive
  # read/readby (what ps and /proc/<pid> inspection need) is widened.
  # trace/tracedby stay restricted to the bare label above.
  ptrace (read,readby),
}
