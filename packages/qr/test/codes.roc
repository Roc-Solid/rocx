## Prints QR codes as PBM images, for decode.sh to read back with a reader (zbar): each version (1
## to 40) at each level, its text exactly what the version holds (so the version is the one under
## test), a line `# <level> <version> <text>` before each image. Run with the repo's CLI platform.
app [main!] { pf: platform "../../../cli/platform/main.roc", qr: "../main.roc" }

import pf.Stdout
import qr.Qr

main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str)])
main! = |_args| {
	alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-./:ABCDEFGHIJKLMNOPQRSTUVWXYZ".to_utf8()
	for (name, level) in [("L", Low), ("M", Medium), ("Q", Quartile), ("H", High)] {
		var $version = 1
		while $version <= 40 {
			count = Qr.bytes_held($version, level)
			var $bytes = []
			var $i = 0
			while $i < count {
				$bytes = $bytes.append(alphabet.get(($i * 7 + $version) % alphabet.len()) ?? 'x')
				$i = $i + 1
			}
			text = Str.from_utf8_lossy($bytes)
			match Qr.encode(text, level) {
				Ok(code) => {
					Stdout.line!("# ${name} ${$version.to_str()} ${text}")?
					Stdout.line!(Qr.pbm(code))?
				}
				Err(TooLong) => Stdout.line!("# ${name} ${$version.to_str()} too long")?
			}
			$version = $version + 1
		}
	}
	Ok({})
}
