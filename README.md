# Got It!

Aplicativo de notas para iPhone e iPad com canvas modular híbrido e IA local.
Este repositório inclui o **Document Core**, o **Canvas Engine** em desenvolvimento e o alvo **GotItApp**.

**A etapa 2 permanece aberta.** Consulte [a revisão de prioridades e validação](docs/stage-2-review.md).

O pacote já oferece modelos de documentos e blocos, estilos herdados, texto por
runs, comandos validados, persistência SQLite e undo/redo persistente. Ainda não
há versão de produção ou modelo de IA integrado. A etapa 2 acrescenta o motor
de canvas testável e uma interface nativa. O build Apple da base foi aprovado;
a evolução com páginas, paleta e PencilKit está descrita em [Editor nativo](docs/native-editor.md).

## Executar

- Swift 6.0 ou superior; Xcode 16 ou superior no Mac.
- Plataformas mínimas desta base: iOS/iPadOS 18 e macOS 15. São escolhas iniciais
  de implementação, ajustáveis quando os runtimes de IA forem integrados.
- No Linux, instalar os headers SQLite: `apt-get install libsqlite3-dev`.

```sh
swift test
```

No Xcode, abra `Package.swift`. Os produtos são `GotItDomain` e
`GotItPersistence`, `GotItCanvas` e `GotItCanvasUI`. O workflow está configurado
para testar Linux/macOS e compilar o adaptador/aplicativo para iOS Simulator.

O aplicativo está em [Apps/GotIt](Apps/GotIt/README.md), com configuração iPhone/iPad e Mac Catalyst.
O código UIKit não é compilado no Linux: o sucesso dos testes locais não prova
que a interface já foi validada no Xcode.

## Exemplo

Em uma função `async throws` do aplicativo:

```swift
import Foundation
import GotItDomain
import GotItPersistence

let directory = try FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask,
    appropriateFor: nil, create: true
).appendingPathComponent("GotIt", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let store = try SQLiteStore(url: directory.appendingPathComponent("documents.sqlite"))

let note = try await store.create(CanvasDocument(
    title: "Minha primeira nota", defaultStyle: BlockStyle(fontSize: 18)
))
let text = CanvasBlock(content: .text(RichText("Got it!")))
let edited = try await store.execute(
    [.insertBlock(text)], documentID: note.id, expectedRevision: note.revision
)
let undone = try await store.undo(documentID: note.id, expectedRevision: edited.revision)
let restored = try await store.redo(documentID: note.id, expectedRevision: undone.revision)
assert(restored.blocks == edited.blocks)
try await store.close()
```

Sempre use a revisão retornada pela última operação. Em caso de
`revisionConflict`, recarregue a nota e reconcilie a intenção de edição; não
repita automaticamente um comando sobre uma versão que o usuário não viu.

## Estrutura e plano

| Etapa | Entrega | Situação |
| --- | --- | --- |
| 1 — Document Core | SQLite, blocos, estilos, comandos, undo/redo e persistência verificável | Primeira implementação neste repositório |
| 2 — Canvas Engine | A4/customizado, contorno de texto, diagramas, Teia, gestos e TextKit 2 | Motor inicial implementado; UI e recursos restantes em validação/desenvolvimento |
| 3 — Multimídia e armazenamento | Importação, arquivos por hash, derivados, compressão e limpeza segura | Planejada |
| 4 — Semantic Memory | Indexação, busca textual/espacial e embeddings locais | Planejada |
| 5 — Local Intelligence | Inferência local e propostas de operações validadas | Planejada |

As decisões preservadas são: aparelhos recentes, funcionamento offline completo,
conteúdo criado e importado, prioridade à qualidade do SLM, canvas híbrido,
desenhos livres e formas, suporte previsto a todas as mídias.

- [Arquitetura, limites e decisões](docs/document-core.md)
- [Validação e próximos critérios da etapa 1](docs/validation.md)
- [Requisitos e implementação da etapa 2](docs/stage-2-canvas.md)

## Licença

A licença original do repositório está em [LICENSE](LICENSE).
