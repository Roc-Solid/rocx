---
title: Małe skrypty powłoki, które na siebie zarabiają
date: 2026-04-04
author: theo-marsh
tags: [kod, narzedzia]
summary: Trzy malutkie skrypty, których używam co tydzień, każdy krótszy niż to streszczenie, i czego nauczyły mnie o automatyzacji.
---
Większość porad o automatyzacji zaczyna się od frameworka. Moja zaczyna się od pliku tekstowego w
`~/bin`. Skryptowi powłoki, który da się przeczytać w dziesięć sekund, wciąż będziesz ufać za dwa
lata i sam go naprawisz, kiedy się zepsuje. Oto trzy, których używam co tydzień.

## Kopia folderu z dzisiejszą datą

Trzymam archiwum notatek i przed każdym większym porządkowaniem robię migawkę. Cały skrypt to jedna
linijka plus zabezpieczenie:

```sh
#!/bin/sh
# snap: kopiuje folder obok niego samego, z dzisiejszą datą w nazwie.
set -eu
src="${1:?który folder?}"
cp -R "$src" "${src%/}-$(date +%Y-%m-%d)"
```

`set -eu` sprawia, że skrypt zatrzymuje się na pierwszym błędzie i na każdej zmiennej, której
zapomniałem ustawić. Fragment `${1:?który folder?}` zatrzymuje go z pomocnym komunikatem, kiedy
zapomnę podać argument.

## Co zjada dysk

Kiedy laptop narzeka na brak miejsca, ten skrypt odpowiada na jedyne pytanie, jakie mam: które
foldery tutaj są duże.

```sh
#!/bin/sh
# big: dziesięć największych rzeczy w bieżącym folderze.
du -sh -- * .[!.]* 2>/dev/null | sort -rh | head -n 10
```

## Zdjęcia nazwane datą zrobienia

Aparaty nazywają pliki `IMG_4031.JPG`, co nic mi nie mówi. Ten skrypt zmienia nazwę każdego zdjęcia
w folderze na jego datę, korzystając z małego narzędzia, które czyta metadane zdjęcia:

```sh
#!/bin/sh
# photos: zmienia nazwy JPEG-ów na chwilę zrobienia, np. 2026-03-28_14-02-11.jpg
set -eu
for photo in *.jpg *.JPG; do
	[ -e "$photo" ] || continue
	exiftool -q '-FileName<DateTimeOriginal' -d '%Y-%m-%d_%H-%M-%S%%-c.%%le' "$photo"
done
```

## Co je łączy

Żaden z tych skryptów nie obsługuje wszystkich przypadków i właśnie o to chodzi. Każdy robi to, czego
potrzebuję, na komputerze, który mam. Kiedy potrzebuję więcej, dopisuję linijkę. W chwili, gdy
skrypt potrzebuje pliku konfiguracyjnego, traktuję to jako znak, że przestałem automatyzować
obowiązek i zacząłem budować produkt.
