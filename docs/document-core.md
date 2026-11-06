# Document Core — etapa 1

## Contrato implementado

`GotItDomain` contém valores `Codable`, `Equatable` e `Sendable`, sem dependência
de UI, SQLite ou IA. `GotItPersistence` é o repositório em um Swift actor.
O SQLite do sistema é acessado pelo módulo C `CSQLite`, sem pacotes externos.

`CanvasDocument` guarda identidade, revisão, datas e estilo padrão.
`CanvasBlock` guarda identidade, pai, ordem entre irmãos, layout, estilo e
conteúdo tipado. A hierarquia admite múltiplos blocos raiz; apenas containers
podiam ter filhos na versão 1. A versão 2 também admite formas fechadas como
pais, para texto e imagens em diagramas. A ordem deve ser única entre irmãos,
mas pode ter intervalos.
Reordenações são lotes de comandos, validados após a aplicação completa.

Os modos `flow`, `absolute` e `anchored` preservam a proposta de canvas híbrido.
Frames usam pontos lógicos, relativos ao pai; em `anchored`, ao bloco âncora.
O motor visual calculará a posição final na etapa 2. Dependências de parentesco
e âncora não podem formar ciclos, inclusive ciclos que misturem as duas relações.
Relações de link/conector/anotação são independentes da árvore de layout.

Os estilos são parciais: `nil` herda, enquanto `false` sobrepõe `true`.
A cascata é documento → containers externos → containers internos → bloco.
Cada run de texto pode sobrepor o resultado com `merging(_:)`.
As cores são `#RRGGBB` ou `#RRGGBBAA`. Os runs guardam o próprio texto, evitando
offsets ambíguos entre Unicode, UTF-16 e índices Swift. O adaptador TextKit 2
virá depois. Imagem, desenho, PDF, áudio e vídeo contêm referências a assets;
formas contêm parâmetros vetoriais básicos.

## Comandos e transações

`execute(_:documentID:expectedRevision:)` abre `BEGIN IMMEDIATE`, lê a versão
atual sob o lock de escrita, confere a revisão, aplica o lote numa cópia,
valida o resultado e grava conteúdo + revisão + histórico na mesma transação.
Qualquer erro faz rollback. A revisão cresce também em undo/redo para impedir
que uma edição antiga volte a parecer atual. Leituras compostas usam uma
transação de leitura para não misturar estados de conexões diferentes.

`removeSubtree` remove descendentes e relações que os referenciam. Um bloco
externo ancorado na árvore removida exige reancoragem ou mudança de layout no
mesmo lote; a operação falha se deixar a referência órfã.
`deleteDocument` é uma API explicitamente permanente, protegida por revisão.

IA futura deverá produzir `DocumentCommand` e usar a mesma validação e controle
de revisão. Esta etapa não inclui um runtime de IA nem aplicação automática de
suas propostas.

## Esquema e integridade

| Tabela | Responsabilidade |
| --- | --- |
| `documents` | Metadados e cursor do histórico |
| `blocks` | Identidades, parentesco, âncora, asset e metadados de cada bloco |
| `text_contents` | Runs de texto, separados dos metadados do bloco |
| `assets` | Registro de metadados por hash SHA-256 e documento |
| `asset_derivatives` | Metadados de derivados por função, como thumbnail |
| `block_relations` | Relações com endpoints no mesmo documento |
| `history` | Grupo e deltas inverso/direto por transação |

Campos de conteúdo usam JSON em BLOBs; identidades e relacionamentos têm
colunas SQL e foreign keys compostas. Texto não é duplicado entre `blocks` e
`text_contents`. A ordem dos arrays é preservada por `ordinal`.
O registro de um hash com metadados diferentes é rejeitado. A existência e o
hash real dos arquivos ainda não são verificados: os arquivos serão geridos
na etapa 3. Metadados podem existir sem referência ativa; coleta de assets
deverá considerar também o histórico antes de apagar qualquer arquivo.

O esquema atual é v5: v3 introduziu páginas; v4 converte snapshots antigos em
deltas dentro de uma transação; v5 identifica histórias e páginas de continuação.
Os nomes físicos `before_snapshot`/`after_snapshot` são mantidos por compatibilidade
SQL, mas desde v4 contêm deltas, não documentos. Writers antigos recusam a base.
Uma falha de migração não apaga os dados.

Foreign keys ficam ligadas em cada conexão. WAL e `synchronous=FULL` são
configurados para as gravações; o timeout de lock é de 5 segundos.
Essas opções não substituem backups, proteção dos arquivos ou testes no aparelho.
Nunca copie apenas o arquivo `.sqlite` de um banco aberto em WAL para backup;
uma futura API deverá usar o mecanismo de backup do SQLite ou equivalente.

## Histórico e limites

O histórico persiste deltas inversos e diretos, com splices de caracteres para
texto. Retém até 50 grupos; a UI agrupa digitação consecutiva. Redo é descartado
quando uma nova edição cria um ramo. Gravação atualiza somente linhas modificadas;
blocos inalterados não são serializados para construir os deltas. O editor ainda
percorre valores em memória e o histórico não tem orçamento de bytes.

A coleta física de assets usa todos os estados retidos, não apenas blocos visíveis.
Detalhes, migração, validação e limitações em [stage-2-review.md](stage-2-review.md).

Não há ainda FTS5, R-Tree, sqlite-vec, compressão, OCR, transcrição, recuperação
de arquivos de mídia ou criptografia de banco. A UI inicial está descrita em
[stage-2-canvas.md](stage-2-canvas.md). Busca e motores locais
(incluindo as opções discutidas de embeddings/Core ML/LiteRT) serão avaliados
nas respectivas etapas; nenhuma dependência de IA foi fixada nesta base.

## Referências de implementação

- [Swift Package Manager — module maps](https://docs.swift.org/main/documentation/packagemanagerdocs/modulemaps/)
- [Swift Testing](https://developer.apple.com/documentation/testing)
- [SQLite — foreign keys](https://www.sqlite.org/foreignkeys.html)
- [SQLite — WAL](https://www.sqlite.org/wal.html)
- [SQLite — PRAGMAs](https://www.sqlite.org/pragma.html)
