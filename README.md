# Deviazioni GTT

Sei alla fermata. Sul sito di GTT c'è scritto:

> *Da via Asinari di Bernezzo angolo corso Monte Grappa, per via Asinari di
> Bernezzo, piazza Chironi, via Medici, corso Lecce, via Lessona, segue
> percorso normale.*

E tu volevi sapere una cosa sola: **il bus passa ancora di qui?**

Questa app legge quel testo e risponde a quella domanda. Per le linee che
prendi tu, quando glielo chiedi.

<p align="center">
  <img src="docs/img/linea-65.png" width="330"
       alt="La schermata della linea 65: la mappa con le due direzioni e le
            fermate, e la scritta «Adesso il percorso è regolare»">
</p>

Flutter, iOS e Android. Niente server: gli orari e tutti i calcoli stanno
sul telefono. Progetto personale, non ha niente a che vedere con GTT.

---

## La cosa che di solito non funziona

Trasformare quelle righe di prosa in una mappa è il punto in cui questi
progetti muoiono. «Via Roma» a Torino sono decine di posti, e un geocoder
lasciato libero ti manda a Collegno con la faccia seria.

Il trucco è non lasciarlo libero: i toponimi si cercano **solo entro un
chilometro dal percorso di quella linea lì**. Il vincolo fa quasi tutto il
lavoro — sui toponimi veri degli avvisi di GTT la risoluzione è 150 su 150,
e le vie estranee alla linea finiscono a 1,3 km o più, cioè si scartano da
sole.

Poi il percorso ricostruito passa cinque prove prima di essere disegnato.
Se una non torna, l'app te lo dice e ti mostra il testo di GTT. Meglio
nessuna mappa che una mappa sbagliata: un falso positivo ti fa camminare
ottocento metri per niente, e la volta dopo non ci credi più.

## Cosa ci fai

**Le fermate che saltano, e dove andare al loro posto.** È la cosa che
serve davvero e che GTT non dice quasi mai. Tu non stai su una via, stai a
una fermata.

**Guardare dove sono i mezzi adesso.** Per un minuto, per dieci, o finché
non ti stufi, con i bus che si muovono sulla mappa. Serve a una cosa che
nessun'altra fonte sa dirti: se la deviazione **è già finita**. GTT
annuncia quando cominciano, quasi mai quando smettono.

**Sapere cosa comincerà.** Un quinto delle variazioni pubblicate non è
ancora in vigore. L'app le tiene da parte — «comincia dopodomani» — invece
di allarmarti oggi per il 24 agosto.

E in fondo a ogni scheda c'è sempre **il testo originale di GTT**. Se il
sistema sbaglia, il dato grezzo è lì e te lo leggi da solo.

## Cosa non ci fai

Meglio dirlo subito che farlo scoprire:

**Non ti manda notifiche.** iOS non regge il polling in background, e
metterci un server sarebbe tradire il resto del progetto. Devi aprirla tu.

**Le distanze alle fermate alternative sono in linea d'aria**, non a piedi.
L'app lo scrive ogni volta, perché a Torino un fiume o una ferrovia
cambiano tutto.

**Dentro una direzione guarda solo la variante principale.** Se una
deviazione riguardasse la sola corsa limitata, il calcolo verrebbe fatto
sul percorso intero.

**Non indovina mai.** Se un toponimo non si risolve, lo dice. Se non ha
visto nessun mezzo, dice «non ho visto nessun mezzo» e non «va tutto
bene». «Non lo so» è una risposta, e va detta come tale.

## Provarla

Serve [Flutter](https://docs.flutter.dev/get-started/install) (Dart ≥ 3.12).

```bash
git clone https://github.com/TCdesign-dev/gtt-deviazioni.git
cd gtt-deviazioni/app && flutter pub get && flutter run
```

Al primo avvio scarica gli orari di GTT — 24 MB — e poi non ci pensa più
per una settimana. Aggiungi le linee che prendi e tocca **Controlla**.

Per leggere il testo degli avvisi serve una chiave
[OpenRouter](https://openrouter.ai/keys): si incolla nelle impostazioni e
**resta sul telefono**. Il modello predefinito è gratuito, con cinquanta
richieste al giorno — ed è il motivo per cui puoi controllare una linea
sola invece di tutte.

Su **Android** fai `flutter build apk` e l'hai finita: niente licenze,
niente store. Su **iOS** con un Apple ID gratuito la firma scade dopo sette
giorni; per darla ad altri serve il programma a pagamento di Apple.

## Se ci vuoi mettere le mani

C'è una regola sola, e regge tutto il resto:

> **`app/lib/core/` è Dart puro.** Nemmeno un `import 'package:flutter/…'`.

Da lì viene il resto: la logica si testa in millisecondi senza simulatore,
e l'interfaccia si può buttare via e rifare senza toccarla.

```bash
cd app && flutter test      # 206 test
cd app && flutter analyze
```

I test sulle fonti girano **offline su dati veri**: il feed e la pagina di
GTT del 31 luglio 2026 stanno in `app/test/fixtures/`.

Prima di cambiare qualcosa, leggi **[`CLAUDE.md`](CLAUDE.md)**. Non è
documentazione di cortesia: ci sono le misure vere, il perché delle scelte,
i sette punti in cui il progetto originale si è rivelato sbagliato, e le
trappole che sono già costate tempo — quella volta che il confronto per
sottostringhe ha fatto scattare «lavori **strada**li» sul capolinea
«**STRADA** del Drosso», per dire.

Due cose che vale la pena sapere prima di aprire una PR:

1. **Le soglie si tarano misurando.** Gli script in `scripts/` e
   `app/tool/` servono a questo. Se un numero non ti torna, rimisuralo — ma
   rimisuralo davvero.
2. **Dichiarare l'incertezza non è una sconfitta.** È la ragione per cui
   questa cosa si può usare.

Le altre carte: [`app/ARCHITETTURA.md`](app/ARCHITETTURA.md) per i moduli,
[`docs/FASE-0-RISULTATI.md`](docs/FASE-0-RISULTATI.md) per le misure sulle
fonti di GTT, e [`docs/`](docs/) per la specifica originale — che però non
è la verità, vedi sopra.

## Grazie a

I dati sono di **GTT S.p.A.**, [open data](https://www.gtt.to.it/cms/openday/open-data)
in **CC-BY**: vanno citati, ed è il minimo. Le mappe sono di
**OpenStreetMap** (ODbL), il routing lo fa **Valhalla** ospitato da
[FOSSGIS](https://valhalla1.openstreetmap.de/), gli indirizzi
**[Photon](https://photon.komoot.io/)** di Komoot.

Photon e Valhalla sono servizi offerti per cortesia. L'app fa pause fra le
chiamate, si presenta con uno User-Agent riconoscibile e ha sempre un
ripiego se cadono. Se ci costruisci sopra qualcosa di serio, ospitateli.

Il codice è **MIT** — vedi [`LICENSE`](LICENSE). Vale per il codice, non
per i dati.
