#!/usr/bin/env python3
"""Apply the POLARIS bring-up changes to an iOS root made by tools/mkiosroot.sh.

  sudo polaris-root-tweaks.py MOUNTED_ROOT

MOUNTED_ROOT is the HFS+ image mounted read-write (Linux: run
`fsck.hfsplus -fy` on the image, then `mount -t hfsplus -o loop,force`).
Run as root (it writes root/mobile owned files). Idempotent. This is what
turned the plain mkiosroot.sh output into the images that reach the home
screen (image versions v8-v14 in NOTES.md):

  launchd.plist   _PanicOnCrash -> _PanicOnCrasX (a crashing daemon must not
                  panic the system); CommCenter jobs removed (no baseband: it
                  crash-loops and Setup blocks on its CoreTelephony XPC)
  containers      /private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}
                  (on iOS they live on the data volume)
  migration       LastSystemVersion so DataMigration does not run for an hour
                  on every boot
  audio           VirtualAudio HAL plug-in disabled (mediaserverd crash)
  MediaToolbox    StartRecorderServer=false (camera filter prewarm calls a
                  NULL OpenGL function without a GPU -> mediaserverd crash loop)
  SpringBoard     BKNoWatchdogs (one slow CPU path, no scene-create watchdog
                  kills), no cloud-configuration UI
  Setup           skipped by default: SetupDone, SetupFinishedAllSteps,
                  SetupVersion 11, mini-buddy flags off. Pass --keep-setup
                  to leave the Setup Assistant enabled (first boot runs
                  purplebuddy; use it when the icon layout or activation
                  state has to be produced by the wizard).
  activation      mobileactivationd system container + data ark. The container
                  is created when missing; the actual Activated state comes
                  from the Hactivation branch selected by /chosen security
                  status in tools/mkadt.py
"""
import glob, os, plistlib, shutil, sys, time

BUILD, VERSION = '20H392', '16.7.16'
MOBILE = 501
ACTIVATION_ID = 'com.apple.mobileactivationd'
# UUID used by the upstream v14 image; the directory name must match the
# metadata, and containermanagerd adopts an existing metadata plist.
ACTIVATION_UUID = 'D90C94C4-F94E-4FCF-8A28-A93BE3846D8E'


def load(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def save(path, data, uid, gid, mode, fmt=plistlib.FMT_BINARY):
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    os.chown(path, uid, gid)
    os.chmod(path, mode)


def merge_pref(root, name, values):
    """Merge keys into /var/mobile/Library/Preferences/NAME.plist (mobile, 0600)."""
    path = os.path.join(root, 'private/var/mobile/Library/Preferences', name + '.plist')
    data = load(path) if os.path.exists(path) else {}
    data.update(values)
    save(path, data, MOBILE, MOBILE, 0o600)
    print('pref', name, sorted(values))


def launchd(root):
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = plist['LaunchDaemons']
    renamed = 0
    for job in jobs.values():
        if '_PanicOnCrash' in job:
            job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
            renamed += 1
    removed = [k for k, j in jobs.items() if j.get('Label') == 'com.apple.CommCenter']
    for k in removed:
        del jobs[k]
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'launchd.plist: {renamed} _PanicOnCrash renamed, {len(removed)} CommCenter jobs removed')


def containers(root):
    base = os.path.join(root, 'private/var/containers')
    for sub, uid in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            os.makedirs(d)
            os.chown(d, uid, uid)
            os.chmod(d, 0o755)
            print('mkdir', d)


def find_container(root, kind, identifier):
    for meta in glob.glob(os.path.join(root, 'private/var/containers', kind, '*',
                                       '.com.apple.mobile_container_manager.metadata.plist')):
        if load(meta).get('MCMMetadataIdentifier') == identifier:
            return os.path.dirname(meta)
    return None


def container_metadata(identifier, uuid):
    """Metadata understood by containermanagerd; MCMMetadataInfo is the
    binary-plist form of the same fields."""
    info = {
        'MCMMetadataContentClass': 2,
        'MCMMetadataIdentifier': identifier,
        'MCMMetadataUUID': uuid,
        'MCMMetadataVersion': 1,
    }
    return {
        'MCMMetadataContentClass': 2,
        'MCMMetadataIdentifier': identifier,
        'MCMMetadataInfo': plistlib.dumps(info, fmt=plistlib.FMT_BINARY),
        'MCMMetadataMtime': int(time.time()),
        'MCMMetadataUUID': uuid,
        'MCMMetadataVersion': 1,
    }


def ensure_container(root, kind, identifier, uuid):
    c = find_container(root, kind, identifier)
    if c is not None:
        return c
    c = os.path.join(root, 'private/var/containers', kind, uuid)
    os.makedirs(c, exist_ok=True)
    os.chown(c, 0, 0)
    os.chmod(c, 0o755)
    save(os.path.join(c, '.com.apple.mobile_container_manager.metadata.plist'),
         container_metadata(identifier, uuid), 0, 0, 0o644)
    print('created container', os.path.relpath(c, root))
    return c


def activation(root):
    c = ensure_container(root, 'Data/System', ACTIVATION_ID, ACTIVATION_UUID)
    lib = os.path.join(c, 'Library')
    os.makedirs(lib, exist_ok=True)
    os.chown(lib, 0, 0)
    os.chmod(lib, 0o755)
    d = os.path.join(lib, 'internal')
    os.makedirs(d, exist_ok=True)
    os.chown(d, MOBILE, MOBILE)
    os.chmod(d, 0o755)
    save(os.path.join(d, 'data_ark.plist'), {
        '-ActivationState': 'Activated', '-BrickState': False,
        '-BuildVersion': BUILD, '-ProductVersion': VERSION,
        '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True,
    }, MOBILE, MOBILE, 0o600)
    print('data ark', d)


def audio(root):
    src = os.path.join(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin')
    dst_dir = os.path.join(root, 'Library/Audio/Plug-Ins/HAL.disabled')
    if os.path.exists(src):
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(src, dst_dir)
        print('VirtualAudio.plugin disabled')
    for conf in glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')):
        st = os.stat(conf)
        data = load(conf)
        data['StartRecorderServer'] = False
        save(conf, data, st.st_uid, st.st_gid, st.st_mode & 0o7777, plistlib.FMT_XML)
        print('StartRecorderServer off', os.path.relpath(conf, root))


def main():
    flags = {a for a in sys.argv[1:] if a.startswith('--')}
    paths = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(paths) != 1 or not os.path.isdir(os.path.join(paths[0], 'System/Library/xpc')):
        sys.exit(__doc__)
    root = paths[0]
    keep_setup = '--keep-setup' in flags
    launchd(root)
    containers(root)
    activation(root)
    audio(root)
    merge_pref(root, 'com.apple.migration', {
        'LastSystemVersion': BUILD,
        'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': BUILD}})
    merge_pref(root, 'com.apple.springboard', {
        'BKNoWatchdogs': True,
        'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
        'MCForceShowCloudConfigurationUI': False})
    if keep_setup:
        print('Setup Assistant left enabled (--keep-setup)')
    else:
        merge_pref(root, 'com.apple.purplebuddy', {
            'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11,
            'daemonizeNeedsToRun': False})
        merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
            k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy',
                               'ShouldRunKeychainSyncMiniBuddy', 'ShouldRunMesaMiniBuddy',
                               'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                               'SilentICDPUpgrade')})
        merge_pref(root, 'com.apple.managedconfiguration.notbackedup', {
            'LockdownActivationIndicatesCloudConfigurationAvailable': False})


if __name__ == '__main__':
    main()
