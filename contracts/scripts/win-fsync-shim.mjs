// Windows-only preload for the Programmable CLI: Windows refuses fsync on a directory handle (EPERM), which the CLI
// does after every atomic write. This ignores only that error so `pack` and `validate` can run locally.
// It does not modify the installed CLI. For the real `submit`, prefer running the CLI on Linux, macOS or WSL.
//   node --import ./scripts/win-fsync-shim.mjs "<npm root -g>/@programmable/launch/bin/programmable-launch.mjs" pack ...
import { open } from "node:fs/promises";

if (process.platform === "win32") {
  const probe = await open(process.execPath, "r");
  const prototype = Object.getPrototypeOf(probe);
  await probe.close();
  const originalSync = prototype.sync;
  prototype.sync = async function sync() {
    try {
      return await originalSync.call(this);
    } catch (error) {
      if (error?.code === "EPERM") return undefined;
      throw error;
    }
  };
}
