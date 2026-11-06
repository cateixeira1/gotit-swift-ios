# Document Core — etapa 1

## Contrato implementado

`GotItDomain` contém valores `Codable`, `Equatable` e `Sendable`, sem dependência
de UI, SQLite ou IA. `GotItPersistence` é o repositório em um Swift actor.
O SQLite do sistema é acessado pelo módulo C `CSQLite`, sem pacotes externos.

`CanvasDocument` guarda identidade, revisão, datas e estilo padrão.
`CanvasBlock` guarda identidade, pai, ordem entre irmãos, layout, estilo e
conteúdo tipado. A hierarquia admite múltiplos blocos raiz; apenas containers
podem ter filhos. A ordem deve ser única entre irmãos, mas pode ter intervalos.
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
| `history` | Comandos e snapshots anterior/posterior por transação |

Campos de conteúdo usam JSON em BLOBs; identidades e relacionamentos têm
colunas SQL e foreign keys compostas. Texto não é duplicado entre `blocks` e
`text_contents`. A ordem dos arrays é preservada por `ordinal`.
O registro de um hash com metadados diferentes é rejeitado. A existência e o
hash real dos arquivos ainda não são verificados: os arquivos serão geridos
na etapa 3. Metadados podem existir sem referência ativa; coleta de assets
deverá considerar também o histórico antes de apagar qualquer arquivo.

A migração inicial é um recurso SQL versionado e transacional, com
`PRAGMA user_version = 1`. Versões futuras são recusadas sem reset do banco.
Não existe fallback que apague uma base que falhou ao abrir ou decodificar.
Alterações de formato e enum cases persistidos exigirão migração explícita.

Foreign keys ficam ligadas em cada conexão. WAL e `synchronous=FULL` são
configurados para as gravações; o timeout de lock é de 5 segundos.
Essas opções não substituem backups, proteção dos arquivos ou testes no aparelho.
Nunca copie apenas o arquivo `.sqlite` de um banco aberto em WAL para backup;
uma futura API deverá usar o mecanismo de backup do SQLite ou equivalente.

## Histórico e limites desta primeira implementação

O histórico persiste snapshots completos de metadados/texto, sem bytes de mídia.
O limite padrão é de 50 lotes por documento, configurável ao abrir o store.
Após undo, uma edição nova descarta o ramo redo; o limite de retenção define
até onde o usuário pode desfazer. A retenção é por quantidade, não por bytes;
diminuir o limite produz limpeza na próxima edição.

Para tornar a atomicidade verificável nesta base, a gravação reescreve os rows
do documento dentro da transação. Isso custa O(n) por edição e snapshots também
podem crescer com notas extensas. **Ainda não é a estratégia final de memória
e armazenamento do produto.** Antes de integrar edição a cada tecla, medir
notas grandes, agrupar gestos/digitação, usar gravações diferenciais e evoluir
o histórico para deltas com checkpoints e limite por bytes. O contrato público
foi isolado para permitir essa evolução.

Não há ainda FTS5, R-Tree, sqlite-vec, compressão, OCR, transcrição, recuperação
de arquivos de mídia, criptografia de banco ou UI. Busca e motores locais
(incluindo as opções discutidas de embeddings/Core ML/LiteRT) serão avaliados
nas respectivas etapas; nenhuma dependência de IA foi fixada nesta base.

## Referências de implementação

- [Swift Package Manager — module maps](https://docs.swift.org/main/documentation/packagemanagerdocs/modulemaps/)
- [Swift Testing](https://developer.apple.com/documentation/testing)
- [SQLite — foreign keys](https://www.sqlite.org/foreignkeys.html)
- [SQLite — WAL](https://www.sqlite.org/wal.html)
- [SQLite — PRAGMAs](https://www.sqlite.org/pragma.html)
