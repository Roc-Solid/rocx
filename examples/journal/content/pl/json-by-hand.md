---
title: Czytanie JSON-a gołym okiem
date: 2026-08-29
author: theo-marsh
tags: [kod, dane]
summary: JSON jest na tyle mały, że da się go przeczytać samemu, jeśli zna się sześć rzeczy, które może zawierać, i miejsca, w których lubi chować kłopoty.
---
Prędzej czy później każdy programista wpatruje się w ścianę nawiasów klamrowych w logu i próbuje
zrozumieć, co poszło nie tak. JSON jest tu przyjemny: cały format mieści się na pocztówce[^pocztowka].
Wartość to jedna z sześciu rzeczy, a kiedy umiesz je rozpoznać, każdy dokument rozpada się na
kawałki, które da się przeczytać.

## Sześć rodzajów wartości

```json
{
  "title": "Znowu nocne pociągi",
  "minutes": 4,
  "draft": false,
  "cover": null,
  "tags": ["podroze", "pociagi"],
  "author": { "id": "hanna-wierzba", "name": "Hanna Wierzba" }
}
```

Napis w cudzysłowie, liczba, `true` albo `false`, `null`, lista w nawiasach kwadratowych i obiekt w
klamrowych, który przypisuje nazwom kolejne wartości. To wszystko. Cała reszta to zagnieżdżanie.

## Gdzie chowają się kłopoty

Większość zepsutego JSON-a, jaki spotykam, jest zepsuta na jeden z kilku sposobów:

- przecinek po ostatnim elemencie listy albo obiektu, na który JSON nie pozwala;
- apostrofy zamiast cudzysłowów, zwykle od kogoś, kto pisał ręcznie;
- liczba, która tak naprawdę jest napisem (`"4"` zamiast `4`), co parsuje się bez problemu i psuje
  się później;
- brakujące pole, którego program potrzebował, co w ogóle nie jest błędem składni.

Ostatni przypadek jest najczęstszy i najtrudniej go zauważyć, bo dokument jest całkowicie poprawny.
To dlatego dobry program mówi, *którego* pola się spodziewał, a nie tylko, że coś się nie udało.

## Jak to uczynić czytelnym

Kiedy dokument przychodzi jako jedna długa linijka, poproś jakieś narzędzie o wcięcia, zanim zaczniesz
czytać:

```sh
curl -s https://journal.example.com/api/posts?lang=pl | python3 -m json.tool | less
```

Potem czytaj od zewnątrz do środka: najpierw kształt (lista? obiekt?), potem nazwy na najwyższym
poziomie, a dopiero na końcu wartości. Tak samo czytałoby się nieznany budynek: najpierw znajdź
drzwi, potem licz okna.

[^pocztowka]: Cała gramatyka jest narysowana jako pięć małych diagramów na stronie domowej formatu, a parser do niego to przyjemne ćwiczenie na weekend.
