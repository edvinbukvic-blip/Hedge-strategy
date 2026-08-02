# Hedge Strategy – MT5

Ovaj repozitorij služi za razvoj, testiranje i verzionisanje automatizovane trading strategije za MetaTrader 5.

Glavni cilj je da se strategija razvija postepeno, bez ponovnog pisanja kompletnog koda pri svakoj izmjeni. Svaka nova funkcija, ispravka ili promjena logike treba biti jasno evidentirana kroz Git commit historiju.

## Sadržaj projekta

- MT5 Expert Advisor fajlovi (`.mq5`)
- Pomoćni include fajlovi (`.mqh`)
- Dokumentacija strategije
- Evidencija izmjena
- Testne verzije i stabilna izdanja

## Pravila razvoja

- `main` branch predstavlja stabilnu verziju strategije.
- Nove funkcije i veće izmjene rade se na zasebnim branchovima.
- Postojeća trading logika se ne mijenja bez jasnog zahtjeva.
- Svaka izmjena treba imati razumljiv commit opis.
- Prije korištenja na realnom računu potrebno je izvršiti backtest i forward test.

## Planirana struktura

```text
Hedge-strategy/
├── Experts/
│   └── HedgeStrategy.mq5
├── Include/
├── Tests/
├── CHANGELOG.md
└── README.md
