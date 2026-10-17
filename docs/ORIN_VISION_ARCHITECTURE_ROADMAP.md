# Orin — Verifiable Software Engineering for the AI Era

> **Produktvision, technische Zielarchitektur und Implementierungsfahrplan**  
> Stand: 13. Oktober 2026 · Status: Designvorschlag, nicht vollständig implementiert  
> Repository: https://github.com/orin-lang/orin-lang

## Executive Summary

**Orin ist eine native, statisch typisierte, TypeScript-nahe Sprache für Software, die überwiegend von KI-Agenten implementiert, von Menschen fachlich verantwortet und durch Maschinen nachvollziehbar geprüft wird.**

Das Produktversprechen lautet nicht „KI schreibt automatisch fehlerfreie Software“. Es lautet:

> **AI-written. Human-understandable. Machine-verifiable. Native-fast.**

Ein Orin-Build soll langfristig neben dem Executable einen präzisen, reproduzierbaren Nachweis erzeugen: welche fachlichen Anforderungen implementiert wurden, welche Properties beweisbar gelten, welche Capabilities jede Funktion und jedes Feature benötigt, wie vertrauliche Daten durch das Programm fließen, welche Änderungen eine PR tatsächlich bewirkt und welche Vertrauensannahmen offen bleiben.

**Leitprinzip:** *As explicit as necessary for verification; as automatic as possible for implementation.* Boilerplate ist akzeptabel, wenn es zusätzliche, maschinenprüfbare Bedeutung trägt. Redundante Deklarationen ohne zusätzliche Aussage sind zu vermeiden.

**Entscheidende Abgrenzung:** Formal bewiesene Properties sind nicht automatisch vollständige oder richtige Geschäftsanforderungen. Unbekannte Eigenschaften, externe Abhängigkeiten und unbewiesene Behauptungen müssen sichtbar bleiben. Orin darf niemals „UNKNOWN“ zu „VERIFIED“ aufwerten.

---

## 1. Problem, Zielgruppe und Erfolgskriterien

### 1.1 Das Problem

KI-Agents können große Änderungen in kurzer Zeit erzeugen. Klassische Code-Reviews skalieren schlecht: 10.000 geänderte Zeilen helfen einem Fachverantwortlichen kaum dabei, zu erkennen, ob eine Rückerstattung fachlich korrekt implementiert ist, Daten an neue Empfänger gelangen oder ein Modul plötzlich zusätzliche Rechte benötigt.

Heutige Artefakte sind getrennt: Requirements, Tickets, Source, Tests, UML, Security Policies, Infrastrukturkonfiguration, Audit-Berichte. Sie können einander widersprechen, ohne dass der Compiler die Diskrepanz erkennt.

### 1.2 Zielbild

Der Standard-Review einer Änderung beantwortet zuerst:

1. Welche **Features und fachlichen Verhaltensweisen** ändern sich?
2. Welche **Daten, Felder, Zustände und Empfänger** sind betroffen?
3. Welche **Capabilities** werden jetzt benötigt, vorher nicht und warum?
4. Welche **Contracts/Invarianten** sind bewiesen, verletzt, offen oder nur angenommen?
5. Welche **Anforderungen und Freigaben** wurden ergänzt, abgeschwächt oder entfernt?
6. Welche **externen Systeme, Runtime-Parameter und Deployment-Profile** beeinflussen die Aussage?
7. Welches **konkrete Source-/Compiler-/Artifact-Set** ist von den Nachweisen abgedeckt?

Ein Entwickler soll in die genaue Quellstelle springen können; ein Coding-Agent soll dieselben Fakten strukturiert über MCP abfragen und die offenen Beweisverpflichtungen iterativ bearbeiten können.

### 1.3 Zielgruppen

- Entwickler, Reviewer und Security Engineers: Änderungsfolgen statt nur Text-Diffs.
- Fachverantwortliche und Produktverantwortliche: fachliche Verhaltensänderungen und freizugebende Entscheidungen.
- Unternehmen mit Audit- und Regulierungsanforderungen: reproduzierbare technische Evidenz mit ausgewiesenen Grenzen.
- AI Coding Agents: stabile Compilerdiagnostik, maschinenlesbare Proof Obligations und kurze Feedback-Loops.

### 1.4 Nichtziele

- Keine allgemeine Garantie, dass eine von Menschen gemeinte Anforderung vollständig formalisiert ist.
- Keine automatische regulatorische Zertifizierung; Audits betreffen auch Prozesse, Personen und Infrastruktur.
- Kein Anspruch, beliebiges FFI, JavaScript, Betriebssystemverhalten oder fremde Datenbanksysteme ohne Annahmen zu beweisen.
- Kein generischer Entscheidungsalgorithmus für alle semantischen Eigenschaften beliebiger Programme.
- Kein Ziel, in jedem Benchmark schneller als C oder Rust zu sein.
- Keine Pflicht für Entwickler, jede inferierbare technische Eigenschaft selbst zu annotieren.

---

## 2. Aktuelle Basis vs. Zukunft (13.10.2026)

### 2.1 Bereits vorhanden bzw. im Repository dokumentiert

Die folgende Einordnung stützt sich auf den aktuellen README- und Fortschrittsstand sowie gemergte PRs; sie ist **keine unabhängige Ausführung sämtlicher Tests**. README und `docs/progress.md` weisen teils verzögerte Statusupdates auf.

| Bereich | Beobachteter Stand |
|---|---|
| TypeScript-nahe Syntax, Records, Unions, `match`, `Option`/`Result`, Module | Implementiert |
| Generics, Klassen mit Value Semantics, Closures und Array API | Gemergt |
| HIR → MIR → Ownership-Verifier → C/LLVM | Implementiert; LLVM-Backend gemergt |
| Inferred Ownership / RC / Copy-on-Write / erste Move-Optimierungen | Implementiert, Optimierungspotenzial offen |
| Lean-Modelle zu wesentlichen Eigenschaften der Ownership-Maschine | Teilmodell, **kein Beweis des gesamten Compilers/Binaries** |
| Selbsthosting, reproduzierbarer Stage2/Stage3-Bootstrap | Vorhanden; PR #9 hat den Seed-Bootstrap gemergt |
| Formatter, LSP, MCP, Semantic Index, VS-Code-Integration | Vorhandene Basis; Packaging/UX weiter ausbaubar |
| `orin.toml`, Modulregeln und API-Snapshots | Im README als vorhanden beschrieben |
| Erstes Alpha-Release | `v0.1.0-alpha.1` dokumentiert |
| Floats, Maps, Contracts, Runtime R2 und weitere Typfeatures | Im Fortschrittsdokument teilweise in Arbeit |
| Sprachumfang 1.0 und Concurrency-Modell | In ADRs festgelegt; **nicht gleichbedeutend mit Implementierung** |

### 2.2 Noch kein fertiges System

Die folgende **integrierte** Funktionalität ist Produktvision beziehungsweise neu zu bauen:

- Effekt- und Capability-Typsystem mit tatsächlicher Runtime-Durchsetzung.
- Feld- und objektbezogene symbolische Lineage inklusive impliziter Flüsse.
- Vollständige Contract-/SMT-Verifikation über rein funktionale Spezialfälle hinaus.
- Formal definierte und prüfbare Config-/Deployment-Constraints.
- Dauerhafter Orin Software Intelligence Graph (OSIG) mit stabilen Identitäten.
- Feature-Manifest, Requirement-Traceability und semantischer PR-Diff.
- Interaktiver Review-Explorer mit nachvollziehbaren Beweis-/Call-Pfaden.
- Verifizierbare und signierte `.orcert`-Release-Artefakte.
- Realer PostgreSQL/HTTP/JSX-Referenzdienst und belastbare End-to-End-Benchmarks.

**Statusquellen:** [README](https://github.com/orin-lang/orin-lang/blob/main/README.md), [Fortschritt](https://github.com/orin-lang/orin-lang/blob/main/docs/progress.md), [PR #9](https://github.com/orin-lang/orin-lang/pull/9), [PR #10](https://github.com/orin-lang/orin-lang/pull/10).

---

## 3. Fundamentale Designprinzipien

1. **Default deny:** Externe Wirkungen brauchen explizit gewährte Capability-Werte.
2. **Capabilities sind nicht nur Metadaten:** Zugriff muss bis zur Plattformgrenze technisch erzwungen werden.
3. **Functional core, explicit effect boundaries:** Berechnung ohne Effekte ist einfach verifizierbar; I/O wird kontrolliert isoliert.
4. **Inference within, declaration at boundaries:** Effekte in privaten Funktionen inferieren; öffentliche Modul-/Feature-Schnittstellen explizit festlegen.
5. **Symbolic first:** Unbekannte Laufzeitwerte über Typen, Herkunft, Constraints und path conditions modellieren statt Analyse abzubrechen.
6. **Fail closed where policy requires:** Fehlende Nachweise blockieren nur entsprechend definierte Quality Gates, nicht den gesamten iterativen Entwicklungsworkflow.
7. **Separate intent, implementation, evidence:** Anforderungen, ihre Implementierung und der unabhängige Prüfbericht dürfen nicht ineinander aufgehen.
8. **Explainability by construction:** Jede Warnung und jedes Ergebnis bekommt einen maschinenlesbaren, source-verlinkten Erklärungspfad.
9. **Trust boundaries must be visible:** FFI, OS, Netzwerk, DB, Compiler/Backend, native Libraries und Deploymentannahmen werden ausdrücklich ausgewiesen.
10. **Do not sacrifice runtime guarantees for speed:** Optimierungen sind nur zulässig, wenn relevante Semantik und Schutzgrenzen erhalten bleiben.
11. **Source-to-artifact traceability:** Evidenz bezieht sich auf konkrete Hashes, Compiler-Versionen, Policies, Config-Schemas und Builds.
12. **Honest proof claims:** `VERIFIED`, `REFUTED`, `UNKNOWN`, `ASSUMED`, `NOT_APPLICABLE` nie vermischen.

---

## 4. Ein gemeinsamer semantischer Kern: OSIG

Der **Orin Software Intelligence Graph (OSIG)** ist das zentrale Produktdatenmodell. Parser, Typechecker, MIR, Effect-/Capability-Analysen, Contract-Verifikation, Feature-Zuordnung, IDE, MCP und GitHub-Review teilen dieselbe normalisierte Identitäts- und Herkunftsebene.

### 4.1 Graph-Knoten

- `Package`, `Module`, `Symbol`, `Function`, `Method`, `Class`, `Type`, `Field`, `Variant`
- `Feature`, `Requirement`, `Contract`, `Invariant`, `Transition`
- `CapabilityKind`, `CapabilityGrant`, `Effect`, `TrustBoundary`
- `DataSource`, `DataSink`, `DataTransformation`, `Classification`, `ConfigField`
- `CallSite`, `CallEdge`, `ControlDependency`, `DataDependency`
- `ProofObligation`, `ProofResult`, `Assumption`, `SourceLocation`
- `Build`, `CompilerVersion`, `Dependency`, `Artifact`, `DeploymentProfile`

### 4.2 Typisierte Kanten

`DEFINES`, `IMPORTS`, `CALLS`, `READS`, `WRITES`, `DERIVES_FROM`, `GUARDED_BY`, `MAY_FLOW_TO`, `REQUIRES_CAPABILITY`, `GRANTED_BY`, `IMPLEMENTS_REQUIREMENT`, `ESTABLISHES`, `INVALIDATES`, `DEPENDS_ON_ASSUMPTION`, `GENERATED_FROM`, `DEPLOYED_WITH`.

### 4.3 Identität und Versionierung

- **Stable Symbol ID:** Paket + Modul + symbolische Signatur + explizite ID, wo sinnvoll; Hash allein genügt nicht bei Rename.
- **Callsite-/IR-IDs:** für interne Analysen revisionslokal, verknüpft mit Source-Maps.
- **Feature IDs:** menschlich verwaltete stabile Kennungen; technische Reichweite wird errechnet.
- **Graph Schema Version:** unabhängig von Compiler-Release.
- **Graph Snapshot:** deterministisch serialisiert und gehasht; Base-/Head-Vergleiche reproduzierbar.
- **Rename-Heuristik:** plausible Zuordnung, aber nicht stillschweigend als bewiesene Identität ausgeben.

### 4.4 Präzision

Graphkanten benötigen mindestens `source`, `target`, `kind`, `confidence` bzw. Evidenzklasse, `source_span`, `analysis_version`, `assumptions` und optional `path_condition`. Nicht jede Kante hat dieselbe Aussagekraft:

- `MUST`: in jeder relevanten Ausführung unter den Annahmen.
- `MAY`: konservativ möglicher Pfad.
- `UNKNOWN`: fehlende Analyseinformation oder fremde Grenzen.

**Wichtig:** Eine überapproximierende `MAY_FLOW_TO`-Analyse ist für Sicherheitsprüfung meist richtig; sie kann False Positives liefern. Ein „nicht beobachteter“ Datenfluss ist **kein** Beweis seiner Unmöglichkeit.

---

## 5. Capability System: Typen, Inferenz und Durchsetzung

### 5.1 Zielmodell

Eine Capability ist ein **nicht fälschbarer Berechtigungswert** mit einem statisch bekannten Typ und gegebenenfalls Ressourcen-Constraints. Beliebiger Anwendungscode darf ihn nicht konstruieren. Er wird von einer vertrauenswürdigen Anwendungskomposition oder Plattforminstanz gewährt. Eine Capability darf durch restriktive Delegation abgeschwächt, aber nicht ohne Autorisierung erweitert werden.

```ts
// Pseudocode: Designziel, NICHT gültige aktuelle Orin-Syntax.
capability DatabaseRead<table: string>;
capability DatabaseWrite<table: string>;
capability NetworkConnect<host: string>;
capability EmailSend;

function listOrders(db: DatabaseRead<"orders">): Result<Order[], DbError> {
  return db.queryOrders();
}
```

### 5.2 Zwei verbundene Konzepte

**Effekt:** Was eine Funktion möglicherweise tut (`DB_READ`, `NET_CONNECT`, `FILE_WRITE`, `CLOCK`, `RANDOM`, `SPAWN`, `FFI`).  
**Capability:** Mit welcher konkreten Autorisierung sie es tun darf (`DatabaseRead<"orders">`, `NetworkConnect<"api.vendor.com">`).

Eine Funktion kann einen Effekt benötigen, ohne ihn lokal auszuführen: Er entsteht transitiv über den Call Graph.

`EffectiveEffects(f) = LocalEffects(f) ∪ ⋃ EffectiveEffects(callee)` als konservativer Fixpunkt unter dynamischem Dispatch, Closures, Rekursion und FFI. Für Ressourcen-Constraints müssen die Bedingungen entlang des Aufrufpfads berücksichtigt werden. Tatsächliche Grants sind davon getrennt.

### 5.3 Pro-Funktion / Pro-Objekt / Pro-Modul / Pro-Feature

- **Funktion:** präzise Anforderungen der Operation.
- **Objekt:** Welche Fähigkeiten sind in einem konkreten Wert enthalten oder durch seine Methoden erreichbar? Ein Typname allein bedeutet **keinen** gewährten Zugriff.
- **Modul:** maximal mögliche Effekte und von exportierten Entry Points erreichbare Effekte als getrennte Sichten.
- **Feature:** über seine Entry Points und Abhängigkeiten errechnete transitive effektive Requirements.
- **App:** notwendige Grants aus den konfigurierten Entry Points; nicht pauschal die Vereinigung aller importierten Bibliotheken.

### 5.4 Capability-Verträge und Policies

```toml
# Konzeptionelle orin.toml-Erweiterung
[modules.payments.capabilities]
allow = ["DatabaseRead<orders>", "DatabaseWrite<orders>"]
deny = ["FileWrite<*>"]

[features.payments.refunds]
review_required_on_capability_expansion = true
```

Explizite Manifestregeln dienen als zulässige **Obergrenze**, nicht als automatisch erhaltene Runtime-Rechte. Bei einer Überschreitung wird der Build in einem entsprechenden Policy-Modus blockiert.

### 5.5 Security-Härtung

- Handle-basierte Autorisierung an jeder OS-/Netz-/DB-Operation, inklusive FFI.
- URL/Host-Constraints müssen Redirects, DNS-Änderungen, IP-Rebinding und Proxy-Verhalten berücksichtigen.
- Pfad-Constraints müssen Symlinks, Mounts und Normalisierung berücksichtigen.
- DB-Scopes müssen auch Views, Trigger, Stored Procedures und Rollen abbilden oder Grenzen markieren.
- Dynamischer Dispatch verwendet eine konservative Menge möglicher Zielimplementierungen.
- Speziell: **Capability-Besitz beweist nicht zulässige Datenweitergabe**. Es braucht zusätzlich Information-Flow-Policies.

---

## 6. Data Lineage und Informationsfluss

### 6.1 Drei getrennte Analysen

1. **Value / Field Lineage:** Welche Ausgaben hängen von welchen Eingaben und Transformationen ab?
2. **Control Dependence:** Welche Entscheidungen werden durch sensitive Daten beeinflusst?
3. **Security Information Flow:** Können Informationen einer Klassifikation an bestimmte Senken gelangen – auch implizit?

```ts
// Pseudocode
@Sensitive("financial")
type CreditScore = int;

function label(score: CreditScore): string {
  if (score > 600) { return "A"; }
  return "B";
}
```

Das Ergebnis hängt vom sensitiven `score` ab, obwohl die Strings literale Werte sind. Ein bloßer Operand-Graph ist dafür unzureichend. Der Compiler muss den Kontrollabhängigkeitsgraphen einbeziehen.

### 6.2 Symbolische Laufzeitwerte

Der Compiler kann `eligible = creditScore >= 600` korrekt als symbolischen Ausdruck beschreiben, ohne einen konkreten Score zu kennen. Constraint-Solver bewerten Pfadbedingungen, Contracts und Konfigurationseinschränkungen. Bei unbekanntem Query-Text oder FFI wird die Analyse konservativ bzw. als offen markiert.

### 6.3 Sicherheitsklassifikationen und Declassification

- Klassifikationen wie `Public`, `Internal`, `Personal`, `PaymentSecret` plus projektspezifische Labels.
- Propagation durch Zuweisungen, Rechenoperationen, Closure-Captures, Serialisierung, Hashing und Branches.
- Explizite, reviewpflichtige `declassify`-Operationen für legitimierte Offenlegung.
- Sink Policies wie `Personal -> ApprovedCRM` oder `PaymentSecret -> PaymentProviderOnly`.
- Taint-Analyse **ist nicht gleich** ein allgemeiner kryptografischer Nichtinterferenzbeweis; Side Channels, Timing, Ausnahmepfade und Ressourcenverbrauch brauchen eigene Modelle.

### 6.4 Datenbanken und externe Services

- Typisierte SQL-ASTs bzw. parametrisierte Queries bevorzugen: Tabellen-/Spalten- und Feld-Lineage lassen sich genauer extrahieren.
- Raw SQL, dynamische Tabellen, DB-Trigger und Stored Procedures als explizite Boundary markieren oder zusätzliche DB-Metadaten einlesen.
- Externes API-Verhalten nur gemäß geprüften Interface-Verträgen annehmen.
- Laufzeit-Telemetrie kann die Analyse **ergänzen**, aber weder einen vollständigen statischen Beweis noch die Erfassung aller möglichen Ausführungen ersetzen.

---

## 7. Zustandsmaschinen, Invarianten und fachliche Contracts

### 7.1 Was formal beschrieben wird

- **Preconditions:** Vorbedingungen (`@Requires`).
- **Postconditions:** Nachbedingungen (`@Ensures`) mit `old()`-Werten.
- **Class-/Record-Invarianten:** Eigenschaften gültiger Zustände (`@Invariant`).
- **Transition Contracts:** erlaubte Zustandsübergänge einer Tagged Union/State Machine.
- **Frame Conditions:** Was **nicht** verändert werden darf; besonders wichtig bei Value Semantics und I/O.
- **Temporal Properties:** für asynchrone Protokolle, z. B. „jede angenommene Bestellung wird entweder abgeschlossen oder storniert“ – erheblich aufwendiger als lokale Contracts.

```ts
// Konzeptionelles Ziel
@Invariant(this.balance >= 0)
class Account {
  constructor(public balance: int) {}

  @Requires(amount > 0 && amount <= this.balance)
  @Ensures(this.balance == old(this.balance) - amount)
  withdraw(amount: int): void {
    this.balance -= amount;
  }
}
```

### 7.2 Beweisworkflow

Typechecker → HIR/MIR-Semantik → Verification Conditions → Solver → unabhängig prüfbare bzw. nachvollziehbare Ergebnisse. Für einfache pure Funktionen sollen automatische Beweise möglich sein; Loops benötigen ggf. Invarianten und Terminierungsmaße. Externe Operationen verwenden bewusste Annahmen statt stillschweigender Beweise.

### 7.3 Spezifikations-Governance

Die kritische Schwachstelle ist nicht nur falscher Code, sondern **richtig bewiesener Code mit falscher Spezifikation**.

- Requirements besitzen stabile IDs, Owner und Status.
- Fachlich relevante Contracts werden unabhängig von der Implementierung genehmigt.
- Ein implementierender Agent darf genehmigte Contracts/Policies nicht stillschweigend abschwächen.
- Änderungen an Anforderungen, `@Assume`, Declassification, Capability-Policies und Scope werden separat reviewpflichtig.
- Zu jedem Beweis wird festgehalten: Welche Requirement-ID und welche Annahmen deckt er ab?

### 7.4 Requirement Completeness

Ein Compiler kann **nicht aus beliebigem Source Code ableiten, welche unausgesprochenen Geschäftsregeln ein Unternehmen meint**. Stattdessen:

- Fachspezifische Requirement Schemas definieren Pflichtfragen für bestimmte Kategorien (Payment, Identity, Personal Data etc.).
- Nicht beantwortete Pflichtfelder erzeugen `NEEDS_DECISION`-Obligations.
- Der Agent fragt gezielt nach; der fachliche Owner genehmigt die Antwort.
- Vollständigkeit wird **relativ zum gewählten Schema** bescheinigt, niemals absolut.

---

## 8. Konfigurationen, Secrets und Deployment

### 8.1 Config als typisierter Vertrag

```ts
// Konzeptionell, noch keine implementierte Syntax
config PaymentConfig {
  @Secret apiKey: Secret<string>;
  @Range(1, 30) timeoutSeconds: int = 10;
  @AllowedHosts(["api.stripe.com"]) endpoint: Url;
  @RequiredOn("production") auditEnabled: bool;
}
```

Konkrete Werte fehlen zur Compilezeit, **Constraints nicht**. Der Compiler beweist Eigenschaften entweder für *alle* zulässigen Werte oder deklariert Bedingungen, die beim Deployment zwingend erfüllt werden müssen.

### 8.2 Drei Zeitpunkte

1. **Compile:** Universelle Aussagen unter einem Config Schema (`∀ config ∈ AllowedConfigs`).
2. **Startup:** Tatsächliche Werte validieren, Secret-Referenzen auflösen, effektive Grants attestieren.
3. **Deployment:** Prüfen, ob Binary-Hash, Config-Schema, Policy-Version, effektive Cloud-/Container-Rechte und Laufzeitumgebung zur Evidenz passen.

### 8.3 Dynamik nach Start

Hot Reload, rotierende Secrets, Service Discovery, Feature Flags und DNS dürfen nicht heimlich einen zuvor geprüften Scope ausweiten. Optionen: bei Änderungen erneut validieren; unveränderliche Config-Snapshots; zeitgebundene Runtime-Attestierung. Secrets werden weder in OSIG-Exports noch Zertifikaten im Klartext abgelegt.

### 8.4 Was ein Config-Beweis aussagen darf

`VERIFIED: for all configurations satisfying schema S, operation O calls only approved hosts.`  
**Nicht**: `VERIFIED: the live production service definitely uses schema S` – ohne Deployment-/Runtime-Nachweis.

---

## 9. Formale Beweise, Coverage und Trust Boundaries

### 9.1 Proof-Status (verpflichtendes Modell)

| Status | Bedeutung | Merge-/Release-Wirkung |
|---|---|---|
| `VERIFIED` | Verpflichtung innerhalb expliziter Annahmen formal bewiesen | Grün nur für exakt diese Aussage |
| `REFUTED` | Gegenbeispiel oder echte Widerlegung gefunden | Blockiert betroffene verpflichtende Policy |
| `UNKNOWN` | Solver unentschieden, Timeout, fehlende Modellierung | Im Strict Mode blockiert |
| `ASSUMED` | Externe oder bewusst nicht bewiesene Annahme | Sichtbar; Policy kann Freigabe verlangen |
| `NEEDS_DECISION` | Fachliche Spezifikation oder Genehmigung fehlt | Agent erhält konkrete Frage |
| `NOT_APPLICABLE` | Anforderung für diesen Kontext nicht relevant | Mit Begründung |

*`VERIFIED` kann einen explizit genannten Satz von Annahmen enthalten. Die Behauptung muss die Annahmen immer nennen; sonst droht Scheinsicherheit.*

### 9.2 Grenzen

- Allgemeine Terminierung beliebiger Programme ist nicht entscheidbar.
- Nichtinterferenz unter Side Channels ist komplex; der Standard-Data-Lineage-Graph genügt nicht.
- Externe Anbieter, Datenbanken, Trigger, OS, Netz und FFI benötigen Verträge, Tests oder separate Evidenz.
- Race-Freiheit dank Task-Isolation bedeutet **nicht** fachliche Atomarität in verteilten Workflows.
- MIR-Beweise beweisen nicht automatisch die Korrektheit der C-/LLVM-Transformation oder der fertigen Binärdatei.

### 9.3 Trusted Computing Base (TCB)

TCB explizit inventarisieren: Lexer/Parser-Semantik, Typechecker, MIR-Transformationen, Proof-Checker/Solverannahmen, Backend/Linker, Runtime, Kernel, FFI, DB-/HTTP-Adapter. Ziel: kleine vertrauenswürdige Komponenten, differenzielle Backends, Translation Validation für riskante Passes, reproduzierbare Builds und getrennte Prüftools. Lean-Teilbeweise als Basis erweitern, nicht als Vollbeweis vermarkten.

### 9.4 Proof Coverage statt Prozent-Folklore

Nicht „95 % verifiziert“ ohne definierte Metrik. Stattdessen: Anteil verpflichtender Obligations erfüllt, Anzahl offene Boundaries, erreichte Entrypoints, Anteil analysierter Sinks, Regressionsrate pro Requirement, Risikoklassen und Source-/Build-Coverage. Unbekannte und angenommene Grenzen explizit zählen.

---

## 10. AI-Agent-Workflow: Compiler als Rückfrage- und Nachweis-Motor

### 10.1 Zustandsautomat

```text
REQUESTED
    ↓ Anforderungen konkretisieren
SPEC_DRAFT
    ↓ Fachliche Genehmigung
SPEC_APPROVED
    ↓ Agent implementiert
IMPLEMENTED
    ↓ Check / Lineage / Effects / Proofs
VERIFICATION_PENDING
    ├── TECHNICAL_DEFECT ──> Agent korrigiert
    ├── NEEDS_DECISION ────> Mensch beantwortet, Spec erneut genehmigen
    ├── ASSUMPTION_CHANGE ─> Security/Owner Approval
    └── VERIFIED ──────────> FEATURE_REVIEW
                                   ↓
                             RELEASE_ELIGIBLE
```

Der Compiler darf keine beliebigen Rückfragen „erraten“, als wären diese formal zwingend. Fragen stammen aus definierten Requirement Schemas, nicht bewiesenen Invarianten, unzureichenden Constraints oder expliziten Unklarheiten.

### 10.2 Strikte Aufgabentrennung

- **Spec Agent:** erstellt fachlichen Vorschlag, markiert offene Entscheidungen.
- **Human Owner:** bestätigt geschäftliche Bedeutung und Ausnahmefälle.
- **Implementation Agent:** schreibt Orin-Code, darf Spec-Approval nicht umgehen.
- **Verifier:** liefert deterministische Diagnosen, Proof Obligations und Gegenbeispiele.
- **Reviewer:** akzeptiert Verhaltens- und Capability-Änderungen.

Separate Agenten können Hilfestellung leisten, ersetzen aber keine unabhängige fachliche Freigabe.

### 10.3 Tooling-Schnittstellen

Vorgesehene Befehle (Zielschnittstellen, noch nicht sämtlich implementiert):

```bash
orin check package/ --format=json
orin inspect --symbol payments.RefundService.refund --format=json
orin effects package/ --entry payments.refund --format=json
orin lineage package/ --from Customer.email --format=json
orin verify package/ --profile production --mode strict
orin graph package/ --format=osig-json -o build/osig.json
orin diff --base origin/main --head HEAD --format=json
orin cert verify build/payment-service.orcert
```

MCP-Tools sollen dieselben Engines verwenden: `get_symbol`, `get_feature`, `explain_capability`, `trace_lineage`, `list_obligations`, `check_change`, `explain_counterexample`, `compare_revisions`.

### 10.4 Strukturierte Diagnose

```json
{
  "id": "ORIN-CAP-014",
  "kind": "CAPABILITY_EXPANSION",
  "severity": "review_required",
  "feature_id": "payments.refunds",
  "entrypoint": "RefundController.refund",
  "capability": "NetworkConnect<payments.example>",
  "path": [
    "RefundController.refund",
    "RefundService.refund",
    "ProviderClient.requestRefund",
    "HttpClient.post"
  ],
  "introduced_at": {"file": "src/payments/provider.or", "line": 42},
  "evidence": "MAY_REACH",
  "policy": "payments.external_access.v3",
  "required_action": "APPROVE_CAPABILITY_EXPANSION"
}
```

Diagnosen erhalten stabile IDs, Feature-Bezug, maschinenlesbare Ursache, Quellstelle, Erklärungspfad, Fix-Kategorie und ob eine menschliche Entscheidung nötig ist.

---

## 11. Feature-first GitHub PR Review

### 11.1 Der Review-Einstieg

Nicht „+8.423/−1.820 Zeilen“, sondern beispielsweise:

> **PR #142 · Partial Refunds**  
> 3 Features betroffen · 1 neue Capability · 2 offene Beweise · 1 Änderung an genehmigter fachlicher Semantik

**Reviewer sieht zuerst:**

1. Feature Summary in Geschäftssprache, mit Quellverweisen.
2. Vorher-/Nachher-Verhalten, Contract-Diff, mögliche Auswirkungen.
3. Capability-Diff inklusive begründendem Call Path.
4. Objekt-/Feld-Lineage und neue Sources/Sinks.
5. State-Transition-Diff.
6. Proof Delta: weiter gültig, neu bewiesen, invalidiert, widerlegt, offen, angenommen.
7. Config-/Dependency-/Trust-Boundary-Diff.
8. Code-Diff als Drill-down und vollständige Evidenzliste.

### 11.2 Fachliche Feature-Identität

Ein Compiler kennt Funktionen, aber nicht automatisch Geschäftsbegriffe. Ein minimales `features/*.toml` liefert stabile Identität und Entry Points; der Graph errechnet die transitive technische Reichweite.

```toml
# Beispiel, Designziel
[feature]
id = "payments.refunds"
name = "Payment Refunds"
owner = "payments-team"

[entrypoints]
symbols = ["RefundController.refund", "RefundService.refund"]

[requirements]
ids = ["PAY-REF-001", "PAY-REF-002"]

[verification]
mode = "strict"
```

Cross-Feature-Abhängigkeiten sind erlaubt und sichtbar. Die Zuordnung kann per Annotation ergänzt werden; sie darf nicht ausschließlich auf Namensähnlichkeit oder LLM-Zusammenfassungen beruhen.

### 11.3 Semantischer Diff-Algorithmus

1. Base und Head reproduzierbar kompilieren/analysieren.
2. Beide OSIG-Snapshots erzeugen und versionieren.
3. Symbole/Feature-IDs zuordnen, Renames gesondert markieren.
4. Auswirkungen durch reverse Call Graph, Feldabhängigkeiten, Effekte, Transitions und Requirements berechnen.
5. Policy-/Grant-Deltas und Source/Sink-Deltas bestimmen.
6. Nur invalidierte Obligations nachprüfen; unveränderte Beweise nur bei gültigem Dependency-/Assumption-Hash wiederverwenden.
7. `MAY`, `MUST`, `UNKNOWN`, `ASSUMED` explizit ausweisen.
8. JSON + HTML-Report + GitHub Check Run/Annotations + Deep Links erzeugen.

### 11.4 Interaktive Views

- **Feature Map:** betroffen/indirekt betroffen/unverändert; Fokusmodus.
- **Capability Graph:** Quelle des Grants, funktionsgenauer Zugriff, neue Rechte farblich markiert.
- **Data Lineage:** Feldknoten, Transformationen, Guards, externe Sinks, mögliche versus bewiesene Pfade.
- **State Machine:** gültige Zustände, neue/entfernte Übergänge, Preconditions.
- **Proof Explorer:** konkrete Obligations, Solver-Ergebnis, Gegenbeispiel, Annahmen.
- **Timeline:** Evolutionshistorie eines Features über Releases und Deployments.

Jeder UI-Knoten verlinkt auf `commit + path + source range` und auf die entsprechende maschinenlesbare Evidenz.

### 11.5 GitHub-Integration in Stufen

1. `orin diff --format=json` als CLI, deterministische Golden Tests.
2. Statischer HTML-Report als GitHub Actions Artifact, plus PR-Check-Summary.
3. GitHub Check Runs mit Findings, Links und Merge-Gates.
4. Interaktiver gehosteter oder self-hostbarer Explorer mit Zugriffskontrolle.
5. Optional vollständige GitHub-App für approvals und organisationsweite Policies.

Nicht mit einer proprietären SaaS anfangen; Kernanalyse und statischer Viewer sollten lokal und reproduzierbar funktionieren.

---

## 12. `.orcert` — Nachweise an echte Builds binden

Beispielstruktur:

```text
payment-service.orcert/
  manifest.json
  source-hashes.json
  compiler-and-toolchain.json
  requirements.json
  osig.json
  capabilities.json
  data-lineage.json
  contract-results.json
  configuration-schema.json
  trust-boundaries.json
  assumptions.json
  proofs/
  sbom.json
  provenance.json
  signatures/
```

### Anforderungen an das Zertifikat

- Bezieht sich auf **Source Commit, vollständig aufgelöste Dependencies, Compiler/Backend, Runtime, Policy-Set und Binary Hash**.
- Beweisberichte werden nicht nur behauptet: unabhängiger Checker prüft akzeptierte Proof-Formate, Hash-Bindung und Signaturen.
- Signaturen/Supply-Chain-Provenance machen Fälschung schwieriger; sie **beweisen nicht**, dass externe Systeme korrekt sind.
- Strict-Release-Policy bestimmt genau, welche `ASSUMED`/`UNKNOWN` akzeptabel sind.
- Bei Änderungen von Contract/Capability/Config-Scope sind bisherige Zertifikate entsprechend ungültig oder nur begrenzt wiederverwendbar.
- Secrets werden niemals eingebettet; nur Schema, Referenzen und gegebenenfalls Attestierungsnachweise.

Langfristig Standards für Provenance/SBOM (z. B. SLSA/in-toto/Sigstore, CycloneDX oder SPDX) interoperabel verwenden, nicht eigene Kryptografie konstruieren.

---

## 13. Performance und Native Runtime

**Ziel:** Sicherheits- und Nachweismechanismen sollen zu möglichst hohem Anteil Compile-Time-Arbeit sein; das Release bleibt ein natives Programm mit so wenig notwendigen Runtime-Checks wie möglich.

- LLVM/C-Backend und optimierende MIR-Pässe wiederverwenden.
- Statisch bewiesene Verträge dürfen unter ihren Annahmen ohne redundante Runtime-Checks umgesetzt werden; unbewiesene oder externe Grenzen benötigen ggf. Checks.
- Escape Analysis, Stack Allocation, RC-Elision, Unboxing, COW-Elision, Specialization und effiziente Collections gezielt benchmarken.
- Capability-Checks, die vom Compiler nicht vollständig aufgelöst werden können, müssen an der Boundary tatsächlich stattfinden.
- Semantik von Optimierungspässen mit Differentialtests und möglichst Translation Validation absichern.
- Benchmark-Klassen: JSON/API, PostgreSQL-CRUD, HTML-Rendering, große Collections, Concurrency, speicherintensive Workloads; p50/p95/p99, Throughput, RSS, CPU und Allokationen messen.

**Performance ist empirisch.** Keine Behauptung „schneller als Rust/Go“ ohne vergleichbare Anwendungen und reproduzierbare Testbedingungen.

---

## 14. Referenzanwendung: Payment / Orders Microservice

Eine reale End-to-End-Demo sollte die Architektur belegen, nicht nur syntaktische Einzeltests.

**Technische Komponenten:** natives Orin-Executable, HTTP-Server/REST-API, PostgreSQL über zunächst kleinen geprüften Adapter, JSON, typisierte Config, serverseitiges JSX-Templating, optional HTMX, Docker Compose, Integrationstests.

**Use Cases:**

- Auftrag anlegen und lesen.
- Zahlung autorisieren.
- Voll-/Teilerstattung mit Übererstattungs-Schutz.
- Versand-/Statusübergänge.
- Dashboard mit JSX-Templates.
- Konfigurierbarer Payment-Provider unter Host-Capability.

**Zu demonstrierende Evidenz:**

- `Order`/`Payment` State-Machine aus Code und Contracts.
- Feld-Lineage: personenbezogene Daten, Zahlungsmengen, Persistenz.
- Capability-Diff, wenn ein externer Provider hinzugefügt wird.
- Automatisch nachgewiesene Invariante „Summe der Refunds <= Zahlungsbetrag“ im definierten Transaktionsmodell.
- Sichtbare `ASSUMED`-Boundary bei externem Provider und DB-Commit.
- Ein PR, der absichtlich eine neue Datenweitergabe oder schwache Invariante einführt, muss im Review sichtbar auffallen.
- Eine Runtime-Config, die falschen Host zulässt, darf nicht unbemerkt als verifiziert starten.

### JSX-Aufteilung

JSX erfordert einen Parser oder Transformer; das Rendering selbst ist eine Library. Erst optionaler Transformer-Prototyp, danach natives Parsing. HTML-Escaping muss kontextabhängig sicher sein; `SafeHtml` nur kontrolliert konstruierbar. Kein VDOM erforderlich für SSR.

---

## 15. Roadmap mit Abhängigkeiten und Gates

**Die Reihenfolge zählt mehr als Kalenderfristen.** Ziel ist eine belegbare vertikale Funktionalität, bevor viele parallel halb implementierte Subsysteme entstehen.

### Phase 0 — Architekturklarheit und Trust Model

**Liefern:** verbindliche ADRs zu OSIG, Capability/Effekt-Semantik, Requirement-Governance, Proof-Status und Configuration Attestation. Ein minimales, versioniertes Graph-Schema. Explizites TCB-Inventar.

**Gate:** An einem handgeschriebenen Beispieldienst können wir eindeutig sagen, welche Behauptungen `VERIFIED`/`ASSUMED` sein dürfen.

### Phase 1 — OSIG MVP und Feature-Diff ohne Beweise

**Liefern:** Compiler-Snapshot mit Symbolen, Modulen, Typen, Calls und Source-Ranges; stabile Feature-IDs; `orin graph`; `orin diff --base --head`; statischer HTML-Report.

**Gate:** Eine PR mit Rename, API-Signaturänderung und neuem Call Path zeigt korrekt die betroffenen Features und den erklärbaren Pfad. Golden Tests prüfen Determinismus.

### Phase 2 — Effekt- und Capability-System

**Liefern:** Effektinferenz, transitiver Fixpunkt, explizite Grenzen, typed capability handles, Policy-Checker und kleine Runtime-Boundary für File/Network/DB. `orin effects` und Capability-Diff.

**Gate:** Ein zusätzlicher Netzwerkzugriff erscheint eindeutig in Funktions-/Feature-/App-Analyse; ohne Grant schlägt der geschützte Aufruf zur Laufzeit fehl. FFI-Ausnahmen werden sichtbar und begrenzt.

### Phase 3 — Symbolische Feld-Lineage und Information Flow

**Liefern:** Datenfluss auf MIR/SSA-Ebene mit field sensitivity, propagierten Labels und Kontrollabhängigkeiten; Sources/Sinks; Interprocedural Summaries; `orin lineage`.

**Gate:** Tests entdecken einen expliziten Datenexport **und** ein implizites Leak über einen Branch. Dynamische/unklare Pfade liefern konservatives `MAY`/`UNKNOWN`, kein falsches Grün.

### Phase 4 — Contracts und Proof Obligations

**Liefern:** `@Requires`, `@Ensures`, `@Invariant`, `old()`, Frame Conditions, VC-Generator, Solver-Integration, Counterexample/UNKNOWN-Handling, Strict Policy, Requirement-IDs.

**Gate:** Ein falscher Payment-Balance-Pass wird widerlegt; eine bewiesene Invariante wird mit Abhängigkeiten ausgewiesen; Contract-Abschwächung ist reviewpflichtig. Keine Annahme wird automatisch als Beweis etikettiert.

### Phase 5 — Symbolische Configuration und Runtime Attestation

**Liefern:** typisierte Config Schemas, Constraints, Profile, Secret-Boundaries, validierte Runtime-Config und Build-gebundene Attestierung.

**Gate:** Für jede zulässige Config gilt eine Host-Policy; eine unzulässige Production-Config startet nicht. Dynamische Änderungen führen zu Neuvalidierung.

### Phase 6 — Feature Review und Agent Loop

**Liefern:** PR-Report mit Verhalten, State Machine, Graph-Diff, Capability-Diff, Proof Delta; MCP `explain_*`; strukturiertes `NEEDS_DECISION`; rollengetrennte Freigaben.

**Gate:** In einer realen Demo-PR kann ein Reviewer die fachlichen Auswirkungen und Nachweisgrenzen innerhalb weniger Minuten erkennen; ein Agent kann aus Diagnosen eine konkrete technische Aktion oder Rückfrage ableiten.

### Phase 7 — Proof-Carrying Releases

**Liefern:** `.orcert`, reproducible provenance, unabhängiger Checker, Policy-Gates, signierte Artefakte, optional GitHub-App.

**Gate:** Ein verändertes Binary, Contract, Policy-Set oder Dependency-Baum invalidiert die entsprechende Zertifikatsprüfung; ein legitimes Release lässt sich offline gegen die spezifizierte Evidenz prüfen.

### Phase 8 — Compiler-Härtung, Runtime, Performance und Ecosystem

**Liefern:** erweiterte Lean-/Translation-Validation-Arbeit, optimierende MIR-Pässe, Runtime-R2/R3, Standardbibliotheken, HTTP/DB/JSX, Homebrew und VS-Code-Paketierung, Benchmark-Suite.

**Gate:** End-to-End-Referenzdienst funktioniert in CI über beide Backends; Performance- und Verifikationsregressionen werden gemessen statt behauptet.

### Parallelisierung ohne Integrationschaos

- **Track A Compiler/Graph:** OSIG, Symbolidentität, MIR Source Mapping.
- **Track B Security:** Effekte, Capabilities, Flow Labels, Runtime Enforcement.
- **Track C Formal:** Contracts, VC, Proof-Checker, Assumptions.
- **Track D Product/Tooling:** MCP, CLI, GitHub Report, Visual Explorer.
- **Track E Ecosystem:** Config, HTTP/DB/JSX, Packaging, Benchmark.

Tracks teilen versionierte IR-/OSIG-/Diagnostic-Contracts. Änderungen an diesen Schemata brauchen Cross-Track-Tests.

---

## 16. Konkretes Backlog: die ersten zehn Tickets

1. **ADR: OSIG Schema v0.1.** IDs, Kanten, Evidenzklasse, Versionierung, Serialization.
2. **Compiler Source Mapping.** Jede MIR-Operation auf relevante Source-Spans abbilden.
3. **`orin graph`.** Deterministischer Export für Demo-Projekte mit Call-/Module-/Type-Graph.
4. **Feature Manifest.** `feature_id`, Owner, Entry Points, Requirement-IDs und Schema-Validation.
5. **`orin diff`.** Base/Head-Snapshot, Rename-Handling und Reverse-Impact-Analyse.
6. **GitHub Actions MVP.** Statischer HTML-PR-Report aus `orin diff` ohne gehosteten Backend-Service.
7. **Effect Lattice.** Purity, Read/Write/Network/FFI-Effects, interprozeduraler Fixpunkt.
8. **Capability Types & Grants.** Nicht-fälschbarer Werteentwurf, Einschränkung, Boundary Enforcement.
9. **Data Flow Prototype.** Field Lineage plus Branch-abhängiger impliziter Fluss.
10. **Verification Protocol.** Obligations, statuses, assumptions und Counterexample-JSON; anfangs auch ohne vollständigen Solver.

**Empfohlener erster PR:** Nur Tickets 1–3 + kleine Tests; sauberer Graph-Export ist die Basis für alles Weitere.

---

## 17. Akzeptanztests für die Vision

1. **Unsichtbare Capability:** Agent fügt `http.post` in eine Utility-Funktion ein. Erwartet: PR zeigt neuen effektiven Netzwerkzugriff über vollständigen Call Path; Policy-Gate greift.
2. **Nicht offensichtlicher Leak:** `if (customer.isVIP) log("A") else log("B")`. Erwartet: implizite sensitive Abhängigkeit erkannt.
3. **Refactoring ohne fachliche Änderung:** Function Rename und Code Move. Erwartet: möglichst kein falscher Behavioral-Change-Alarm; nicht eindeutig zuordenbare Symbole als Unsicherheit markieren.
4. **Contract-Schwächung:** Agent entfernt eine Balance-Invariante. Erwartet: Requirement-/Proof-Diff fordert explizite Freigabe.
5. **Falsche Rückerstattung:** Implementierung erlaubt Refund > Zahlung. Erwartet: `REFUTED` mit reproduzierbarem Gegenbeispiel unter festgelegtem Modell.
6. **Undefinierter Fachfall:** Refund-Schema enthält keine Idempotenzentscheidung. Erwartet: `NEEDS_DECISION`, nicht vom Agenten stillschweigend als „erledigt“ markierbar.
7. **Unbekannte Runtime-Config:** Host ist unbekannt, aber constrained. Erwartet: bedingter Compile-Beweis + Startup-Validierung; falscher Host wird abgewiesen.
8. **Externe DB:** Eine DB-Trigger-Semantik fehlt. Erwartet: explizite `ASSUMED`/`UNKNOWN`-Boundary, niemals vollständiger Datenflussbeweis.
9. **Dependency Update:** Native Library hinzugefügt. Erwartet: FFI-Trust-Boundary und Proof-Invalidierung erscheinen.
10. **Reproducible Evidence:** Binärdatei nach Release manipuliert. Erwartet: unabhängiger Zertifikatscheck schlägt fehl.

---

## 18. Messbare Produktmetriken

**Verifikationsqualität:** False-Negative-Rate in kuratierten Sicherheits-/Regressionsszenarien, False-Positive-Rate bei Refactorings, Anteil erklärbarer Findings, `UNKNOWN`-Quote, Abdeckungsgrad kritischer Sources/Sinks, Nachweis-Gültigkeitsquote nach Change.

**AI-Entwicklungsqualität:** Anteil fachlich akzeptierter Features beim ersten Review, escaped defects, Zahl nötiger Rückfragen, Zeit bis zu fachlicher Freigabe, Review-Aufwand pro Feature, Kosten pro akzeptiertem Feature.

**Compiler-/Runtime-Qualität:** Conformance gegen C/LLVM, Differentialtests, Bootstrap-Reproduzierbarkeit, MIR-Ownership-Korrektheit, Crash/Memory/Sanitizer-Regressionen, Build-Zeit, Incremental Recheck-Zeit.

**Performance:** realistische Throughput-/Latency-/Memory-Benchmarks gegen geeignete Referenzimplementierungen; Sicherheitseigenschaften konstant halten.

**Enterprise-Evidenz:** Anteil Releases mit vollständig gebundener Provenance, Anteil nachvollziehbarer Annahmen, Zahl ungeprüfter Grants, durchschnittliche Zeit zur Beantwortung einer Audit-Frage.

Keine der Metriken durch unkontrolliertes Erweitern der Annahmen oder Abschwächen der Contracts „optimieren“.

---

## 19. Risiken und offene Designentscheidungen

| Thema | Entscheidungsvorschlag | Hauptrisiko |
|---|---|---|
| Capability als Klasse oder Sprachprimitive? | Erste-Klasse-Typ/Handle, Syntax später; unforgeable | `new` könnte Autorisierung umgehen |
| API-Boundaries | Explizite Effekte/Contracts, intern Inferenz | Zu viel Annotation oder versteckte Effekte |
| Feature-Zuordnung | Stable ID + Entry Points + Graph-Ausbreitung | Namensheuristiken erzeugen falsche Semantik |
| Data Lineage | Field-sensitive + Control Dependence + conservative MAY | False Positives oder übersehene implicit flows |
| Proof Scope | Modularer SMT-Ansatz + sichtbare UNKNOWNs | Solver-Skalierung, Scheinsicherheit |
| SQL und FFI | Typisierte Adapter bevorzugen, Grenzen markieren | Semantik außerhalb des Modells |
| Config | Schema-Constraints + Start-/Deploy-Validierung | Time-of-check/time-of-use |
| Trust Chain | Kleine TCB, unabhängiger Checker, Provenance | Backend-/Runtime-Bugs |
| Concurrency | Isolierte Tasks + Protokoll-Contracts | Fachliche Rennen/Distributed Consistency |
| UI | Offline HTML zuerst, später Explorer | Dashboard vor Analysequalität |
| Boilerplate | Nur überprüfbare Information explizit | Agent erfindet tautologische Contracts |
| Review Governance | Unabhängiger Owner für fachliche Änderung | Implementierender Agent genehmigt sich selbst |

**Zu entscheiden vor Phase 1:** Graph-Schema, Stable IDs, Fehlerstatusmodell, Dateiformat für Feature-IDs und Minimalumfang der ersten vertikalen Demo.

---

## 20. Vorhandene Forschung und Komponenten als Referenz

Nicht bei Null anfangen:

- **Dafny:** Verification Conditions, pre-/postconditions, Invarianten, SMT-Workflow — https://dafny.org/
- **F\*:** Refinement Types, Effekte und modulare Verifikation — https://fstar-lang.org/
- **Lean 4:** formale Modelle und kleine geprüfte Kerne — https://lean-lang.org/
- **Z3 / SMT-LIB:** automatische symbolische Beweise — https://github.com/Z3Prover/z3 · https://smt-lib.org/
- **CodeQL:** data-/control-flow paths, source-to-sink queries — https://codeql.github.com/
- **WASI / WebAssembly Component Model:** capabilityorientierte Plattform- und Ressourceninterfaces — https://wasi.dev/
- **OpenLineage:** interoperable Data-Lineage-Metadaten — https://openlineage.io/
- **SLSA / in-toto / Sigstore:** Build-Provenance und signierte Artefakte — https://slsa.dev/ · https://in-toto.io/ · https://www.sigstore.dev/

**Abgrenzung:** Diese Systeme decken wichtige Bausteine ab. Die Eigenleistung von Orin wäre die Integration in eine vertraute native Sprache, gemeinsame semantische Graph-Daten, menschlich freigegebene Requirements und einen agentenfähigen Feature-Review-Workflow.

---

## 20a. Lean-verifizierter Compiler und Runtime: verbindliche Proof-Strategie

**Ziel:** Auch der größtenteils von KI-Agents implementierte Orin-Compiler und die Orin-Runtime sollen Fehler in den eigenen Algorithmen erkennen können. Sicherheitskritische Optimierungen und Checker dürfen nicht allein aufgrund erfolgreicher Tests oder eines ähnlichen Lean-Modells als korrekt gelten. Der unabhängig prüfbare Nachweis und seine genaue Reichweite werden Teil des Entwicklungsprozesses.

### Drei getrennte Assurance-Stufen

1. **Model Proof:** Lean beweist eine Eigenschaft des formalisierten Algorithmus/MIR-Modells. Der Orin-Implementierungscode ist dadurch noch nicht verifiziert.
2. **Implementation Refinement:** Eine geprüfte Abbildung verbindet die *tatsächliche* Orin-Implementierung mit dem Modell. Alternativ validiert ein separater Translation Validator jeden konkreten Transformationsschritt gegen eine präzise Semantik.
3. **Binary Assurance:** Emittierter C-/LLVM-/Maschinencode und Laufzeit-/Plattform-ABI werden zusätzlich geprüft. Ein reproduzierbarer Bootstrap oder identische C-/LLVM-Testausgaben beweisen keine generelle Korrektheit.

Reports müssen `MODEL_ONLY`, `IMPLEMENTATION_VERIFIED`, `TRANSLATION_VALIDATED`, `TESTED_ONLY`, `ASSUMED`, `UNKNOWN` und `REFUTED` unterscheiden. `VERIFIED` darf nur mit ausgewiesener Eigenschaft, Scope, Modellversion, Beweiskette und Annahmen erscheinen.

### Risk-first-Prioritäten

| Komponente | Zu prüfende Eigenschaft | Priorität |
|---|---|---|
| MIR Ownership Verifier | Jede akzeptierte MIR erfüllt die modellierte Ownership-Disziplin; reale Checker-Implementierung entspricht dem formalen Checker | P0 |
| RC/COW, Last-use Moves, Retain/Release-Elimination | Kein Use-after-free/Double-free, Value-Semantik bleibt erhalten | P0 |
| HIR→MIR, Optimierungen | Erhalten beobachtbare Semantik einschließlich Effekten und Trap-Verhalten | P0 |
| Capability-/Effektanalyse | Soundness: benötigte Rechte werden nicht übersehen, unbekannte Effekte sind konservativ | P0 |
| Information Flow | Nachweisbare Nichtinterferenz unter spezifizierten Policies, einschließlich impliziter Flows | P0 |
| Contract-Verifier und VC-Erzeugung | Bewiesene Vor-/Nachbedingungen folgen aus den korrekten Proof Obligations; Solver-Grenzen offengelegt | P0 |
| Core-Runtime in `.or` | Tatsächliche Speicheroperationen verfeinern die Lean-Speichermaschine | P0 |
| Typechecker, Parser, Formatter | Type Soundness für Sprachkern; Parser- und Formatter-Eigenschaften | P1 |
| LLVM/C-Backend, Plattform und FFI | Semantik/ABI/Runtime-Contracts und Übersetzungsintegrität | P1 |

**Kein pauschaler Lean-Pflichtbeweis für jeden Hilfsalgorithmus:** Strenge Anforderungen gelten zunächst für sicherheits- und semantikkritische Komponenten. Bei nicht kritischer Infrastruktur reichen risikobasierte Tests.

### PR-Vertrag für kritische Compileränderungen

Jede relevante PR liefert:
1. **Formale Spezifikation:** Semantik, Preconditions, Postconditions, Invarianten, Fehlerfälle, erlaubte Effekte und externe Annahmen.
2. **Lean-Theorem(e):** Beweise für die genannten Eigenschaften; pinnen der Tool-Versionen. Keine `sorry`/`admit`-Platzhalter, unkontrollierten Axiome oder unbegründeten `unsafe`-Abkürzungen im vertrauenswürdigen Proof-Pfad.
3. **Implementierungsbindung:** Eine explizite Relation zwischen realen Orin-/MIR-Operationen und dem Lean-Modell; fehlt sie, ist das Ergebnis lediglich `MODEL_ONLY`.
4. **Adversarial Regression Suite:** Grammar-Fuzzing, negative MIR-Fälle, Property-/Metamorphic- und Differentialtests. Absichtlich fehlerhafte Optimierungen oder Capability-Analysen müssen die Prüfung scheitern lassen.
5. **Proof Impact Diff:** Geänderte Annahmen, invalidierte Theoreme, neue Proof Obligations und verletzte Policies werden im Feature-first PR-Report erklärt.
6. **Governance:** Ein implementierender Agent darf weder Contracts stillschweigend schwächen noch durch neue Axiome oder mehr Rechte ein rotes Ergebnis „reparieren“, ohne gesonderte Freigabe.

Beispiel: Bei der Entfernung eines `retain` muss nicht nur der separate Ownership-Checker die neue MIR akzeptieren; die Transformation muss auch die beobachtbare Semantik und Fehler-/Effektgrenzen erhalten. Speicher-sicher ist nicht automatisch korrekt.

### Unabhängigkeit und Trusted Computing Base

- Lean-Kernel prüft Proof-Terme; Taktiken sind keine unabhängige Autorität. SMT-`unsat` ohne separat überprüftes Zertifikat vertraut mindestens dem Solver und VC-Encoder.
- Ein möglichst kleiner, unabhängig entwickelter **Translation Validator** kann Eingabe- und Ausgabe-MIR vergleichen. Bei unentscheidbaren Fällen `UNKNOWN` statt behaupteter Äquivalenz.
- C/LLVM Differentialtests, Sanitizer, zufallsgenerierte Programme, Seed-/Stage0-Vergleiche und Stage2==Stage3 bleiben wichtig, zählen aber jeweils als **Tests oder Reproduzierbarkeit**, nicht als genereller mathematischer Beweis.
- Runtime-Migration nach spec 19: `core/*.or` implementiert Ownership, Arrays, Strings und Allokation; eine kleine, geschlossene Low-Level-Intrinsic-/Plattform-Grenze wird separat geprüft. Kein Zirkelschluss, bei dem die zu prüfende Runtime ihre eigenen Beweisannahmen garantiert.

### CI und menschenlesbarer Nachweis

Vorgeschlagener Workflow `tools/verify_compiler.sh` mit maschinenlesbarem JSON und GitHub-Check:

```text
Lean proofs & assumptions audit          PASS
MIR checker model                       MODEL_ONLY
Actual checker ↔ formal model           UNKNOWN
RC/COW formal machine                   PROVEN (MODEL)
Retain-elimination transformation       TRANSLATION_VALIDATED / UNKNOWN
HIR→MIR                                  TESTED_ONLY
C/LLVM + sanitizers                      PASS (TESTS)
Negative mutation corpus                 PASS
Bootstrap fixed point                    PASS
Release assurance                        INCOMPLETE
```

*Illustrative Statuswerte, keine Aussage über die aktuelle CI.*

- Bereits etablierte, verpflichtende P0-Eigenschaften: **Fail closed** bei gebrochenem Proof, neuen nicht freigegebenen Axiomen oder fehlgeschlagenem Validator.
- Für noch nicht erfüllte Forschungsziele einen expliziten **Proof-Debt-Ledger** führen; keine fälschlich grünen Sicherheitsclaims, aber auch keine pauschale Blockade jeder Entwicklungs-PR.
- Nachweisformat mindestens: `property_id`, `assurance_level`, `status`, `assumptions`, `source_hash`, `model_hash`, `compiler_version`, `checker_version`, `proof_dependencies`, `evidence`.
- Kritische Compiler- und Runtime-Änderungen invalidieren abhängige Nachweise und werden in OSIG/PR-Reports sichtbar.

### Phasenplan

- **L0 – Audit:** Bestehende Lean-Theoreme, Axiome und tatsächlichen Implementierungsbezüge inventarisieren; Claim-vs-Evidence-Tabelle und Proof Debt erstellen.
- **L1 – CI-Härtung:** Lean pinnen, Axiom-/`sorry`-Checks, Mutationstests und negative MIR-Tests verbindlich machen.
- **L2 – End-to-End-Beispiel:** Eine kleine reale Optimierung (z. B. Last-use Move) mit Modell, Beweis, Implementierungsbindung und aktiv entdecktem Fehler als vertikalen Proof-Slice liefern.
- **L3 – Ausrollen:** Checker, HIR→MIR, Capability-/Effektanalyse und Information Flow risikobasiert formalisieren.
- **L4 – Runtime:** Orin-Core-Dialekt, verifizierte RC-/COW-Verfeinerung und unabhängige Plattform-Intrinsic-Contracts.
- **L5 – Proof-Carrying Releases:** Nachweise an Quellrevision, Build, Konfiguration und Binärartefakte binden; offenen TCB/Assumptions explizit ausweisen.

**Definition of Done:** Mindestens ein absichtlich injizierter relevanter Fehler wird unabhängig entdeckt; Modellbeweis und Code-Nachweis werden sauber unterschieden; betroffene Nachweise werden bei Änderungen invalidiert; CI liefert reproduzierbare Gründe statt bloßer Ampeln.

**Leitsatz:** *AI implements; independent proof checkers and adversarial tests establish what can actually be trusted.*

---

## 21. Produktidentität und Schlussfolgerung

Orin soll nicht nur eine Sprache sein, in der Agents bequem programmieren. Orin soll eine **durchgehende Evidenzkette** liefern:

```text
Business Requirement (human-approved)
          ↓
Formal Contracts + Capability/Data Policies
          ↓
AI-generated TypeScript-like Orin Code
          ↓
Typed HIR/MIR + Ownership/Effect/Dataflow Analysis
          ↓
Verification Conditions + Explicit Assumptions
          ↓
Native Executable + Versioned OSIG Snapshot
          ↓
Feature-first Semantic PR Review
          ↓
Provenance-bound .orcert Release
```

Das zentrale Versprechen an einen Enterprise-Reviewer:

> **„Du musst nicht jede generierte Codezeile lesen, um zu verstehen, was sich fachlich geändert hat, welche Daten und Rechte betroffen sind, was mathematisch bewiesen wurde und wo weiterhin Vertrauen statt Beweis nötig ist.“**

Das bleibt ein ambitioniertes Forschungs- und Engineering-Projekt. Der Weg zum glaubwürdigen Produkt besteht nicht darin, möglichst schnell viele Labels auf „Verified“ zu setzen. Er besteht darin, mit jedem Schritt **weniger unbelegte Behauptungen und mehr prüfbare, verständliche Evidenz** zu erzeugen.

**Nächster konkreter Schritt:** OSIG v0.1, `orin graph`, `orin diff` und einen ersten statischen GitHub-PR-Report auf einer echten Orin-Demo umsetzen – danach Effekt-/Capability-Analyse und schrittweise formale Verifikation integrieren.