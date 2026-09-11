# AI Assistant (Previo)

Návrh odpovede a zhrnutie úlohy priamo na detaile úlohy, cez **Google Gemini**.
Nahrádza externý Flask nástroj „Redmine Analytics".

## Čo to robí

**1. Návrh odpovede.** Na detaile úlohy je **vedľa tlačidla „Add comment"**
sekundárne tlačidlo **AI reply suggestion**, ktoré vygeneruje návrh odpovede
a vloží ho do poľa komentára. Text je pred odoslaním editovateľný.

Od v0.6.4 má **vlastný vypínač** (*Zapnúť AI návrh odpovede* v sekcii návrhu
odpovede). Na rozdiel od ostatných funkcií je **zapnutý defaultne** — funkcia
bežala už predtým, než vypínač vznikol, takže default `0` by ju pri nasadení
ticho zhasol. Vypnutie skryje tlačidlo **a zároveň odmietne endpoint**, aby sa
vypnutá funkcia nedala volať priamo a spotrebovávať firemný kľúč.

**2. AI Summarizer.** V lište akcií úlohy (medzi *Upraviť* a *Zapísať čas*, ikona
čarovného prútika) je tlačidlo **AI Summarizer**. Otvorí okno nad úlohou so
zhrnutím **popisu a všetkých verejných komentárov** — zhrnutie sa iba zobrazuje,
nikam sa nevkladá. Okno sa zatvára krížikom, klávesom Esc alebo klikom mimo;
zatvorenie počas generovania požiadavku zruší.

**Jazyk zhrnutia má vlastný prepínač** (v0.7.0). Zhrnutie prichádza v jazyku
z *My account*, ale pod textom je lišta *„Chceš to vo svojom jazyku? Klikni sem."* —
po kliknutí sa objaví výber jazyka a zhrnutie sa hneď pregeneruje. Voľba sa ukladá
**k účtu**, takže platí aj v ďalších úlohách a aj z iného počítača; lišta potom
ponúka *„Chceš iný jazyk?"*. Navrchu zoznamu sú trhy Previa (čeština, slovenčina,
maďarčina, poľština, rumunčina, nemčina, chorvátčina), pod nimi celý zoznam
jazykov Redmine. Vzniklo to preto, že **polovica ľudí má Redmine v angličtine,
aj keď sú Česi alebo Slováci**, a kvôli jednému zhrnutiu si celé rozhranie
prepínať nechcú. Voľba platí **len pre zhrnutie** — návrh odpovede a ostatné
funkcie sa ďalej riadia *My account*.

**3. Create with AI.** Na formulári novej úlohy je **vedľa nadpisu „New issue"**
tlačidlo **Create with AI**, ktoré sa aktivuje, keď je vyplnený názov alebo popis.
Zo stručného zadania (česky, slovensky, anglicky) určí **projekt**, **názov a popis
v angličtine podľa šablóny daného trackera**, tracker, kategóriu, prioritu a **povinné polia**
(v Previu „Project Manager"). Ak zvolená kategória má v Redmine nastavenú zodpovednú osobu,
doplní sa aj riešiteľ. Upozorní aj na **možné duplicity** s odkazmi.

Priebeh je vidieť **pri tlačidle** („Pripravujem návrh úlohy…" + krížik na zrušenie), rovnako
ako pri návrhu odpovede. Čo sa stane potom, závisí od AI:

- **nemá otázky** → formulár sa predvyplní hneď, žiadne okno sa neotvára;
- **potrebuje sa dopýtať** → otvorí sa okno **„AI issue creator"** s návrhom a **každá otázka
  má vlastné políčko na odpoveď**. Po *Prepočítať s odpoveďami* ide celá konverzácia modelu
  znova, takže sa dá dopytovať, kým návrh nesedí.

**Projekt smie zmeniť** — zadanie často nepatrí do projektu, v ktorom užívateľ stojí.
Vtedy to okno výslovne oznámi a predvyplnenie prejde na formulár správneho projektu.

Formulár sa iba **predvyplní** — tlačidlo *Create* vždy klikne človek.

Nahrádza to Gemini Gem v Google Chate, ktorý mal v prompte ručne udržiavaný JSON
zoznam projektov, kategórií a projektových manažérov a zadrôtované šablóny.
Tu sa všetko číta **naživo z Redmine** (šablóny z `global_issue_templates` podľa
trackera), takže sa neudržiava nič a pridanie kategórie sa prejaví samo.
Funkcia má **vlastný vypínač**, aby sa dala nasadiť oddelene od prvých dvoch.

Komentár vždy odosiela užívateľ sám, pod svojím účtom. Plugin do Redmine nikdy
nič nezapíše — úlohu ukladá jadrový `IssuesController#create`.

Každá funkcia má v konfigurácii **vlastný systémový prompt** a **vlastný limit
znakov popisu** (odpoveď 600, zhrnutie 4000 — pri zhrnutí nesie zadanie práve
popis). Hodinový limit volaní je naopak **jeden pre všetky**, lebo sa platí z toho
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

**4. AI issue creator (režim plánu).** V hlavičke, **vľavo od ikonky osoby**, je ikonka
čarovného prútika — alebo klávesová skratka **`Ctrl+Shift+X`** (`⇧⌘X` na Macu), ktorá robí to
isté z akejkoľvek stránky. Otvorí okno, kde úlohu opíšeš vlastnými slovami a vo svojom
jazyku — projekt vyberať nemusíš. AI navrhne **plán**: buď jednu úlohu, alebo
nadradenú úlohu s podúlohami. Plán sa dá doupresniť v konverzácii (doplniť text
alebo odpovedať na otázky) a až **Accept** začne zakladanie.

Úlohy sa predvypĺňajú **jedna po druhej** a „Create" pri každej klikne človek. Po
každom uložení sa nad formulárom (a na detaile úlohy) zobrazí panel *„AI plán:
2 zo 4 založené · Ďalšia: …"* s odkazom na ďalší predvyplnený formulár. Odkaz
znesie aj Ctrl+klik, keď chceš ďalšiu úlohu v novom panelu.

> **Prečo nie všetky formuláre naraz.** `issue[parent_issue_id]` musí v Redmine
> ukazovať na **existujúcu** úlohu, a jej číslo vznikne až tým, že ju človek uloží.
> Poradie je teda vynútené jadrom, nie naším rozhodnutím: najprv nadradená úloha,
> potom podúlohy.

Fronta úloh žije v `sessionStorage` — nedokončený plán patrí **tej karte** a zomrie
s ňou (plus expiruje po dvoch hodinách). Na server sa neukladá nič.

Keď v projekte nemáš právo **spravovať podúlohy** (`manage_subtasks`), AI navrhne
samostatné úlohy a okno to povie — Redmine by inak `parent_issue_id` **ticho**
zahodilo a hierarchia by nevznikla bez akéhokoľvek varovania.

Má vlastný vypínač (*Zapnúť režim plánu*); kým je vypnutý, ikonka prútika sa
v hlavičke nezobrazí.

### Nemenné pravidlo

**Modul vždy len predvyplňuje. Finálne „Create" klikne pri každej úlohe človek.**
Ukladá výhradne jadrový `IssuesController#create`, takže všetky práva a validácie
zostávajú na jadre a plugin do Redmine nezapisuje nič.

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

### Vypínač návrhu odpovede (od v0.6.4)

Selftest overí logiku prepínača, ale nie to, či je checkbox naozaj v administrácii
a či sa uloží. Na to je test proti **živému** Redmine — 13 kontrol vrátane toho, že
po vypnutí zmizne tlačidlo z úlohy a endpoint vráti **403**. Pôvodnú hodnotu
nastavenia si na konci vráti, takže konfiguráciu instancie nemení:

```sh
node extra/suggest_switch_cdp_test.mjs <base> <login> <heslo> <issueId> [port]
```

### Klientske testy

Klientskú časť (okná, XSS, focus trap, fronta) overujú dva jsdom testy, ktoré
spúšťajú **skutočný** `ai_assistant.js` so stubnutým `fetch` — nič nikam nechodí
a nestojí to žiadne volanie do Gemini:

```sh
NODE_PATH=C:/Users/marti/theprevio/node_modules node extra/overlay_test.js   # AI Summarizer
NODE_PATH=C:/Users/marti/theprevio/node_modules node extra/plan_test.js      # režim plánu
```

`plan_test.js` má dve fixtures: okno (plán, karty, konverzácia, XSS, focus trap,
chýbajúce právo na podúlohy) a sprievodcu zakladaním (panel mimo `#all_attributes`,
`parent_issue_id` aj `back_url` v odkaze, preskočenie, zrušenie, expirácia
a **hostilná fronta podstrčená z konzoly**).

> `location.assign` sa v jsdom stubnúť nedá (je unforgeable), takže navigácia sama
> sa netestuje. Overuje sa to, čo pozorovateľné je: stav fronty v `sessionStorage`
> a `href` odkazu „Predvyplniť ďalšiu úlohu".

### Test banneru duplicít cez CDP (od v0.6.3)

Skutočné presmerovanie sa v jsdom otestovať nedá (viď vyššie), a práve na ňom banner
padal. Preto beží proti **živému** Redmine v headless prehliadači:

```sh
# 1. testovací užívateľ (admin s jazykom sk — presne ako ten, kto bug hlásil)
MODE=setup docker compose exec -T --user redmine -e SECRET_KEY_BASE=<key> redmine \
  bin/rails runner -e production - < extra/dup_fixture.rb

# 2. headless prehliadač s CDP
msedge --headless=new --disable-gpu --remote-debugging-port=9351 \
  --user-data-dir=<profil> about:blank &

# 3. test: <base> <login> <heslo> <homeProjectId> <aiProjectId> <dupIssueId> [port]
node extra/dup_cdp_test.mjs http://localhost:3080 re_dup_admin <heslo> 61 59 56482 9351

# 4. uklid
MODE=teardown docker compose exec -T --user redmine -e SECRET_KEY_BASE=<key> redmine \
  bin/rails runner -e production - < extra/dup_fixture.rb
```

24 kontrol: preklad tlačidla, presmerovanie na projekt navrhnutý AI, banner na novom
formulári s označením cudzieho projektu, jednorazovosť, banner bez prepnutia projektu
(regresia), sanitácia podstrčeného obsahu z konzoly, TTL a banner odložený pre iný projekt.

> **Púšťa dve skutočné volania Gemini**, takže berie z hodinového limitu. Odpoveď sa
> hodinu cachuje, takže opakovaný beh s tým istým zadaním je zadarmo.

Serverovú stranu (aké kľúčové slová model vráti, ktorí kandidáti z toho vyjdú a čo
vráti hlavné volanie) zaznamenáva `extra/dup_probe.rb` — je commitnutá práve preto,
aby meranie nemusel nikto robiť znova.

`extra/dup_shot.mjs` je k tomu len pomôcka na screenshot výsledného banneru
(`node extra/dup_shot.mjs <base> <login> <heslo> <homeProjectId> <outPng> [port]`).

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

### Hľadanie duplicít (od v0.6.2 naprieč projektami)

Pri „Create with AI" sa modelu nabídne hŕba otvorených úloh na posúdenie duplicity.
Hľadá sa **vo všetkých projektoch, ktoré daný človek vidí** — nie len v tom z formulára.
Dôvod je ten, pre ktorý vznikol nahlásený bug: „POS Tables 500" má near-verbatim
dvojníka v inom projekte (Connectors) a s filtrom na jeden projekt nemal ako vyjsť,
pričom práve takú duplicitu nikto sám nenájde — cudzie projekty si pred písaním
tiketu neprechádza.

- Kandidáti idú z `Issue.visible`, takže sa neponúkne nič, čo daný človek vidieť nesmie;
  privátne úlohy sú vylúčené vždy.
- Pri **rovnakom** počte zhodných slov má prednosť projekt z formulára. Je to tie-break,
  nie filter — silnejšia zhoda inde ide aj tak vpredu.
- Duplicita mimo projektu, kam sa úloha zakladá, sa v okne označí **názvom projektu**.
- Hľadanie je obyčajné `LIKE` nad názvami (bez fulltext indexu), spojené cez OR a radené
  podľa počtu zhodných slov. Jadrový scope `Issue.like` použiť nemožno — spája slová cez
  AND, takže by sa v názve musela vyskytovať celá veta zo zadania.

#### Banner prežije presmerovanie na iný projekt (od v0.6.3)

Keď model navrhne **iný projekt**, `applyDraft` formulár nevypĺňa — opustí stránku
a ide na `prefillUrl`, aby Redmine prekreslil trackery, kategórie a custom fieldy
podľa nového projektu. Do v0.6.2 tým banner s duplicitami zmizol: `renderDraftNotes`
je až za tým `return`. Chýbal teda práve tam, kde má najvyššiu cenu — trefa v cudzom
projekte je často aj dôvod, prečo model ten projekt navrhol.

Duplicity sa preto pred presmerovaním odložia do `sessionStorage` (rovnaký mechanizmus
ako fronta plánu) a na novom formulári sa vykreslia.

- Čítajú sa **raz** a pri čítaní sa zmažú — ďalšia úloha banner nezdedí. Naviac vypršia
  po piatich minútach: má to prežiť jedno presmerovanie, nie celé sedenie.
- `sessionStorage` je zapisovateľné z konzoly prehliadača, takže obsah prechádza tou
  istou sanitáciou ako fronta plánu (id musí byť číslo, texty sa krátia, `other_project`
  musí byť skutočný boolean) a vykresľuje sa z textových nodov, nikdy nie `innerHTML`.
  Odkaz nikdy nejde z úložiska — skladá ho `issueLink` z čísla úlohy.
- Banner odložený pre iný projekt sa **zahodí**, nie zobrazí: sedel by pri úlohe,
  s ktorou nesúvisí.

### Kód z GitLabu (od v0.6.0)

Pole **Merge request** (formát `link`, vyplnené na 8 770 úlohách, z toho 8 751 je
plná GitLab URL) sa teraz **naozaj načíta** — ak je zapnuté `code_context_enabled`
a je uložený GitLab token so scope `read_api`.

Do promptu potom pribudne:

- hlavička MR (názov, stav, vetvy, autor) a jeho popis,
- **pripomienky z code review** — pri návrhu odpovede často to najcennejšie,
  lebo v Redmine komentároch sa typicky rieši presne to, čo napísal reviewer,
- **diff** s rozpočtom (`code_diff_limit`, default 40 000 znakov; jeden súbor
  smie zabrať najviac štvrtinu, zvyšok sa vypíše len názvami).

Pri **novej úlohe** žiadny MR ešte neexistuje, takže sa namiesto toho hľadá
v kóde podľa anglických kľúčových slov, ktoré model aj tak vyrába pre hľadanie
duplicít. Ktorý repozitár k projektu patrí sa nikde nekonfiguruje — odvodí sa
z toho, kam reálne mieria merge requesty úloh v tom projekte.

**Bezpečnostné poistky** (politika Previa dovoľuje posielať kód do firemného
Gemini; tajomstvá tým pokryté nie sú):

- súbory sa zahadzujú podľa cesty (`.env`, `secrets/`, `*.pem`, `id_rsa`,
  `auth.json`, čokoľvek s *secret*/*credential* v názve) — nie je to teoretické,
  úplne prvý testovací dotaz vrátil `config/secrets/prod/prod.RABBITMQ_…php`,
- v tom, čo prejde, sa prepisujú hodnoty priradení, ktoré vyzerajú ako heslo,
  token či kľúč,
- súbor s blokom privátneho kľúča sa zahodí celý,
- odkaz na MR sa nasleduje **len keď mieri na nakonfigurovaný GitLab host** —
  pole vypĺňa človek a bez tejto kontroly by stačilo zapísať cudziu doménu,
  aby token odišiel tam.

Namerané na 10 posledných úlohách s MR: prompt rastie z priemerných 838 na
19 628 znakov (~4 900 vstupných tokenov na volanie namiesto 210).

Keď je GitLab nedostupný alebo token chýba, sekcia kódu jednoducho nie je
a návrh sa vygeneruje bez nej.

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
