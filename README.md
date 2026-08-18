# AI Assistant (Previo)

Návrh odpovede a zhrnutie úlohy priamo na detaile úlohy, cez **Google Gemini**.
Nahrádza externý Flask nástroj „Redmine Analytics".

## Čo to robí

**1. Návrh odpovede.** Na detaile úlohy je **vedľa tlačidla „Add comment"**
sekundárne tlačidlo **AI reply suggestion**, ktoré vygeneruje návrh odpovede
a vloží ho do poľa komentára. Text je pred odoslaním editovateľný.

**2. AI Summarizer.** V lište akcií úlohy (medzi *Upraviť* a *Zapísať čas*, ikona
čarovného prútika) je tlačidlo **AI Summarizer**. Otvorí okno nad úlohou so
zhrnutím **popisu a všetkých verejných komentárov** — zhrnutie sa iba zobrazuje,
nikam sa nevkladá. Okno sa zatvára krížikom, klávesom Esc alebo klikom mimo;
zatvorenie počas generovania požiadavku zruší.

Komentár vždy odosiela užívateľ sám, pod svojím účtom. Plugin do Redmine nikdy
nič nezapíše.

Každá funkcia má v konfigurácii **vlastný systémový prompt** a **vlastný limit
znakov popisu** (odpoveď 600, zhrnutie 4000 — pri zhrnutí nesie zadanie práve
popis). Hodinový limit volaní je naopak **jeden pre obe**, lebo sa platí z toho
istého firemného kľúča.

### Umiestnenie tlačidiel (a prečo to rieši JS)

**AI Summarizer:** lišta *Upraviť / Zapísať čas / Sledovať / Kopírovať* je Redmine
partial `issues/_action_menu` a **hook v nej žiadny nie je**, takže sa do nej
serverovo dostať nedá. Tlačidlo sa renderuje v `view_issues_show_details_bottom`
(vždy viditeľný blok detailu) a JS ho presunie pred *Zapísať čas*. Je to `<a
class="icon">`, nie `<button>` — téma Previo štýluje `.contextual a.icon`, takže
vzhľad zdedí, a pred plošným štýlovaním `<button>` téma výslovne varuje. Ikonka je
inline SVG, lebo v Redmine sprite (224 symbolov) prútik ani iskričky nie sú.

**AI reply suggestion:**

Tlačidlo **„Add comment" nie je z Redmine** — vytvára ho plugin
`redmine_rich_editor` (`.re-comment-submit` v `.re-comment-box` pod `#history`),
a to až JS-om po načítaní stránky.

Formulár úlohy má v Redmine jediný hook, a ten je pod poľom na komentár
(`view_issues_edit_notes_bottom`) vo **skrytom** `#update`. Tlačidlo sa preto
renderuje tam a JS ho presunie k „Add comment" — vďaka tomu je viditeľné aj bez
klikania na Upraviť. Keďže cieľ vzniká asynchrónne, použitý je `MutationObserver`
(s časovým stropom, aby nevisel navždy). Ak by Rich Editor aktívny nebol,
tlačidlo zostane na mieste — na spodné Odoslať sa neposúva, tam nemá zmysel.

Vizuál kopíruje sekundárne tlačidlá témy Previo (Edit / Log time / Watch / Copy):
biele, rámik `--previo-grey200`, radius 8, hover inset tieň. Veľkosť je rovnaká
ako „Add comment" (min-height 34 px, padding 0 20 px), aby sedeli v jednej línii.

## Inštalácia

```sh
docker compose restart redmine
docker compose exec --user redmine -e SECRET_KEY_BASE=<key> redmine \
  rake redmine:plugins:migrate RAILS_ENV=production
```

`SECRET_KEY_BASE` treba dodať aj pre `rake`, aj pre `rails runner` — entrypoint
obrazu ju exportuje len hlavnému procesu.

Potom **Administrácia → Pluginy → AI Assistant → Konfigurovať**:

1. vlož **Gemini API kľúč** (získaš na [aistudio.google.com](https://aistudio.google.com)),
2. zaškrtni **Zapnúť AI asistenta**.

Kým nie je splnené oboje, plugin je neaktívny a do Gemini sa neodošle nič.

## Jeden spoločný kľúč, len pre adminov

Kľúč je **jeden pre celé Previo** a zadáva ho výhradne administrátor v konfigurácii
pluginu. Stránka nastavení pluginu je v Redmine dostupná len adminom (overené:
neadmin dostane 403 na GET aj 422 na POST).

### Kľúč sa nedá prečítať cez Inspect element

Toto je vedomé opatrenie, nie samozrejmosť. Bežný vzor

```erb
password_field_tag 'api_key', settings['api_key']   # ← ŠPATNE
```

vykreslí `<input type="password" value="SKUTOCNY_KLUC">`. `type="password"` maskuje
kľúč **len vizuálne** — v HTML zdroji je celý a vidno ho cez Inspect element aj
View source. Preto tu:

- pole na kľúč sa renderuje **vždy prázdne**, hodnota sa do prehliadača neposiela
  nikdy (ani ciphertext),
- v administrácii sa zobrazujú len **posledné 4 znaky** („Kľúč je nastavený (a1b2)"),
- **prázdne pole kľúč nezmaže** — znamená „nechaj existujúci". Na zmazanie je
  samostatný checkbox.

Aby prázdne pole kľúč neprepísalo, plugin robí `prepend` na
`SettingsController#plugin` (`lib/redmine_ai_assistant/key_store.rb`) — Redmine na
ukladanie pluginových nastavení hook nemá. Patch je obmedzený výhradne na tento
plugin podľa `params[:id]`.

Kľúč je v nastaveniach uložený **šifrovane** (`ActiveSupport::MessageEncryptor`,
kľúč odvodený zo `secret_key_base`) a je vo `filter_parameters`, takže sa nedostane
do Rails logu.

> ⚠️ Bezpečnosť stojí na `secret_key_base`. Lokálny `docker-compose.yml` má slabý
> `REDMINE_SECRET_KEY_BASE` — pre lokálny klon to stačí, pre reálne nasadenie musí
> byť silný a mimo gitu. Pri jeho zmene sa uložený kľúč už nedá dešifrovať a admin
> ho musí vložiť znova.

## Self-test

```sh
docker compose exec --user redmine -e SECRET_KEY_BASE=<key> redmine \
  rails runner plugins/redmine_ai_assistant/extra/selftest.rb <login>
```

Overí šifrovanie, ukladanie kľúča (prázdne pole / nový kľúč / zmazanie), **že kľúč
nie je v HTML**, gating, GDPR filtre v oboch smeroch, routy, lokalizácie, render
partialov a HTTP cestu ku Gemini (jedno volanie s neplatným kľúčom). Nastavenia
pluginu na konci vráti do pôvodného stavu; do Redmine nič nezapíše.

⚠️ **`--user redmine` je dôležité.** `docker compose exec` beží ako root, kým Puma
ako `redmine`. Bez toho vzniknú v `tmp/cache` súbory vlastnené rootom, ktoré appka
nedokáže prepísať. Ak sa to už stalo:
`docker compose exec --user root redmine chown -R redmine:redmine /usr/src/redmine/tmp`

## GDPR

Obsah úloh a komentárov **opúšťa Redmine** a ide do Google Gemini mimo EU. Plugin
preto:

1. Je **default vypnutý** — zapnúť ho môže len administrátor a len spolu s vložením
   kľúča.
2. **Nikdy** neposiela privátne poznámky (`private_notes`) — ani keď na ne má
   užívateľ právo.
3. **Nikdy** neposiela privátne úlohy (`is_private`) — tlačidlá sa na nich
   nezobrazia.
4. Obmedzuje počet volaní na užívateľa za hodinu.

**Otvorená otázka, ktorá nie je technická:** či má Previo uzavretú zmluvu
o spracovaní údajov s Googlom a či je odosielanie obsahu Redmine tretej strane
v súlade s internými pravidlami. Do vyriešenia odporúčam nechať plugin vypnutý.

## Kontext pre AI

Posiela sa: číslo a názov úlohy, stav, priorita, zadávateľ, riešiteľ, popis
(skrátený) a **všetky verejné komentáre** — ich počet sa nenastavuje. Namerané
na produkčných dátach: priemer 3,4 komentára na úlohu, p95 = 11, maximum 79.
Interný strop 60 000 znakov je len poistka proti patologickému prípadu.

Popis sa skracuje (default 600 znakov), lebo maximum v produkcii je 91 000 znakov
(niekto vložil do zadania log).

Ďalej sa posielajú súvisiace **natívne changesety** (commit ↔ úloha cez `#1234`).

### Čo NIE je v kontexte: merge requesty

Pole **Merge request** (`cf_67`, formát `link`, vyplnené na 8 087 úlohách) Redmine
len vykreslí ako odkaz — jeho obsah **nikdy nenačíta**. Do AI teda nejde ani popis
MR, ani diff, ani diskusia či stav pipeline.

Čiastočne to zachraňujú merge commity: GitLab do nich píše názov vetvy, názov MR
a `See merge request …!NNNN`. V produkcii má 1 658 changesetov odkaz na MR
a 6 296 je merge commitov, takže hlavička MR sa do kontextu často dostane sama.

Na skutočné čítanie MR by bolo treba volať GitLab API (token + nový klient).

## Gemini API

- `POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`
- Kľúč ide **hlavičkou `x-goog-api-key`**, nie ako `?key=` v URL — inak by skončil
  v access logoch, proxy logoch a v Rails logu request path.
- Default model **`gemini-3.6-flash`**, nastaviteľný v administrácii.
- `max_tokens` sa u modelov s uvažovaním delí medzi uvažovanie a odpoveď, preto je
  default 2048 a nižšie ako 1024 sa neodporúča (prichádzala by prázdna odpoveď
  s `finishReason: MAX_TOKENS`).
- Ošetrené: neplatný kľúč, prekročená kvóta, blokovanie bezpečnostnými filtrami
  (`promptFeedback.blockReason`, `finishReason: SAFETY`), timeout, nedostupnosť.
  Chyby idú ako HTTP 4xx/5xx s čitateľnou správou, nikdy ako text návrhu.

Návrh sa cachuje per úloha + posledný komentár na hodinu, takže opakované kliknutie
bez zmeny v úlohe nevygeneruje nové (platené) volanie. Volania platí Previo zo
spoločného kľúča — preto je hodinový limit na užívateľa dôležitý.

## Licencia

Copyright (C) 2026 Martin Kopáč

GPL-2.0-or-later, rovnako ako Redmine — viď [LICENSE](LICENSE).
