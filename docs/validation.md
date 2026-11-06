> Histórico da entrega anterior. O status atual, as mudanças e os limites desta revisão estão em [stage-2-review.md](stage-2-review.md). Teia e equações estão congeladas.

# Validação da primeira implementação

Execute `swift test` na raiz. A suíte usa bancos temporários reais e fixtures
independentes; não usa um mock para os testes de persistência.

Validação local em 6 de novembro de 2026: a base inicial passou em 24 testes;
a extensão da etapa 2 e suas páginas passaram em **48 testes** com Swift 6.0.3 em Linux.
Há também entradas parametrizadas para dimensões e expressões matemáticas.
O código UIKit fica fora da compilação Linux; a análise sintática separada
não substitui a compilação contra os SDKs Apple nem testes visuais.
O workflow `.github/workflows/swift.yml` registra as verificações Apple/Linux
de cada commit; consulte seu resultado antes de integrar a branch.

O CI anterior (`eb542b4`, execução 42191501818) aprovou testes Linux/macOS e
builds do adaptador e demo no SDK iOS. A evolução do editor acrescenta testes
nativos e UI em simuladores; consulte o CI do commit atual para seu resultado.

## Cobertura

- Round-trip de todos os tipos de bloco, estilos, Unicode, NUL, assets,
  derivados e relações, fechando e reabrindo o banco.
- Undo/redo persistente entre reaberturas, revisões monotônicas, descarte do
  ramo redo e limite de retenção.
- Conflito de revisão em duas conexões e duas escritas concorrentes, com
  exatamente uma vencedora.
- Lote inválido sem alteração de conteúdo, revisão ou histórico.
- Falha SQL injetada após alterações já terem começado, seguida de rollback
  integral; falha de undo sem avanço indevido do cursor.
- Isolamento entre documentos e remoção de um sem afetar outro.
- Migração idempotente, rollback de migração e recusa de esquema futuro.
- IDs duplicados, ordens inválidas, órfãos, ciclos pai/âncora, geometria e
  estilos inválidos; validação iterativa de árvore com 5.000 containers.
- Migração v1/v2→v3 preservando conteúdo e histórico; persistência de Teias,
  preferências, recorte, rotação, estilos de parágrafo e tinta.
- A4 e unidades, zoom, posicionamento, contorno, redimensionamento proporcional,
  reconhecimento geométrico, cronologia independente de posição e equações.

## Critérios ainda necessários antes de encerrar a etapa 1 para produção

- Executar o aplicativo e calibrar escrita/desenho em iPhone/iPad físicos;
  o CI valida separadamente SDK Apple e simuladores.
- Testar encerramento abrupto do processo, espaço em disco esgotado, banco
  corrompido e suspensão/retomada do aplicativo em aparelhos reais.
- Medir latência, tamanho do banco e memória para notas grandes; substituir
  regravação integral e snapshots por operações diferenciais/checkpoints
  antes de persistir eventos de digitação em alta frequência.
- Definir política de backup/restauração e proteção dos arquivos no iOS.

O critério original da etapa é **persistência sem perda**. Os testes demonstram
os cenários explicitamente cobertos, sem transformar isso em garantia absoluta
contra falhas de hardware, exclusão externa ou todos os estados do sistema.
