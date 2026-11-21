import Catalog
import Intl
import Locales

## Words for what can be wrong with a form's fields, in every starter locale, keyed
## `validation.<key>` by packages/forms' keys (`Issues.key(code)`), in its voice: short, second
## person ("Use at least 3 characters"). `intl.issue(key, params)` says one, given forms'
## `Issues.params(code)`; `intl.error({ code, args })` takes the arguments as `Message.Arg`s. Merge
## the app's own catalog over it to change any of them, or add keys of its own:
##
##     catalog = Catalog.merge(Validation.catalog, Words.catalog)
##     intl.issue(Issues.key(code), Issues.params(code))       # "Wpisz co najmniej 3 znaki"
##
## | Key | Arguments |
## |---|---|
## | `required`, `unchecked` | |
## | `too_short`, `too_long` | `min`, `max`: a count of characters |
## | `no_match`, `not_email`, `not_url`, `not_date`, `not_one_of`, `not_integer`, `not_number` | |
## | `too_small`, `too_large` | `min`, `max`: a number |
## | `not_step` | `below`, `above`: the nearest numbers allowed |
## | `too_early`, `too_late` | `min`, `max`: a day (`2026-01-31`), written as the locale writes dates |
## | `too_few`, `too_many` | `min`, `max`: a count of items |
## | `not_same` | |
Validation := [].{

	catalog : Catalog
	catalog = Catalog.new(
		"en",
		[
			(
				"en",
				[
					("validation.required", "Fill this in"),
					("validation.unchecked", "Tick this box to go on"),
					("validation.too_short", "Use at least {min, plural, one {# character} other {# characters}}"),
					("validation.too_long", "Use {max, plural, one {# character} other {# characters}} or fewer"),
					("validation.no_match", "Use the format asked for"),
					("validation.not_email", "Enter an email address, like name@example.com"),
					("validation.not_url", "Enter a web address, like https://example.com"),
					("validation.not_date", "Enter a date, like 2026-01-31"),
					("validation.not_one_of", "Choose one of the options"),
					("validation.not_integer", "Enter a whole number"),
					("validation.not_number", "Enter a number"),
					("validation.too_small", "Enter {min, number} or more"),
					("validation.too_large", "Enter {max, number} or less"),
					("validation.not_step", "Enter {below, number} or {above, number}, the nearest allowed"),
					("validation.too_early", "Enter {min, date, medium} or later"),
					("validation.too_late", "Enter {max, date, medium} or earlier"),
					("validation.too_few", "Choose at least {min, number}"),
					("validation.too_many", "Choose {max, number} or fewer"),
					("validation.not_same", "These don't match"),
				],
			),
			(
				"de",
				[
					("validation.required", "Bitte ausfüllen"),
					("validation.unchecked", "Kreuzen Sie dieses Feld an, um fortzufahren"),
					("validation.too_short", "Verwenden Sie mindestens {min, plural, one {# Zeichen} other {# Zeichen}}"),
					("validation.too_long", "Verwenden Sie höchstens {max, plural, one {# Zeichen} other {# Zeichen}}"),
					("validation.no_match", "Verwenden Sie das verlangte Format"),
					("validation.not_email", "Geben Sie eine E-Mail-Adresse ein, z. B. name@example.com"),
					("validation.not_url", "Geben Sie eine Webadresse ein, z. B. https://example.com"),
					("validation.not_date", "Geben Sie ein Datum ein, z. B. 2026-01-31"),
					("validation.not_one_of", "Wählen Sie eine der Optionen"),
					("validation.not_integer", "Geben Sie eine ganze Zahl ein"),
					("validation.not_number", "Geben Sie eine Zahl ein"),
					("validation.too_small", "Geben Sie {min, number} oder mehr ein"),
					("validation.too_large", "Geben Sie {max, number} oder weniger ein"),
					("validation.not_step", "Geben Sie {below, number} oder {above, number} ein, die nächsten erlaubten Werte"),
					("validation.too_early", "Geben Sie {min, date, medium} oder später ein"),
					("validation.too_late", "Geben Sie {max, date, medium} oder früher ein"),
					("validation.too_few", "Wählen Sie mindestens {min, number}"),
					("validation.too_many", "Wählen Sie höchstens {max, number}"),
					("validation.not_same", "Die Eingaben stimmen nicht überein"),
				],
			),
			(
				"fr",
				[
					("validation.required", "Remplissez ce champ"),
					("validation.unchecked", "Cochez cette case pour continuer"),
					("validation.too_short", "Utilisez au moins {min, plural, one {# caractère} other {# caractères}}"),
					("validation.too_long", "Utilisez au plus {max, plural, one {# caractère} other {# caractères}}"),
					("validation.no_match", "Utilisez le format demandé"),
					("validation.not_email", "Saisissez une adresse e-mail, par exemple name@example.com"),
					("validation.not_url", "Saisissez une adresse web, par exemple https://example.com"),
					("validation.not_date", "Saisissez une date, par exemple 2026-01-31"),
					("validation.not_one_of", "Choisissez l'une des options"),
					("validation.not_integer", "Saisissez un nombre entier"),
					("validation.not_number", "Saisissez un nombre"),
					("validation.too_small", "Saisissez {min, number} ou plus"),
					("validation.too_large", "Saisissez {max, number} ou moins"),
					("validation.not_step", "Saisissez {below, number} ou {above, number}, les valeurs autorisées les plus proches"),
					("validation.too_early", "Saisissez le {min, date, medium} ou une date ultérieure"),
					("validation.too_late", "Saisissez le {max, date, medium} ou une date antérieure"),
					("validation.too_few", "Choisissez-en au moins {min, number}"),
					("validation.too_many", "Choisissez-en {max, number} au plus"),
					("validation.not_same", "Les valeurs ne correspondent pas"),
				],
			),
			(
				"es",
				[
					("validation.required", "Rellena este campo"),
					("validation.unchecked", "Marca esta casilla para continuar"),
					("validation.too_short", "Usa al menos {min, plural, one {# carácter} other {# caracteres}}"),
					("validation.too_long", "Usa como máximo {max, plural, one {# carácter} other {# caracteres}}"),
					("validation.no_match", "Usa el formato indicado"),
					("validation.not_email", "Introduce una dirección de correo, como name@example.com"),
					("validation.not_url", "Introduce una dirección web, como https://example.com"),
					("validation.not_date", "Introduce una fecha, como 2026-01-31"),
					("validation.not_one_of", "Elige una de las opciones"),
					("validation.not_integer", "Introduce un número entero"),
					("validation.not_number", "Introduce un número"),
					("validation.too_small", "Introduce {min, number} o más"),
					("validation.too_large", "Introduce {max, number} o menos"),
					("validation.not_step", "Introduce {below, number} o {above, number}, los valores permitidos más cercanos"),
					("validation.too_early", "Introduce el {min, date, medium} o una fecha posterior"),
					("validation.too_late", "Introduce el {max, date, medium} o una fecha anterior"),
					("validation.too_few", "Elige al menos {min, number}"),
					("validation.too_many", "Elige como máximo {max, number}"),
					("validation.not_same", "Los valores no coinciden"),
				],
			),
			(
				"pl",
				[
					("validation.required", "Wypełnij to pole"),
					("validation.unchecked", "Zaznacz to pole, aby przejść dalej"),
					("validation.too_short", "Wpisz co najmniej {min, plural, one {# znak} few {# znaki} many {# znaków} other {# znaku}}"),
					("validation.too_long", "Wpisz najwyżej {max, plural, one {# znak} few {# znaki} many {# znaków} other {# znaku}}"),
					("validation.no_match", "Użyj wymaganego formatu"),
					("validation.not_email", "Wpisz adres e-mail, np. name@example.com"),
					("validation.not_url", "Wpisz adres strony, np. https://example.com"),
					("validation.not_date", "Wpisz datę, np. 2026-01-31"),
					("validation.not_one_of", "Wybierz jedną z opcji"),
					("validation.not_integer", "Wpisz liczbę całkowitą"),
					("validation.not_number", "Wpisz liczbę"),
					("validation.too_small", "Wpisz {min, number} lub więcej"),
					("validation.too_large", "Wpisz {max, number} lub mniej"),
					("validation.not_step", "Wpisz {below, number} lub {above, number}, najbliższe dozwolone wartości"),
					("validation.too_early", "Wpisz {min, date, medium} lub późniejszą datę"),
					("validation.too_late", "Wpisz {max, date, medium} lub wcześniejszą datę"),
					("validation.too_few", "Wybierz co najmniej {min, number}"),
					("validation.too_many", "Wybierz najwyżej {max, number}"),
					("validation.not_same", "Wartości się nie zgadzają"),
				],
			),
			(
				"cs",
				[
					("validation.required", "Vyplňte toto pole"),
					("validation.unchecked", "Zaškrtněte toto políčko, abyste mohli pokračovat"),
					("validation.too_short", "Zadejte alespoň {min, plural, one {# znak} few {# znaky} many {# znaku} other {# znaků}}"),
					("validation.too_long", "Zadejte nejvýše {max, plural, one {# znak} few {# znaky} many {# znaku} other {# znaků}}"),
					("validation.no_match", "Použijte požadovaný formát"),
					("validation.not_email", "Zadejte e-mailovou adresu, např. name@example.com"),
					("validation.not_url", "Zadejte webovou adresu, např. https://example.com"),
					("validation.not_date", "Zadejte datum, např. 2026-01-31"),
					("validation.not_one_of", "Vyberte jednu z možností"),
					("validation.not_integer", "Zadejte celé číslo"),
					("validation.not_number", "Zadejte číslo"),
					("validation.too_small", "Zadejte {min, number} nebo více"),
					("validation.too_large", "Zadejte {max, number} nebo méně"),
					("validation.not_step", "Zadejte {below, number} nebo {above, number}, nejbližší povolené hodnoty"),
					("validation.too_early", "Zadejte {min, date, medium} nebo pozdější datum"),
					("validation.too_late", "Zadejte {max, date, medium} nebo dřívější datum"),
					("validation.too_few", "Vyberte alespoň {min, number}"),
					("validation.too_many", "Vyberte nejvýše {max, number}"),
					("validation.not_same", "Hodnoty se neshodují"),
				],
			),
			(
				"ru",
				[
					("validation.required", "Заполните это поле"),
					("validation.unchecked", "Отметьте этот флажок, чтобы продолжить"),
					("validation.too_short", "Введите не менее {min, plural, one {# символа} few {# символов} many {# символов} other {# символа}}"),
					("validation.too_long", "Введите не более {max, plural, one {# символа} few {# символов} many {# символов} other {# символа}}"),
					("validation.no_match", "Используйте требуемый формат"),
					("validation.not_email", "Введите адрес электронной почты, например name@example.com"),
					("validation.not_url", "Введите веб-адрес, например https://example.com"),
					("validation.not_date", "Введите дату, например 2026-01-31"),
					("validation.not_one_of", "Выберите один из вариантов"),
					("validation.not_integer", "Введите целое число"),
					("validation.not_number", "Введите число"),
					("validation.too_small", "Введите {min, number} или больше"),
					("validation.too_large", "Введите {max, number} или меньше"),
					("validation.not_step", "Введите {below, number} или {above, number} — ближайшие допустимые значения"),
					("validation.too_early", "Введите {min, date, medium} или более позднюю дату"),
					("validation.too_late", "Введите {max, date, medium} или более раннюю дату"),
					("validation.too_few", "Выберите не менее {min, number}"),
					("validation.too_many", "Выберите не более {max, number}"),
					("validation.not_same", "Значения не совпадают"),
				],
			),
			(
				"ar",
				[
					("validation.required", "املأ هذا الحقل"),
					("validation.unchecked", "حدد هذا المربع للمتابعة"),
					("validation.too_short", "استخدم {min, plural, zero {# حرف} one {حرفًا واحدًا} two {حرفين} few {# أحرف} many {# حرفًا} other {# حرف}} على الأقل"),
					("validation.too_long", "استخدم {max, plural, zero {# حرف} one {حرفًا واحدًا} two {حرفين} few {# أحرف} many {# حرفًا} other {# حرف}} على الأكثر"),
					("validation.no_match", "استخدم التنسيق المطلوب"),
					("validation.not_email", "أدخل عنوان بريد إلكتروني، مثل name@example.com"),
					("validation.not_url", "أدخل عنوان ويب، مثل https://example.com"),
					("validation.not_date", "أدخل تاريخًا، مثل 2026-01-31"),
					("validation.not_one_of", "اختر أحد الخيارات"),
					("validation.not_integer", "أدخل عددًا صحيحًا"),
					("validation.not_number", "أدخل رقمًا"),
					("validation.too_small", "أدخل {min, number} أو أكثر"),
					("validation.too_large", "أدخل {max, number} أو أقل"),
					("validation.not_step", "أدخل {below, number} أو {above, number}، وهما أقرب قيمتين مسموح بهما"),
					("validation.too_early", "أدخل {min, date, medium} أو تاريخًا لاحقًا"),
					("validation.too_late", "أدخل {max, date, medium} أو تاريخًا سابقًا"),
					("validation.too_few", "اختر {min, number} على الأقل"),
					("validation.too_many", "اختر {max, number} على الأكثر"),
					("validation.not_same", "القيمتان غير متطابقتين"),
				],
			),
			(
				"ja",
				[
					("validation.required", "入力してください"),
					("validation.unchecked", "続行するにはこのボックスをオンにしてください"),
					("validation.too_short", "{min}文字以上で入力してください"),
					("validation.too_long", "{max}文字以内で入力してください"),
					("validation.no_match", "指定された形式で入力してください"),
					("validation.not_email", "メールアドレスを入力してください（例：name@example.com）"),
					("validation.not_url", "ウェブアドレスを入力してください（例：https://example.com）"),
					("validation.not_date", "日付を入力してください（例：2026-01-31）"),
					("validation.not_one_of", "選択肢から選んでください"),
					("validation.not_integer", "整数を入力してください"),
					("validation.not_number", "数値を入力してください"),
					("validation.too_small", "{min, number}以上の値を入力してください"),
					("validation.too_large", "{max, number}以下の値を入力してください"),
					("validation.not_step", "{below, number}または{above, number}（最も近い許容値）を入力してください"),
					("validation.too_early", "{min, date, medium}以降の日付を入力してください"),
					("validation.too_late", "{max, date, medium}以前の日付を入力してください"),
					("validation.too_few", "{min, number}個以上選んでください"),
					("validation.too_many", "{max, number}個以下で選んでください"),
					("validation.not_same", "入力内容が一致しません"),
				],
			),
		],
	)
}

expect Catalog.problems(Validation.catalog) == []
expect Catalog.locales(Validation.catalog).map(|locale| locale.tag()) == ["en", "de", "fr", "es", "pl", "cs", "ru", "ar", "ja"]
expect Catalog.keys(Validation.catalog, "en").len() == 19

say : Locales.Data, Str, List({ name : Str, value : Str }) -> Str
say = |data, key, params| Intl.new(data).with_catalog(Validation.catalog).issue(key, params)

expect say(Locales.en, "too_short", [{ name: "min", value: "1" }]) == "Use at least 1 character"
expect say(Locales.en, "too_long", [{ name: "max", value: "280" }]) == "Use 280 characters or fewer"
expect say(Locales.en, "too_small", [{ name: "min", value: "1500.5" }]) == "Enter 1,500.5 or more"
expect say(Locales.en, "not_same", []) == "These don't match"
expect say(Locales.en_gb, "required", []) == "Fill this in"
expect say(Locales.en, "too_early", [{ name: "min", value: "2026-01-01" }]) == "Enter Jan 1, 2026 or later"
expect say(Locales.pl, "too_short", [{ name: "min", value: "3" }]) == "Wpisz co najmniej 3 znaki"
expect say(Locales.pl, "too_short", [{ name: "min", value: "5" }]) == "Wpisz co najmniej 5 znaków"
expect say(Locales.pl, "too_short", [{ name: "min", value: "22" }]) == "Wpisz co najmniej 22 znaki"
expect say(Locales.pl, "too_late", [{ name: "max", value: "2026-12-31" }]) == "Wpisz 31 gru 2026 lub wcześniejszą datę"
expect say(Locales.ru, "too_short", [{ name: "min", value: "21" }]) == "Введите не менее 21 символа"
expect say(Locales.ru, "too_short", [{ name: "min", value: "8" }]) == "Введите не менее 8 символов"
expect say(Locales.cs, "too_long", [{ name: "max", value: "4" }]) == "Zadejte nejvýše 4 znaky"
expect say(Locales.ar, "too_short", [{ name: "min", value: "2" }]) == "استخدم حرفين على الأقل"
expect say(Locales.ar, "too_short", [{ name: "min", value: "11" }]) == "استخدم 11 حرفًا على الأقل"
expect say(Locales.de, "not_step", [{ name: "below", value: "1000" }, { name: "above", value: "1500" }]) == "Geben Sie 1.000 oder 1.500 ein, die nächsten erlaubten Werte"
expect say(Locales.fr, "too_many", [{ name: "max", value: "3" }]) == "Choisissez-en 3 au plus"
expect say(Locales.ja, "too_short", [{ name: "min", value: "8" }]) == "8文字以上で入力してください"
expect say(Locales.ja, "too_early", [{ name: "min", value: "2026-01-05" }]) == "2026/01/05以降の日付を入力してください"
expect Intl.new(Locales.de).with_catalog(Validation.catalog).error({ code: "too_large", args: [("max", Num(1500.5))] }) == "Geben Sie 1.500,5 oder weniger ein"
expect {
	own = Catalog.new("en", [("en", [("validation.required", "Please fill this in"), ("validation.not_postcode", "Enter a postcode")])])
	intl = Intl.new(Locales.en).with_catalog(Catalog.merge(Validation.catalog, own))
	intl.issue("required", []) == "Please fill this in" and intl.issue("not_postcode", []) == "Enter a postcode" and intl.issue("not_url", []) == "Enter a web address, like https://example.com"
}
