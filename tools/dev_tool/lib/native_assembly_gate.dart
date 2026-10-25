/// Orders native hot-reload toolchain assembly after the app's first frame.
///
/// The dev tool's hot-reload toolchain assembly (the `NativePipelineAssembler`:
/// its toolchain probe, cquery, and the dev-app `bazel build`) is heavy enough
/// to starve the app it just launched on a small machine: the build and the
/// app's startup fight for the same cores, and the app loses — its first frame
/// lands after the first-frame wait has already given up, and every drivable
/// command is refused for the rest of the run.
///
/// So a native run that can reload starts assembly only once the first-frame
/// wait of every launched native session has settled. Settled is any of the
/// wait's own outcomes — the frame rendered, the wait timed out or failed, or
/// the run ended — because all of them complete the future
/// [DeviceSession.waitUntilDrivable] returned, which is the future this waits
/// on. Until assembly starts, reload and restart commands keep waiting on the
/// pipeline's readiness gate, exactly as they do while assembly itself runs.
library;

import 'session_host.dart';

/// Start [assemble] once every launched session's first-frame wait has settled.
///
/// Waits on the futures the launcher kept on [SessionHost.firstFrameWaits] —
/// the futures [DeviceSession.waitUntilDrivable] already returned — adding no
/// second wait, no polling, and no new timer. A run whose sessions never had a
/// VM client waits on nothing: those futures completed at once.
///
/// [startPaused] keeps the run's historical order. The app is held before
/// `main()`, so no frame comes until a debugger resumes it; assembly only
/// needs the VM service, which is already up. Waiting here would stall the
/// reload pipeline — and every reload or restart command waiting on its
/// readiness — until the resume or the wait's own timeout, so assembly starts
/// at once instead.
Future<void> assembleNativeAfterFirstFrame({
  required SessionHost host,
  required bool startPaused,
  required Future<void> Function() assemble,
}) async {
  // A paused app renders nothing until it is resumed, so there is no frame to
  // wait for; the VM service assembly needs is already up.
  if (!startPaused) {
    await host.settleFirstFrameWaits();
  }
  await assemble();
}
