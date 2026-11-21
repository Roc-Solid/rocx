import { analyse, binaryen } from "/tmp/rocx-split/repo/src/split.mjs";
import * as split from "/tmp/rocx-split/repo/src/split.mjs";
import { readFileSync } from "node:fs";
const F = process.argv[2];
// reuse the module's internals through a small re-implementation: parse references of both objects
const mod = await import("/tmp/rocx-split/repo/src/split.mjs");
