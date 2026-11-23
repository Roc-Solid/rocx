// What a benchmark ran on, for the docs to say under its numbers (site/Ui/Machine.rocx): the
// machine's model, its processor and cores (performance and efficiency ones, on Apple silicon), its
// memory, its storage, its system, and whether it ran on mains power or a battery (a laptop on its
// battery slows down). Read from the system: system_profiler, sysctl, diskutil, sw_vers and pmset on
// macOS; /proc and Node's os elsewhere. Nothing that names the machine or its owner (no host name,
// no serial number).
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { arch, cpus, release, totalmem, type } from "node:os";

/** A command's output, trimmed, or "" when it fails or isn't there. */
function said(command, args) {
	const done = spawnSync(command, args, { encoding: "utf8", timeout: 20_000 });
	return done.status === 0 ? done.stdout.trim() : "";
}

/** Bytes as whole gigabytes: "32 GB". */
const gigabytes = (bytes) => `${Math.round(bytes / 1024 ** 3)} GB`;

function mac() {
	let hardware = {};
	try {
		hardware = JSON.parse(said("system_profiler", ["SPHardwareDataType", "-json"]) || "{}").SPHardwareDataType?.[0] ?? {};
	} catch {}
	const performance = Number(said("sysctl", ["-n", "hw.perflevel0.physicalcpu"])) || 0;
	const efficiency = Number(said("sysctl", ["-n", "hw.perflevel1.physicalcpu"])) || 0;
	const all = Number(said("sysctl", ["-n", "hw.ncpu"])) || cpus().length;
	const disk = said("diskutil", ["info", "/"]);
	const field = (name) => new RegExp(`^\\s*${name}:\\s*(.+)$`, "m").exec(disk)?.[1]?.trim() ?? "";
	const solid = field("Solid State") === "Yes";
	const filesystem = field("Type \\(Bundle\\)");
	const battery = said("pmset", ["-g", "batt"]);
	const source = /'AC Power'/.test(battery) ? "mains" : /'Battery Power'/.test(battery) ? "battery" : "";
	const low = /^\s*(lowpowermode|powermode)\s+1\b/m.test(said("pmset", ["-g"]));
	const power = [source, low ? "Low Power Mode" : ""].filter(Boolean).join(", ");
	return {
		model: [hardware.machine_name, hardware.machine_model && `(${hardware.machine_model})`].filter(Boolean).join(" "),
		cpu: hardware.chip_type || said("sysctl", ["-n", "machdep.cpu.brand_string"]) || cpus()[0]?.model || "",
		cores: performance && efficiency ? `${all} (${performance} performance, ${efficiency} efficiency)` : String(all),
		memory: hardware.physical_memory || gigabytes(totalmem()),
		storage: [solid ? "SSD" : "", filesystem.toUpperCase()].filter(Boolean).join(", "),
		os: `${said("sw_vers", ["-productName"]) || "macOS"} ${said("sw_vers", ["-productVersion"])}`.trim(),
		arch: arch(),
		power,
	};
}

function other() {
	const model = ["/sys/class/dmi/id/product_name", "/sys/firmware/devicetree/base/model"].map((path) => (existsSync(path) ? readFileSync(path, "utf8").replace(/\0/g, "").trim() : "")).find(Boolean) ?? "";
	const pretty = existsSync("/etc/os-release") ? /^PRETTY_NAME="?([^"\n]+)"?$/m.exec(readFileSync("/etc/os-release", "utf8"))?.[1] ?? "" : "";
	return {
		model,
		cpu: cpus()[0]?.model?.trim() ?? "",
		cores: String(cpus().length),
		memory: gigabytes(totalmem()),
		storage: "",
		os: pretty || `${type()} ${release()}`,
		arch: arch(),
		power: "",
	};
}

/** The machine this runs on: `{ model, cpu, cores, memory, storage, os, arch, power }`, "" where unknown. */
export function machine() {
	return process.platform === "darwin" ? mac() : other();
}

/** The machine as one line, for a log: "MacBook Pro (Mac17,2), Apple M5, 10 cores (…), 32 GB". */
export function machineLine(m = machine()) {
	return [m.model, m.cpu, m.cores && `${m.cores} cores`, m.memory].filter(Boolean).join(", ");
}

if (import.meta.url === `file://${process.argv[1]}`) console.log(JSON.stringify(machine(), null, "\t"));
