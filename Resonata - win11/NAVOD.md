# Resonata pro Windows — návod

Přehrávač na pravém okraji obrazovky, kousek pod horním rohem: úzký výstupek
s obalem, názvem skladby a pruhy. Ukazuje, co zrovna hraje,
texty písní, poznámky, zástupce aplikací, časovač a polici na soubory.
Kdo chce, zapne si i limity a stav Claude Code a Mistral Vibe.

Zvuk počítače **neposlouchá**. Co hraje, ví ze systémového „právě hraje“, odkud
to čte i panel médií ve Windows. Funguje se Spotify, s prohlížečem a s většinou
dalších přehrávačů.

## Instalace

1. Z [vydání na GitHubu](https://github.com/Durik24/Resonata/releases/tag/win-v1.4.0)
   stáhni `Resonata-Setup-1.4.0.exe` a spusť ho. Je pro počítače s procesorem
   Intel nebo AMD. Na počítači s procesorem ARM (třeba Snapdragon X) běží taky,
   jen přes emulaci a pomaleji; verze 1.4.0 vlastní Setup pro ARM nemá.
2. Když se objeví modré okno SmartScreen, klikni na **Další informace** a pak
   **Přesto spustit**. Instalátor není podepsaný placeným certifikátem.
3. Windows se zeptá, jestli povolit aplikaci od **neznámého vydavatele**.
   Ukáže to u každého nepodepsaného programu, potvrď to a projdi průvodce.

> **Inteligentní řízení aplikací (Smart App Control):** Setup stažený z GitHubu
> se na našem počítači se zapnutou ochranou nainstaloval bez potíží. Windows
> ale soubory posuzuje podle jejich pověsti, takže to jinde dopadnout může jinak.
> Pokud ho zablokuje, tlačítko „Přesto spustit“ tam není a výjimku pro jednu
> aplikaci Windows nedovolí. Ochranu kvůli tomu nevypínej, zapnout jde zpátky
> až po přeinstalaci Windows. Počkej radši na podepsanou verzi.

Aplikace je ve výchozím stavu anglicky, češtinu zapneš v **Settings → Language**
(projeví se po restartu Resonaty).

Resonata se nainstaluje do `C:\Program Files\Resonata`, přidá se do nabídky Start
a do ikon u hodin a bude se spouštět po přihlášení (jde to vypnout v nastavení).

## Aktualizace

Stačí spustit **novější `Resonata-Setup`**. Starou verzi není potřeba mazat:
Setup Resonatu sám zavře, přepíše ji a znovu spustí. Poznámky a nastavení zůstanou.

Resonata se jednou denně podívá, jestli je nová verze. Když ano, oznámí to
a v nastavení nebo v nabídce u ikony ji jde stáhnout a spustit jedním kliknutím.
Sama si vybere Setup pro procesor tvého počítače.

## Odinstalace

V **Nastavení Windows → Aplikace → Resonata → Odinstalovat**, nebo tlačítkem na
konci nastavení Resonaty. Odinstalátor se zeptá, jestli smazat i poznámky,
úkoly a nastavení. Výchozí odpověď je Ne.

## Jak se ovládá

| Co udělat | Co se stane |
|---|---|
| Najet myší na výstupek na pravém okraji a chvíli počkat | Otevře se velký panel |
| Kliknout na výstupek | Otevře se velký panel, bez čekání |
| Kliknout na prázdné místo v horním pruhu panelu | Panel se zavře |
| **Ctrl + Shift + Mezerník** | Otevře nebo zavře panel odkudkoliv (v nastavení jde přepnout na Alt + Shift + N) |
| Levý klik na ikonu u hodin | Otevře nebo zavře panel |
| Pravý klik na ikonu nebo na výstupek | Nabídka: nastavení, spuštění po přihlášení, ukončení |
| Kliknout kamkoliv mimo panel | Panel se zavře |
| Kolečko dolů na výstupku | Otevře panel |
| Kolečko nebo dva prsty nahoru a dolů v panelu | Další nebo předchozí stránka |
| Dva prsty do strany na touchpadu | Na výstupku další/předchozí skladba, v panelu další stránka |
| Přetáhnout soubor k pravému okraji | Otevře se police, soubor na ni pustíš |

V **Settings → Open the panel** jsou dva režimy:

Panel se otevře jako okénko na výšku kousek od okraje a obal alba do něj
vyletí z výstupku. Stránky jsou pod sebou.

- **Hover** (výchozí): když na výstupku chvíli zůstaneš, panel se otevře sám.
  Dokud na něm přepínáš skladby, počká.
  Když myší odjedeš, zavře se. Během psaní poznámky zůstane otevřený.
- **Click**: najetí na výstupek jen ukáže, co hraje. Kliknutí panel otevře,
  další kliknutí mimo panel nebo na prázdné místo v jeho horním pruhu ho zavře.

**Když se nic neděje**, tedy nic nehraje, neběží časovač a nepracuje žádná
relace Claude Code ani Vibe, výstupek po půl minutě zajede celý. Vrátí se, když
se něco stane, nebo když kurzorem najedeš na jeho místo úplně u okraje
obrazovky. Vypíná se to v **Settings → Sliding out → Hide the tab while nothing
is going on**.

Výstupek se sám na chvíli rozšíří do pruhu, který řekne víc: při nové skladbě, po skončení časovače,
5 minut před událostí, při připojení Bluetooth sluchátek, při zapojení nabíječky
a při slabé baterii. Všechno jde vypnout v nastavení. Ve hrách a filmech přes
celou obrazovku se sama nevysouvá.

## Stránky panelu

- **Hudba**: obal, název, text písně, posuvník, ovládání a kalendář. Když hraje
  Spotify, je tu i posuvník jeho hlasitosti. Hýbe přímo posuvníkem ve Spotify,
  po 10 %, takže funguje i když Spotify hraje přes Spotify Connect do telefonu
  nebo do reproduktoru. Ostatní zvuk počítače zůstane. Spotify musí mít otevřené
  okno, klidně minimalizované. Bez okna se posuvník vrátí ke směšovači hlasitosti
  Windows a mění Spotify jen v tomhle počítači.
- **Poznámky a úkoly**: ukládá se průběžně a jen u tebe v počítači.
- **Aplikace**: až 11 zástupců. Přidáš je tlačítkem +, řadíš v nastavení.
- **Časovač**: 5–60 minut jedním klepnutím, libovolná délka v kruhu, nebo Pomodoro.
- **Police**: soubory si tu odložíš a pak je odtáhneš, kam potřebuješ. Kliknutím
  se otevřou. Ukládá se jen cesta, ne kopie souboru.
- **Limity**: jen se zapnutým Claude Code nebo Vibe, viz níž.

## Claude Code a Mistral Vibe

Volitelné a ve výchozím stavu vypnuté. Zapínají se každý zvlášť v **Settings →
Claude Code and Mistral Vibe**.

- Na výstupku přibude kroužek a výstupek se o něj prodlouží. Kroužek ukazuje,
  kolik z limitu je využito. Točí se, dokud nějaká relace pracuje, a je
  jantarový, když na tebe čeká.
- Když se relace na něco zeptá nebo dokončí delší práci, vysune se zpráva.
  Kliknutí na ni přepne do aplikace, kde relace běží.
- V panelu přibude stránka **Limity**: limit relace a týdne, kdy se obnoví,
  a seznam relací.
- Když nic nehraje, limity se ukážou na výstupku i na stránce Hudba místo
  prázdného obalu. Jakmile začne hrát hudba, místo si vezme zpátky.

Čte se jen z tohohle počítače. U Claude Code ze souborů relací a limity z jeho
vlastního `/usage`: k tomu musí být nainstalovaný a přihlášený příkaz `claude`.
Samotná desktopová aplikace Claude dá stavy relací a zprávy, limity ne. U Vibe
se limit ptá vlastní kód a přihlášení Vibe. Resonata žádný klíč ani přihlášení
nevidí a neukládá. Část pro Vibe je napsaná podle verze pro Mac a na Windows
zatím nebyla vyzkoušená.

## Kalendář

Windows nenabízí kalendář, který by běžná aplikace mohla jen tak přečíst, proto
Resonata čte odkaz ve formátu `.ics`. Vložíš ho v **Settings → Calendar**, každý
na vlastní řádek.

- **Google Kalendář**: nastavení kalendáře → *Tajná adresa ve formátu iCal*.
- **Outlook**: Nastavení → Kalendář → Sdílené kalendáře → Publikovat kalendář.

Tajný odkaz je jako heslo ke čtení kalendáře, nikomu ho nedávej. Resonata ho
ukládá do svého nastavení v počítači. Kalendář jen čte a obnovuje se po 15 minutách.

## Kde co je

| Co | Kde |
|---|---|
| Program | `C:\Program Files\Resonata` |
| Poznámky, nastavení, záznam chyb | `%APPDATA%\Resonata` |
| Uložené texty písní | `%LOCALAPPDATA%\Resonata\Cache` |

## Když to nefunguje

**Nic se nevysouvá.** Podívej se na ikonu u hodin (může být schovaná pod šipkou)
a zkus zkratku. V nastavení zkontroluj *Show the tab on the right edge of the screen*.
Když se nic neděje, výstupek po půl minutě zajede: najeď kurzorem úplně na okraj.

**Ukazuje „Nic nehraje“, i když hudba hraje.** Přehrávač se nehlásí do systému.
Podívej se, jestli ho vidíš v panelu hlasitosti ve Windows.

**Posuvník ve Spotify neposouvá skladbu.** Záleží na tom, jestli to přehrávač
povolí. Zbytek ovládání to neovlivní.

**Zkratka nefunguje.** Možná ji používá jiná aplikace. V nastavení vyber jinou.

Co se pokazilo, bývá v `%APPDATA%\Resonata\resonata.log`.

## Pro vývojáře

Viz [README.md](README.md).
